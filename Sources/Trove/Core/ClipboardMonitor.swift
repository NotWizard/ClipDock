import AppKit
import Combine
import CryptoKit
import Foundation

/// Polls the general pasteboard, captures every flavour of a new entry, and
/// hands a ready-to-store `ClipItem` to the store.
@MainActor
final class ClipboardMonitor: ObservableObject {
    private let store: Store
    private let prefs: Preferences
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Set right after we write to the pasteboard ourselves so we don't echo.
    private var suppressedChangeCount: Int = -1

    @Published private(set) var isPaused = false
    @Published private(set) var pausedUntil: Date?

    /// Bundle id of the app that was frontmost when the entry was copied.
    private(set) var currentSource: SourceApp = .unknown

    var onCapture: ((ClipItem) -> Void)?

    private static let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
        "com.agilebits.onepassword",
    ]

    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword",
        "com.1password.clipboard.concealed",
    ]

    init(store: Store, prefs: Preferences, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.prefs = prefs
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: Lifecycle

    func start() {
        stop()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refreshSource()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func suppressNextChange() {
        suppressedChangeCount = pasteboard.changeCount
    }

    // MARK: Pause

    func pause(for interval: TimeInterval?) {
        isPaused = true
        pausedUntil = interval.map { Date().addingTimeInterval($0) }
    }

    func resume() {
        lastChangeCount = pasteboard.changeCount
        isPaused = false
        pausedUntil = nil
    }

    func clearExpiredPause() {
        guard isPaused, let pausedUntil, Date() >= pausedUntil else { return }
        resume()
    }

    // MARK: Source tracking

    func refreshSource() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        currentSource = SourceApp(
            bundleID: app.bundleIdentifier,
            name: app.localizedName,
            icon: app.icon,
            color: .secondaryLabelColor
        )
    }

    // MARK: Polling

    private func poll() {
        clearExpiredPause()
        guard !isPaused else { return }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard changeCount != suppressedChangeCount else { return }

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }
        if items.allSatisfy({ $0.types.isEmpty }) { return }

        // Honour privacy filters before doing any expensive work.
        if prefs.ignoreTransient, items.contains(where: { item in
            item.types.contains { ClipboardMonitor.transientTypes.contains($0.rawValue) }
        }) { return }

        if prefs.ignoreConfidential, items.contains(where: { item in
            item.types.contains { ClipboardMonitor.concealedTypes.contains($0.rawValue) }
        }) { return }

        refreshSource()
        if let bundleID = currentSource.bundleID, prefs.ignoredBundleIDs.contains(bundleID) { return }

        guard let captured = capture(from: pasteboard, items: items) else { return }

        var item = ClipItem()
        item.kind = captured.kind
        item.sourceBundleID = currentSource.bundleID
        item.sourceName = currentSource.name
        item.text = captured.text
        item.urlString = captured.urlString
        item.colorHex = captured.colorHex
        item.colorComponents = captured.colorComponents
        item.filePaths = captured.filePaths
        item.checksum = captured.checksum
        item.title = captured.title
        item.searchText = captured.searchText
        item.payloads = store.storePayloads(for: item.id, captured: captured.payloads)

        if let imageData = captured.imageData {
            item.imageName = store.storeImage(for: item.id, data: imageData)
            item.imagePixelSize = captured.imagePixelSize
        }

        let stored = store.insert(item)
        onCapture?(item)
        // A duplicate capture is discarded; enrichment must target the item that
        // actually lives in the library.
        guard stored.inserted else { return }

        if item.kind == .image, let data = captured.imageData {
            Task { await OCRService.shared.recognize(imageData: data, itemID: stored.id) }
        }
        if item.kind == .link, prefs.generateLinkPreviews, let urlString = captured.urlString {
            Task { await LinkPreviewService.shared.enrich(urlString: urlString, itemID: stored.id) }
        }
    }

    // MARK: Capture

    private struct Captured {
        var kind: ItemKind
        var payloads: [(type: String, data: Data, index: Int)]
        var text: String?
        var urlString: String?
        var colorHex: String?
        var colorComponents: [Double]?
        var filePaths: [String]
        var imageData: Data?
        var imagePixelSize: [Int]?
        var checksum: String
        var title: String
        var searchText: String
    }

    private func capture(from pasteboard: NSPasteboard, items: [NSPasteboardItem]) -> Captured? {
        // 1. Raw flavours for faithful playback.
        var payloads: [(type: String, data: Data, index: Int)] = []
        var totalBytes = 0
        let byteBudget = 32 * 1024 * 1024

        for (itemIndex, item) in items.enumerated() {
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                guard totalBytes + data.count <= byteBudget else { continue }
                totalBytes += data.count
                payloads.append((type.rawValue, data, itemIndex))
            }
        }
        guard !payloads.isEmpty else { return nil }

        let checksum = ClipboardMonitor.checksum(payloads)

        // 2. Text.
        let plainText = pasteboard.string(forType: .string)
            ?? items.first.flatMap { $0.string(forType: .string) }

        // 3. Files.
        var filePaths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            filePaths = urls.filter(\.isFileURL).map(\.path)
        }

        // 4. Colour.
        var colorHex: String?
        var colorComponents: [Double]?
        if let colors = pasteboard.readObjects(forClasses: [NSColor.self]) as? [NSColor], let color = colors.first,
           let srgb = color.usingColorSpace(.sRGB) {
            colorHex = srgb.hexString
            colorComponents = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        }

        // 5. Image.
        var imageData: Data?
        var imagePixelSize: [Int]?
        if let image = NSImage(pasteboard: pasteboard) {
            if let png = ClipboardMonitor.pngData(from: image) {
                imageData = png
                if let rep = NSBitmapImageRep(data: png) {
                    imagePixelSize = [rep.pixelsWide, rep.pixelsHigh]
                }
            }
        }

        // 6. URL.
        var urlString: String?
        if let raw = pasteboard.string(forType: .URL) ?? items.first?.string(forType: .URL),
           let url = URL(string: raw), url.scheme != nil {
            urlString = raw
        } else if let text = plainText, ClipboardMonitor.looksLikeBareURL(text) {
            urlString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 7. Classification (order matters, mirrors the reference app's six kinds).
        let kind: ItemKind
        if !filePaths.isEmpty {
            kind = .files
        } else if imageData != nil && plainText == nil {
            kind = .image
        } else if colorHex != nil && plainText == nil {
            kind = .color
        } else if let urlString, plainText == nil || ClipboardMonitor.looksLikeBareURL(plainText!) {
            kind = .link
            _ = urlString
        } else if let plainText, !plainText.isEmpty {
            kind = .text
        } else if imageData != nil {
            kind = .image
        } else {
            kind = .unknown
        }

        // 8. Presentable text.
        var title: String
        var searchText: String

        switch kind {
        case .text:
            let text = plainText ?? ""
            title = ClipboardMonitor.title(for: text)
            searchText = text
        case .link:
            let url = urlString ?? plainText ?? ""
            title = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
            searchText = url
        case .image:
            if let size = imagePixelSize {
                title = "Image \(size[0]) × \(size[1])"
            } else {
                title = "Image"
            }
            searchText = "image png picture"
        case .color:
            title = "#\(colorHex ?? "FFFFFF")"
            searchText = "color \(colorHex ?? "")"
        case .files:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            title = names.count == 1 ? names[0] : "\(names.count) files"
            searchText = filePaths.joined(separator: " ")
        case .unknown:
            title = payloads.first?.type ?? "Clipboard item"
            searchText = ""
        }

        return Captured(
            kind: kind,
            payloads: payloads,
            text: plainText,
            urlString: urlString,
            colorHex: colorHex,
            colorComponents: colorComponents,
            filePaths: filePaths,
            imageData: imageData,
            imagePixelSize: imagePixelSize,
            checksum: checksum,
            title: title,
            searchText: searchText
        )
    }

    // MARK: Helpers

    static func checksum(_ payloads: [(type: String, data: Data, index: Int)]) -> String {
        var hasher = SHA256()
        for entry in payloads.sorted(by: { ($0.index, $0.type) < ($1.index, $1.type) }) {
            hasher.update(data: Data("\(entry.index)".utf8))
            hasher.update(data: Data(entry.type.utf8))
            hasher.update(data: entry.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func looksLikeBareURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.count < 2048 else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        guard ["http", "https", "mailto"].contains(scheme) else { return false }
        return url.host != nil || scheme == "mailto"
    }

    static func title(for text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        if collapsed.isEmpty { return text.isEmpty ? "Empty text" : text }
        return collapsed.count > 90 ? String(collapsed.prefix(90)) + "…" : collapsed
    }
}
