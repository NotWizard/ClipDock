import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Owns clipboard writing and the external application remembered before UI opens.
@MainActor
final class Paster {
    static let shared = Paster()
    nonisolated static let itemIdentifier = "app.trove.clipboard.item"

    private(set) var pasteTarget: NSRunningApplication?
    private(set) var lastError: String?
    private var activationObserver: NSObjectProtocol?

    var hasAccessibility: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var destinationName: String { validTarget?.localizedName ?? "当前应用" }

    private var validTarget: NSRunningApplication? {
        guard let target = pasteTarget, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return target
    }

    func startTrackingTarget() {
        rememberFrontmostTarget()
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Paster.shared.rememberFrontmostTarget() }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Clipboard representations

    @discardableResult
    func write(items: [ClipItem], plainText: Bool = false, store: Store, pasteboard: NSPasteboard = .general) -> Bool {
        lastError = nil
        var written: [NSPasteboardItem] = []
        let forcePlainText = plainText || Preferences.shared.alwaysPlainText

        for clip in items {
            if forcePlainText, let text = clip.text ?? clip.urlString {
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                written.append(item)
                continue
            }
            let groups = Dictionary(grouping: store.payloadData(for: clip), by: { $0.index })
            var produced: [NSPasteboardItem] = []
            for index in groups.keys.sorted() {
                let item = NSPasteboardItem()
                for payload in groups[index] ?? [] {
                    item.setData(payload.data, forType: NSPasteboard.PasteboardType(payload.type))
                }
                if !item.types.isEmpty { produced.append(item) }
            }
            if produced.isEmpty, let text = clip.text ?? clip.urlString {
                let fallback = NSPasteboardItem()
                fallback.setString(text, forType: .string)
                produced.append(fallback)
            }
            guard !produced.isEmpty else {
                lastError = "原始内容已不可用，剪贴板未更改。"
                return false
            }
            written.append(contentsOf: produced)
        }
        guard !written.isEmpty else { return false }
        if forcePlainText, written.count > 1,
           written.allSatisfy({ $0.string(forType: .string) != nil }) {
            let combined = NSPasteboardItem()
            combined.setString(written.compactMap { $0.string(forType: .string) }.joined(separator: "\n"), forType: .string)
            written = [combined]
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(written) else {
            lastError = "未能写入系统剪贴板，请重试。"
            return false
        }
        if pasteboard.name == NSPasteboard.general.name, NSApp?.delegate is AppDelegate {
            TroveApp.shared.monitor.suppressNextChange()
        }
        return true
    }

    @discardableResult
    func copy(items: [ClipItem], plainText: Bool = false) -> Bool {
        guard let first = items.first, write(items: items, plainText: plainText, store: .shared) else { return false }
        Store.shared.lastCopiedID = first.id
        SoundFeedback.shared.playCopy()
        return true
    }

    /// Native data goes to other apps; the private identifier only travels inside Trove.
    func itemProvider(for item: ClipItem) -> NSItemProvider {
        // ponytail: SwiftUI exposes one drag provider; a native dragging session is needed for multiple file icons.
        let provider = item.filePaths.first.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider()
        provider.suggestedName = item.title
        let identity = Data(item.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.itemIdentifier, visibility: .ownProcess) { completion in
            completion(identity, nil)
            return nil
        }
        let payloads = Store.shared.payloadData(for: item)
        let firstGroup = payloads.map(\.index).min() ?? 0
        for payload in payloads where payload.index == firstGroup {
            provider.registerDataRepresentation(forTypeIdentifier: payload.type, visibility: .all) { completion in
                completion(payload.data, nil)
                return nil
            }
        }
        if !payloads.contains(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue }),
           let text = item.text ?? item.urlString {
            provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue, visibility: .all) { completion in
                completion(Data(text.utf8), nil)
                return nil
            }
        }
        return provider
    }

    // MARK: Target and paste

    func rememberFrontmostTargetIfUnset() {
        if validTarget == nil { rememberFrontmostTarget() }
    }

    func rememberFrontmostTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pasteTarget = app
    }

    @discardableResult
    func paste(items: [ClipItem], plainText: Bool = false, hide: () -> Void) -> Bool {
        rememberFrontmostTargetIfUnset()
        let target = validTarget
        guard let first = items.first, write(items: items, plainText: plainText, store: .shared) else { return false }
        Store.shared.lastCopiedID = first.id
        guard Preferences.shared.pasteToActiveApp, hasAccessibility, let target else {
            SoundFeedback.shared.playCopy()
            return false
        }
        guard target.activate(options: []) else {
            lastError = "已复制，但无法激活目标应用。请切回目标应用按 ⌘V。"
            return false
        }
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard !target.isTerminated else { return }
            Paster.sendCommandV(to: target.processIdentifier)
            SoundFeedback.shared.playPaste()
        }
        return true
    }

    @discardableResult
    func pasteMultiple(items: [ClipItem], hide: () -> Void) -> Bool {
        paste(items: items, hide: hide)
    }

    func restoreTarget() {
        validTarget?.activate(options: [])
    }

    private static func sendCommandV(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}

@MainActor
final class SoundFeedback {
    static let shared = SoundFeedback()
    func playCopy() {
        guard Preferences.shared.soundEffects else { return }
        NSSound(named: "Tink")?.play()
    }
    func playPaste() {
        guard Preferences.shared.soundEffects else { return }
        NSSound(named: "Pop")?.play()
    }
}
