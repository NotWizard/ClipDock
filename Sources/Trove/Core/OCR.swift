import AppKit
import Foundation
import LinkPresentation
import Vision

/// On-device OCR so screenshots become searchable.
///
/// Notes drawn from measurement on this machine: the first Vision text request in
/// a fresh process pays a one-off Apple Neural Engine model compile (tens of
/// seconds). Pinning several recognition languages multiplies that cost, so this
/// service uses the system default language set, downscales large images, and
/// runs a warm-up request at launch so captures stay fast.
final class OCRService: @unchecked Sendable {
    static let shared = OCRService()

    private let queue = DispatchQueue(label: "app.trove.ocr", qos: .userInitiated)
    private var isWarm = false

    // MARK: Warm-up

    func prewarm() {
        queue.async { [weak self] in
            guard let self, !self.isWarm else { return }
            guard let image = OCRService.warmupImage(),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            _ = try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            self.isWarm = true
            NSLog("TroveOCR warm-up finished")
        }
    }

    private static func warmupImage() -> NSImage? {
        let size = NSSize(width: 320, height: 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("warm up 123" as NSString).draw(
            at: NSPoint(x: 8, y: 24),
            withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
        )
        image.unlockFocus()
        return image
    }

    // MARK: Recognition

    func recognize(imageData: Data, itemID: UUID) async {
        guard let image = NSImage(data: imageData) else { return }
        let prepared = OCRService.downscale(image, maxDimension: 1600)
        guard let cgImage = prepared.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async {
                let request = VNRecognizeTextRequest { request, _ in
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let joined = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: joined)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    self.isWarm = true
                } catch {
                    NSLog("TroveOCR failed: %@", String(describing: error))
                    continuation.resume(returning: "")
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            let store = Store.shared
            guard var item = store.items.first(where: { $0.id == itemID }) else { return }
            guard !item.searchText.contains(trimmed) else { return }
            item.searchText += "\n" + trimmed
            store.update(item)
        }
    }

    /// Keeps OCR tractable on 5K screenshots without losing readable text.
    private static func downscale(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return image }
        let scale = maxDimension / largest
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        output.unlockFocus()
        return output
    }
}

/// Fetches page metadata so link cards show a real title instead of a hostname.
@MainActor
final class LinkPreviewService {
    static let shared = LinkPreviewService()
    private var inFlight: Set<UUID> = []

    func enrich(urlString: String, itemID: UUID) async {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return }
        guard inFlight.insert(itemID).inserted else { return }
        defer { inFlight.remove(itemID) }

        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        var previewData: Data?
        if let imageProvider = metadata.imageProvider ?? metadata.iconProvider,
           imageProvider.canLoadObject(ofClass: NSImage.self) {
            let image: NSImage? = await withCheckedContinuation { continuation in
                _ = imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                    continuation.resume(returning: object as? NSImage)
                }
            }
            if let image, image.size.width > 0, image.size.height > 0 {
                let scale = min(1, 1024 / max(image.size.width, image.size.height))
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                let thumbnail = NSImage(size: size)
                thumbnail.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: size))
                thumbnail.unlockFocus()
                if let data = ClipboardMonitor.pngData(from: thumbnail), data.count <= 8 * 1024 * 1024 { previewData = data }
            }
        }
        let store = Store.shared
        guard var item = store.items.first(where: { $0.id == itemID }), item.urlString == urlString else { return }
        if let title = metadata.title, !title.isEmpty {
            if item.title.isEmpty || item.title == item.host || item.title == item.urlString { item.title = title }
            if !item.searchText.contains(title) { item.searchText += "\n" + title }
        }
        if let previewData {
            item.imageName = store.storeImage(for: item.id, data: previewData)
        }
        store.update(item)
    }
}
