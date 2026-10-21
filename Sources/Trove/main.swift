import AppKit

final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    let name: String
    let path: String
    init(name: String, path: String) { self.name = name; self.path = path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            SelfTest.snapshot(named: name, to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}

final class PanelCheckDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    var status: Int32 = 1
    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = MainActor.assumeIsolated { SelfTest.checkPanel(to: directory) }
        NSApp.terminate(nil)
    }
}

// Trove uses an AppKit shell (LSUIElement menu-bar app) with SwiftUI content
// hosted in NSWindow / NSPanel instances. This keeps full control over status
// item behaviour, the floating quick-paste HUD, and window activation.
//
// Two headless modes exist for verification:
//   Trove --selftest            run storage/query/pasteboard checks and exit
//   Trove --render-previews DIR render every screen to PNG and exit

let arguments = CommandLine.arguments

if arguments.contains("--check-updates") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDock-updatecheck-\(UUID().uuidString)")
    setenv("TROVE_TEST_DATA_DIR", root.path, 1)
    let status = MainActor.assumeIsolated { () -> Int32 in
        var status: Int32?
        Task { status = arguments.contains("--live") ? await UpdateChecks.checkPublishedRelease() : await UpdateChecks.run() }
        while status == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return status!
    }
    try? FileManager.default.removeItem(at: root)
    UserDefaults.standard.removePersistentDomain(forName: "app.trove.test.\(root.lastPathComponent)")
    exit(status)
}

if let index = arguments.firstIndex(of: "--check-panel"), arguments.count > index + 1 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Trove-panelcheck-\(UUID().uuidString)")
    setenv("TROVE_TEST_DATA_DIR", root.path, 1)
    let delegate = PanelCheckDelegate(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    try? FileManager.default.removeItem(at: root)
    UserDefaults.standard.removePersistentDomain(forName: "app.trove.test.\(root.lastPathComponent)")
    exit(delegate.status)
}

if arguments.contains("--selftest") {
    let status = MainActor.assumeIsolated { SelfTest.run() }
    exit(status)
}

if arguments.contains("--check-hotkeys") {
    let status = MainActor.assumeIsolated { SelfTest.checkHotKeys() }
    exit(status)
}

if let index = arguments.firstIndex(of: "--render-previews"), arguments.count > index + 1 {
    MainActor.assumeIsolated { SelfTest.renderPreviews(to: arguments[index + 1]) }
    exit(0)
}

if let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 2 {
    if arguments.contains("--demo") || arguments.contains("--demo-update") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDock-demo-\(UUID().uuidString)")
        setenv("TROVE_TEST_DATA_DIR", root.path, 1)
        MainActor.assumeIsolated { DemoContent.prepare(update: arguments.contains("--demo-update")) }
    }
    let name = arguments[index + 1]
    let path = arguments[index + 2]
    let appearanceIndex = arguments.firstIndex(of: "--appearance")
    let appearance = (appearanceIndex.flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }) ?? "dark"
    let snapshotDelegate = SnapshotDelegate(name: name, path: path)
    let app = NSApplication.shared
    app.delegate = snapshotDelegate
    app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

let app = NSApplication.shared
if arguments.contains("--demo") || arguments.contains("--demo-update") || arguments.contains("--demo-onboarding") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDock-demo-\(UUID().uuidString)")
    setenv("TROVE_TEST_DATA_DIR", root.path, 1)
    MainActor.assumeIsolated { DemoContent.prepare(update: arguments.contains("--demo-update")) }
    if arguments.contains("--demo-onboarding") {
        MainActor.assumeIsolated { Preferences.shared.hasCompletedOnboarding = false }
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if arguments.contains("--demo-update") {
    DispatchQueue.main.async { TroveWindows.shared.closeQuickPaste(restoreTarget: false); TroveWindows.shared.showMainWindow() }
}
app.run()
