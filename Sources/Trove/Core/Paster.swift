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
    private(set) var isPasting = false
    private var activationObserver: NSObjectProtocol?

    var hasAccessibility: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var destinationName: String { validTarget?.localizedName ?? "当前应用" }

    private var validTarget: NSRunningApplication? {
        guard let target = pasteTarget, !target.isTerminated,
              target.bundleIdentifier != "com.apple.loginwindow",
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
    func write(items: [ClipItem], plainText: Bool = false, store: Store, pasteboard: NSPasteboard = .general, promote: Bool = true) -> Bool {
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
        if promote { markUsed(items, store: store) }
        return true
    }

    func markUsed(_ items: [ClipItem], store: Store) {
        // Reverse the batch so the first selected item remains first; keep manual Pinboard order.
        for clip in items.reversed() where clip.pinboardID == nil { store.moveToTop(clip.id) }
        store.lastCopiedID = items.first?.id
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
              app.bundleIdentifier != "com.apple.loginwindow",
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        pasteTarget = app
    }

    @discardableResult
    func paste(items: [ClipItem], plainText: Bool = false,
               hide: (@escaping (Bool) -> Void) -> Void,
               completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard !isPasting else { return false }
        rememberFrontmostTargetIfUnset()
        let target = validTarget
        guard !items.isEmpty, write(items: items, plainText: plainText, store: .shared, promote: false) else { return false }
        guard Preferences.shared.pasteToActiveApp else {
            markUsed(items, store: .shared)
            SoundFeedback.shared.playCopy()
            return false
        }
        guard hasAccessibility else {
            lastError = AXIsProcessTrusted()
                ? "已复制，但 macOS 尚未允许 ClipDock 发送粘贴按键。请在系统设置中重新启用 ClipDock 的辅助功能权限。"
                : "已复制，但 ClipDock 的辅助功能授权尚未生效。请在系统设置中重新启用 ClipDock 后重试。"
            return false
        }
        guard let target else {
            lastError = "已复制，但未找到唤起前的目标应用。请回到需要粘贴的输入框，再唤起剪贴板。"
            return false
        }
        let changeCount = NSPasteboard.general.changeCount
        isPasting = true
        hide { [self] didHide in
            guard didHide else { isPasting = false; completion(false); return }
            Task { @MainActor in
                defer { isPasting = false }
                guard !target.isTerminated, target.activate(options: []) else {
                    lastError = "已复制，但无法恢复目标应用。请切回目标输入框按 ⌘V。"
                    completion(false)
                    return
                }
                // Allow the window server to release the nonactivating panel's keyboard focus.
                // Never retry Cmd-V: macOS does not provide a receipt for the resulting paste.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard NSPasteboard.general.changeCount == changeCount else {
                        lastError = "剪贴板在回贴前已改变，本次粘贴已取消。请重新选择条目。"
                        completion(false)
                        return
                    }
                    guard !target.isTerminated else { break }
                    if target.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                       NSApp.keyWindow == nil {
                        guard Self.sendCommandV() else { break }
                        markUsed(items, store: .shared)
                        SoundFeedback.shared.playPaste()
                        completion(true)
                        return
                    }
                }
                lastError = "已复制，但未能恢复目标输入焦点。请切回目标输入框按 ⌘V。"
                completion(false)
            }
        }
        return true
    }

    @discardableResult
    func pasteMultiple(items: [ClipItem], hide: (@escaping (Bool) -> Void) -> Void) -> Bool {
        paste(items: items, hide: hide)
    }

    func restoreTarget() {
        validTarget?.activate(options: [])
    }

    private static func sendCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
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
