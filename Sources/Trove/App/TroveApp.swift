import AppKit
import Combine
import ServiceManagement

@MainActor
final class TroveApp {
    static let shared = TroveApp()

    let store = Store.shared
    let prefs = Preferences.shared
    let updates = UpdateChecker.shared
    private(set) lazy var monitor = ClipboardMonitor(store: store, prefs: prefs)
    private(set) lazy var mainModel = MainViewModel(store: store, prefs: prefs)
    private(set) lazy var stackModel = PasteStackModel(store: store)

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    // MARK: Boot

    func start() {
        Paster.shared.startTrackingTarget()
        // Capture source app tracking needs a frontmost app at all times.
        monitor.start()
        monitor.onCapture = { [weak self] _ in
            self?.stackModel.objectWillChange.send()
        }

        wireHotKeys()
        observePreferences()
        updates.onUpdateAvailable = { _ in TroveWindows.shared.showUpdate() }
        updates.start()
        applyLoginItem()

        // Pay the one-off Vision model compile in the background so the first
        // screenshot capture doesn't wait for it.
        OCRService.shared.prewarm()

        // Seed an empty pinboard so the sidebar isn't a dead end on first run.
        if store.pinboards.isEmpty && !prefs.hasCompletedOnboarding {
            store.createPinboard(name: "常用片段", colorHex: Pinboard.palette[1])
        }
    }

    // MARK: Hot keys

    private func wireHotKeys() {
        let hotKeys = HotKeyCenter.shared

        hotKeys.setHandler(for: .activate) { [weak self] in
            self?.toggleClipboardPanel()
        }
        hotKeys.setHandler(for: .quickPaste) { [weak self] in
            self?.showQuickPaste()
        }
        hotKeys.setHandler(for: .pasteStack) { [weak self] in
            guard let self else { return }
            if !self.stackModel.isEmpty {
                Paster.shared.rememberFrontmostTarget()
                self.stackModel.pasteNext { TroveWindows.shared.hideAll() }
            } else {
                TroveWindows.shared.showPasteStack()
            }
        }
        hotKeys.setHandler(for: .plainText) { [weak self] in
            self?.quickPaste(plainText: true)
        }
        hotKeys.setHandler(for: .nextPinboard) { [weak self] in
            self?.cyclePinboard(forward: true)
        }
        hotKeys.setHandler(for: .previousPinboard) { [weak self] in
            self?.cyclePinboard(forward: false)
        }

        hotKeys.apply(from: prefs)
    }

    private func observePreferences() {
        prefs.$showMenuBarIcon
            .sink { visible in
                StatusBarController.shared.setVisible(visible)
            }
            .store(in: &cancellables)

        prefs.$openAtLogin
            .dropFirst()
            .sink { [weak self] _ in self?.applyLoginItem() }
            .store(in: &cancellables)

        monitor.$isPaused
            .dropFirst()
            .sink { _ in StatusBarController.shared.refresh() }
            .store(in: &cancellables)
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if prefs.openAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("Trove: login item update failed — \(error.localizedDescription)")
        }
    }

    // MARK: Window actions

    func toggleClipboardPanel() {
        if TroveWindows.shared.quickPanel?.isVisible == true {
            TroveWindows.shared.closeQuickPaste()
        } else {
            TroveWindows.shared.showQuickPaste()
        }
    }

    func showQuickPaste() {
        TroveWindows.shared.showQuickPaste()
    }

    func quickPaste(plainText: Bool) {
        Paster.shared.rememberFrontmostTarget()
        if TroveWindows.shared.quickPanel?.isVisible != true { TroveWindows.shared.showQuickPaste() }
        TroveWindows.shared.commitSelection(plainText: plainText)
    }

    func cyclePinboard(forward: Bool) {
        if TroveWindows.shared.quickPanel?.isVisible != true { TroveWindows.shared.showQuickPaste() }
        mainModel.cycleDestination(forward: forward)
    }

    // MARK: Capture control

    func pauseCapture(_ interval: TimeInterval?) {
        monitor.pause(for: interval)
        StatusBarController.shared.refresh()
    }

    func resumeCapture() {
        monitor.resume()
        StatusBarController.shared.refresh()
    }

    var isPaused: Bool { monitor.isPaused }

    var pauseDescription: String {
        guard let until = monitor.pausedUntil else { return "Paused" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Paused until \(formatter.string(from: until))"
    }
}
