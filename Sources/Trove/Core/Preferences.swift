import AppKit
import Foundation

/// UserDefaults-backed preferences. Kept small and explicit.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let defaultActivateShortcut = "9:768"
    static let defaultQuickPasteShortcut = "9:4352"
    static let defaultPasteStackShortcut = "9:6400"

    private let d: UserDefaults

    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    @Published var openAtLogin: Bool { didSet { d.set(openAtLogin, forKey: "openAtLogin") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var soundEffects: Bool { didSet { d.set(soundEffects, forKey: "soundEffects") } }

    @Published var pasteToActiveApp: Bool { didSet { d.set(pasteToActiveApp, forKey: "pasteToActiveApp") } }
    @Published var alwaysPlainText: Bool { didSet { d.set(alwaysPlainText, forKey: "alwaysPlainText") } }

    @Published var ignoreConfidential: Bool { didSet { d.set(ignoreConfidential, forKey: "ignoreConfidential") } }
    @Published var ignoreTransient: Bool { didSet { d.set(ignoreTransient, forKey: "ignoreTransient") } }
    @Published var generateLinkPreviews: Bool { didSet { d.set(generateLinkPreviews, forKey: "generateLinkPreviews") } }

    @Published var ignoredBundleIDs: [String] { didSet { d.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") } }

    // Shortcuts stored as "keyCode:carbonModifiers" or "" when disabled.
    @Published var activateShortcut: String { didSet { d.set(activateShortcut, forKey: "activateShortcut") } }
    @Published var quickPasteShortcut: String { didSet { d.set(quickPasteShortcut, forKey: "quickPasteShortcut") } }
    @Published var pasteStackShortcut: String { didSet { d.set(pasteStackShortcut, forKey: "pasteStackShortcut") } }
    @Published var plainTextShortcut: String { didSet { d.set(plainTextShortcut, forKey: "plainTextShortcut") } }
    @Published var nextPinboardShortcut: String { didSet { d.set(nextPinboardShortcut, forKey: "nextPinboardShortcut") } }
    @Published var previousPinboardShortcut: String { didSet { d.set(previousPinboardShortcut, forKey: "previousPinboardShortcut") } }

    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    @Published var automaticallyChecksForUpdates: Bool { didSet { d.set(automaticallyChecksForUpdates, forKey: "automaticallyChecksForUpdates") } }
    @Published var updateRepository: String { didSet { d.set(updateRepository, forKey: "updateRepository") } }
    @Published var lastUpdateCheck: Date? { didSet { d.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    var cachedUpdate: Data? { get { d.data(forKey: "cachedUpdate") } set { d.set(newValue, forKey: "cachedUpdate") } }
    var lastNotifiedUpdate: String { get { d.string(forKey: "lastNotifiedUpdate") ?? "" } set { d.set(newValue, forKey: "lastNotifiedUpdate") } }

    private init() {
        if let testDirectory = ProcessInfo.processInfo.environment["TROVE_TEST_DATA_DIR"] {
            d = UserDefaults(suiteName: "app.trove.test.\(URL(fileURLWithPath: testDirectory).lastPathComponent)")!
        } else {
            d = .standard
        }
        d.register(defaults: [
            "historyLimit": 500,
            "openAtLogin": false,
            "showMenuBarIcon": true,
            "soundEffects": true,
            "pasteToActiveApp": true,
            "alwaysPlainText": false,
            "ignoreConfidential": true,
            "ignoreTransient": true,
            "generateLinkPreviews": true,
            "ignoredBundleIDs": [String](),
            "activateShortcut": Self.defaultActivateShortcut,
            "quickPasteShortcut": Self.defaultQuickPasteShortcut,
            "pasteStackShortcut": Self.defaultPasteStackShortcut,
            "plainTextShortcut": "",
            "nextPinboardShortcut": "",
            "previousPinboardShortcut": "",
            "hasCompletedOnboarding": false,
            "automaticallyChecksForUpdates": true,
            "updateRepository": Bundle.main.object(forInfoDictionaryKey: "GitHubRepository") as? String ?? "NotWizard/ClipDock",
        ])

        historyLimit = d.integer(forKey: "historyLimit")
        openAtLogin = d.bool(forKey: "openAtLogin")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        soundEffects = d.bool(forKey: "soundEffects")
        pasteToActiveApp = d.bool(forKey: "pasteToActiveApp")
        alwaysPlainText = d.bool(forKey: "alwaysPlainText")
        ignoreConfidential = d.bool(forKey: "ignoreConfidential")
        ignoreTransient = d.bool(forKey: "ignoreTransient")
        generateLinkPreviews = d.bool(forKey: "generateLinkPreviews")
        ignoredBundleIDs = d.stringArray(forKey: "ignoredBundleIDs") ?? []
        activateShortcut = d.string(forKey: "activateShortcut") ?? ""
        quickPasteShortcut = d.string(forKey: "quickPasteShortcut") ?? ""
        pasteStackShortcut = d.string(forKey: "pasteStackShortcut") ?? ""
        plainTextShortcut = d.string(forKey: "plainTextShortcut") ?? ""
        nextPinboardShortcut = d.string(forKey: "nextPinboardShortcut") ?? ""
        previousPinboardShortcut = d.string(forKey: "previousPinboardShortcut") ?? ""
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")
        automaticallyChecksForUpdates = d.bool(forKey: "automaticallyChecksForUpdates")
        updateRepository = d.string(forKey: "updateRepository") ?? ""
        lastUpdateCheck = d.object(forKey: "lastUpdateCheck") as? Date

        migrateBrokenShortcuts()
    }

    /// Earlier builds shipped Carbon masks that do not exist (524288, 6488064)
    /// and collided with the activation shortcut. Rewrite them once.
    private func migrateBrokenShortcuts() {
        let broken: [String: String] = [
            "9:524288": "9:4352",
            "9:6488064": "9:6400",
            "9:4352": "9:768",
        ]
        if let current = broken[activateShortcut] {
            activateShortcut = current
        }
        if let current = broken[quickPasteShortcut], current != activateShortcut {
            quickPasteShortcut = current
        }
        if let current = broken[pasteStackShortcut], current != quickPasteShortcut {
            pasteStackShortcut = current
        }
    }

    func addIgnoredApp(_ bundleID: String) {
        guard !ignoredBundleIDs.contains(bundleID) else { return }
        ignoredBundleIDs.append(bundleID)
    }

    func removeIgnoredApp(_ bundleID: String) {
        ignoredBundleIDs.removeAll { $0 == bundleID }
    }

    func resetShortcutDefaults() {
        activateShortcut = Self.defaultActivateShortcut
        quickPasteShortcut = Self.defaultQuickPasteShortcut
        pasteStackShortcut = Self.defaultPasteStackShortcut
        plainTextShortcut = ""
        nextPinboardShortcut = ""
        previousPinboardShortcut = ""
    }
}
