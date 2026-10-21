import AppKit
import SwiftUI
import QuartzCore

/// Owns every window in the app so they can be created lazily and hidden together.
@MainActor
final class TroveWindows {
    static let shared = TroveWindows()

    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var stackWindow: NSWindow?
    var quickPanel: QuickPanel?
    var onboardingWindow: NSWindow?
    var updateWindow: NSWindow?
    private var previewWindows: [UUID: NSWindow] = [:]
    private var keyMonitors: [ObjectIdentifier: Any] = [:]
    private var outsideClickMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var dismissalWorkItem: DispatchWorkItem?
    private var presentationID = UUID()

    var mainModel: MainViewModel { TroveApp.shared.mainModel }
    var stackModel: PasteStackModel { TroveApp.shared.stackModel }

    // MARK: Main window

    func showMainWindow() {
        Paster.shared.rememberFrontmostTarget()
        if mainWindow == nil { buildMainWindow() }
        guard let window = mainWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    private func buildMainWindow() {
        let view = MainWindowView(
            store: TroveApp.shared.store,
            prefs: TroveApp.shared.prefs,
            model: TroveApp.shared.mainModel
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("TroveMainWindow")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowDelegateKeeper.shared
        mainWindow = window
        installKeyMonitor(for: window, kind: .main)
    }

    // MARK: Primary clipboard panel

    func showQuickPaste() {
        Paster.shared.rememberFrontmostTarget()
        dismissalWorkItem?.cancel()
        let id = UUID()
        presentationID = id
        mainModel.preparePanel()

        if quickPanel == nil {
            let panel = QuickPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.title = "\(AppIdentity.name) — 剪贴板"
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.contentView = NSHostingView(rootView: QuickPasteView(
                model: mainModel, store: TroveApp.shared.store, prefs: TroveApp.shared.prefs
            ))
            quickPanel = panel
            installKeyMonitor(for: panel, kind: .quick)
            installDismissalMonitors()
        }
        guard let panel = quickPanel else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frame = Self.clipboardPanelFrame(in: screen.frame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if panel.isVisible {
            panel.setFrame(frame, display: true)
        } else {
            panel.setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: -18), display: true)
            panel.alphaValue = reduceMotion ? 1 : 0
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        mainModel.searchFocusRequest += 1
    }

    static func clipboardPanelFrame(in screenFrame: NSRect) -> NSRect {
        NSRect(x: screenFrame.minX + 8, y: screenFrame.minY + 8,
               width: max(0, screenFrame.width - 16), height: min(332, max(0, screenFrame.height - 16)))
    }

    func closeQuickPaste(restoreTarget: Bool = true) {
        dismissalWorkItem?.cancel()
        guard let panel = quickPanel, panel.isVisible else { return }
        let id = UUID()
        presentationID = id
        mainModel.previewID = nil
        mainModel.showFilters = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            if !reduceMotion { panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -12), display: true) }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentationID == id else { return }
                panel.orderOut(nil)
                if restoreTarget { Paster.shared.restoreTarget() }
            }
        })
    }

    func hideAll() {
        dismissalWorkItem?.cancel()
        presentationID = UUID()
        mainModel.previewID = nil
        mainModel.showFilters = false
        quickPanel?.orderOut(nil)
        mainWindow?.orderOut(nil)
        stackWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        for window in previewWindows.values { window.orderOut(nil) }
    }

    func commitSelection(copyOnly: Bool = false, plainText: Bool = false) {
        let chosen = mainModel.selectedItems
        guard !chosen.isEmpty else { return }
        dismissalWorkItem?.cancel()
        let plain = plainText || mainModel.plainTextMode
        let paster = Paster.shared
        if !copyOnly, paster.paste(items: chosen, plainText: plain, hide: { self.hideAll() }) { return }
        if copyOnly, !paster.copy(items: chosen, plainText: plain) {
            mainModel.feedback = paster.lastError ?? "复制失败，请重试。"
            return
        }
        if let error = paster.lastError { mainModel.feedback = error; return }
        mainModel.feedback = "已复制 · 在目标应用按 ⌘V 粘贴"
        if quickPanel?.isVisible == true {
            let work = DispatchWorkItem { [weak self] in self?.closeQuickPaste() }
            dismissalWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
    }

    private func installDismissalMonitors() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeQuickPaste(restoreTarget: false) }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.closeQuickPaste(restoreTarget: false)
            }
        }
    }

    // MARK: Settings

    func showSettings(about: Bool = false) {
        closeQuickPaste(restoreTarget: false)
        if settingsWindow == nil {
            let view = SettingsView(prefs: TroveApp.shared.prefs, store: TroveApp.shared.store, initialTab: about ? .about : .general)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "\(AppIdentity.name) 设置"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = WindowDelegateKeeper.shared
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if about {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .clipdockShowUpdates, object: nil) }
        }
    }

    func showUpdate() {
        guard UpdateChecker.shared.available != nil else { return }
        closeQuickPaste(restoreTarget: false)
        if updateWindow == nil {
            let view = UpdatePrompt(updates: .shared) { TroveWindows.shared.updateWindow?.orderOut(nil) }
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "\(AppIdentity.name) 更新"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            updateWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Paste stack

    func showPasteStack() {
        Paster.shared.rememberFrontmostTarget()
        closeQuickPaste(restoreTarget: false)
        if stackWindow == nil {
            let view = PasteStackView(
                model: TroveApp.shared.stackModel,
                store: TroveApp.shared.store,
                close: { TroveWindows.shared.stackWindow?.orderOut(nil) }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Paste Stack"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = WindowDelegateKeeper.shared
            stackWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        stackWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Preview

    func previewWindow(for item: ClipItem, store: Store) -> NSWindow? {
        if let existing = previewWindows[item.id] {
            return existing
        }
        let view = ItemPreviewWindowView(
            item: item,
            store: store,
            close: { TroveWindows.shared.previewWindows[item.id]?.orderOut(nil) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = item.title
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowDelegateKeeper.shared
        previewWindows[item.id] = window
        return window
    }

    // MARK: Onboarding

    func showOnboarding() {
        hideAll()
        if let window = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(prefs: TroveApp.shared.prefs) {
            TroveWindows.shared.finishOnboarding()
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 \(AppIdentity.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowDelegateKeeper.shared
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func finishOnboarding() {
        TroveApp.shared.prefs.hasCompletedOnboarding = true
        onboardingWindow?.delegate = nil
        onboardingWindow?.close()
        onboardingWindow = nil
        showQuickPaste()
    }

    // MARK: Keyboard

    private enum MonitorKind { case main, quick }

    func handlePanelEvent(_ event: NSEvent) -> Bool {
        handle(event: event, kind: .quick)
    }

    private func installKeyMonitor(for window: NSWindow, kind: MonitorKind) {
        let token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch kind {
            case .main:
                guard event.window === window, window.isKeyWindow, event.type == .keyDown else { return event }
            case .quick:
                guard window.isVisible,
                      event.window === window || (event.type == .flagsChanged && window.isKeyWindow) || self.mainModel.previewID != nil else { return event }
                return self.handlePanelEvent(event) ? nil : event
            }
            return self.handle(event: event, kind: kind) ? nil : event
        }
        if let token { keyMonitors[ObjectIdentifier(window)] = token }
    }

    private func handle(event: NSEvent, kind: MonitorKind) -> Bool {
        let isTyping: Bool = {
            guard let responder = event.window?.firstResponder else { return false }
            return responder is NSTextView
        }()

        switch kind {
        case .quick:
            let model = mainModel
            if event.type == .flagsChanged {
                model.showNumberHints = event.modifierFlags.contains(.command)
                model.plainTextMode = event.modifierFlags.contains(.shift)
                return false
            }
            if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            if model.showNewPinboard { return false }
            if event.window !== quickPanel, model.previewID != nil {
                if event.keyCode == 53 || (event.keyCode == 49 && !isTyping) {
                    model.previewID = nil
                    model.searchFocusRequest += 1
                    return true
                }
                return false
            }
            let flags = event.modifierFlags
            if flags.contains(.command) {
                if let number = Int(KeyCodeNames.name(for: UInt32(event.keyCode))), (1...9).contains(number) {
                    if model.selectQuickItem(number - 1) { commitSelection(plainText: flags.contains(.shift)) }
                    return true
                }
                switch event.keyCode {
                case 3:
                    model.isSearching = true
                    model.searchFocusRequest += 1
                    return true
                case 123 where !model.isSearching, 124 where !model.isSearching:
                    model.cycleDestination(forward: event.keyCode == 124)
                    return true
                case 45 where flags.contains(.shift):
                    model.showNewPinboard = true
                    return true
                case 0 where !model.isSearching:
                    model.selectAll()
                    return true
                case 8 where !model.isSearching:
                    commitSelection(copyOnly: true, plainText: flags.contains(.shift))
                    return true
                case 43:
                    showSettings()
                    return true
                default: break
                }
            }
            switch event.keyCode {
            case 53:
                if model.previewID != nil { model.previewID = nil; model.searchFocusRequest += 1 }
                else if model.showFilters { model.showFilters = false }
                else if !model.query.isEmpty { model.query = "" }
                else if model.isSearching { model.isSearching = false; model.searchFocusRequest += 1 }
                else { closeQuickPaste() }
                return true
            case 36, 76:
                commitSelection(copyOnly: flags.contains(.command), plainText: flags.contains(.shift))
                return true
            case 49 where !model.isSearching:
                model.previewEditing = false
                model.previewID = model.previewID == nil ? model.current?.id : nil
                return true
            case 123 where !model.isSearching, 124 where !model.isSearching:
                model.previewID = nil
                model.moveSelection(by: event.keyCode == 124 ? 1 : -1)
                return true
            case 125, 126:
                guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
                model.moveSelection(by: event.keyCode == 125 ? 1 : -1)
                return true
            case 51 where !model.isSearching, 117 where !model.isSearching:
                model.deleteSelection()
                model.reconcileSelection()
                return true
            default:
                return false
            }

        case .main:
            let model = TroveApp.shared.mainModel
            switch event.keyCode {
            case 3 where event.modifierFlags.contains(.command): // ⌘F
                NotificationCenter.default.post(name: .troveFocusSearch, object: nil)
                return true
            case 53:
                if model.query.isEmpty { hideMainWindow() } else { model.query = "" }
                return true
            case 49 where !isTyping: // space
                if let item = model.selectedItems.first,
                   let window = previewWindow(for: item, store: TroveApp.shared.store) {
                    window.makeKeyAndOrderFront(nil)
                }
                return true
            case 36 where !isTyping, 76 where !isTyping:
                model.pasteSelection()
                return true
            case 51 where !isTyping, 117 where !isTyping:
                model.deleteSelection()
                return true
            case 125 where !isTyping:
                model.moveSelection(by: 1)
                return true
            case 126 where !isTyping:
                model.moveSelection(by: -1)
                return true
            case 8 where event.modifierFlags.contains(.command) && !isTyping: // ⌘C
                model.copySelection()
                return true
            default:
                return false
            }
        }
    }
}

extension Notification.Name {
    static let troveFocusSearch = Notification.Name("trove.focusSearch")
}

// MARK: - Panel

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Delegates

@MainActor
final class WindowDelegateKeeper: NSObject, NSWindowDelegate {
    static let shared = WindowDelegateKeeper()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === TroveWindows.shared.onboardingWindow {
            TroveWindows.shared.finishOnboarding()
            return false
        }
        sender.orderOut(nil)
        return false
    }
}
