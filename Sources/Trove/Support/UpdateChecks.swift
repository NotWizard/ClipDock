import AppKit
import Foundation
import Sparkle

private final class UpdateFixtureProtocol: URLProtocol {
    static var responseCode = 200
    static var data = Data()
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.responseCode == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Disposable installer fixtures relaunch without command-line arguments. Their
/// private bundle marker keeps both launches isolated from the user's library.
final class UpdateProbeDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path) {
                DemoContent.prepare(update: false)
                Preferences.shared.historyLimit = 250
            }
            Store.shared.save(immediately: true)
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let record: [String: Any] = [
                "version": Bundle.main.shortVersion, "build": build,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "items": Store.shared.items.map { $0.id.uuidString },
                "pinboards": Store.shared.pinboards.map { $0.id.uuidString },
                "historyLimit": Preferences.shared.historyLimit,
                "shortcut": Preferences.shared.activateShortcut,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("probe-\(build).json"), options: .atomic)
            }
            if build == Bundle.main.object(forInfoDictionaryKey: "ClipDockUpdaterProbeExitVersion") as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }
    }
}

@MainActor
enum UpdateChecks {
    /// Exercises the real Sparkle installer against disposable external bundles only.
    static func checkInstallation(hostURL: URL, feedURL: URL, expectedExecutable: URL, expectRejection: Bool, cancelDownload: Bool) async -> Int32 {
        guard let host = Bundle(url: hostURL), host.bundleIdentifier?.hasPrefix("app.trove.updater-test.") == true,
              hostURL.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/") else {
            print("FAIL  installer check requires a disposable app.trove.updater-test.* bundle inside the temporary directory")
            return 1
        }
        let infoURL = hostURL.appendingPathComponent("Contents/Info.plist")
        let executableURL = hostURL.appendingPathComponent("Contents/MacOS/Trove")
        guard let beforeInfo = try? Data(contentsOf: infoURL), let beforeBinary = try? Data(contentsOf: executableURL) else { return 1 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let prefs = Preferences.shared
        prefs.automaticallyChecksForUpdates = false
        prefs.updateRepository = "NotWizard/ClipDock"
        let release = AppRelease(tagName: "v\(Bundle.main.shortVersion)",
                                 htmlURL: URL(string: "https://github.com/NotWizard/ClipDock/releases/tag/v\(Bundle.main.shortVersion)")!,
                                 body: "Disposable installer fixture", draft: false, prerelease: false)
        UpdateFixtureProtocol.responseCode = 200
        UpdateFixtureProtocol.data = try! JSONEncoder().encode(release)
        let updater = UpdateChecker(prefs: prefs, session: session, currentVersion: host.shortVersion, hostBundle: host, testFeedURL: feedURL)
        await updater.check()
        updater.downloadUpdate()
        let deadline = Date().addingTimeInterval(90)
        var previous: UpdateChecker.InstallState?
        var cancellationRequested = false
        while Date() < deadline {
            if updater.installState != previous {
                print("INSTALLER  \(updater.installState.rawValue)")
                previous = updater.installState
            }
            if cancelDownload, !cancellationRequested, updater.installState == .downloading, updater.downloadedBytes > 0 {
                cancellationRequested = true
                updater.cancelDownload()
            }
            if cancellationRequested, updater.installState == .idle {
                let unchanged = (try? Data(contentsOf: infoURL)) == beforeInfo && (try? Data(contentsOf: executableURL)) == beforeBinary
                print("\(unchanged ? "PASS" : "FAIL")  real download cancellation finished; original app intact=\(unchanged)")
                return unchanged ? 0 : 1
            }
            if updater.installState == .failed {
                var error = updater.installationError
                var signatureFailure = false
                var codes: [Int] = []
                while let current = error {
                    codes.append(current.code)
                    if current.domain == SUSparkleErrorDomain, [3001, 3002].contains(current.code) { signatureFailure = true }
                    error = current.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                let unchanged = (try? Data(contentsOf: infoURL)) == beforeInfo && (try? Data(contentsOf: executableURL)) == beforeBinary
                let passed = expectRejection && signatureFailure && unchanged
                print("\(passed ? "PASS" : "FAIL")  signed update rejection; original app intact=\(unchanged), error codes=\(codes), \(updater.lastError ?? "")")
                return passed ? 0 : 1
            }
            if updater.installState == .ready { updater.performUpdateAction() }
            if let data = try? Data(contentsOf: infoURL),
               let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               info["CFBundleVersion"] as? String == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
               info["CFBundleShortVersionString"] as? String == Bundle.main.shortVersion {
                let binary = try? Data(contentsOf: executableURL)
                let current = try? Data(contentsOf: expectedExecutable)
                let passed = !expectRejection && binary == current
                print("\(passed ? "PASS" : "FAIL")  real Sparkle download, verification, extraction and replacement; executable matches new build")
                return passed ? 0 : 1
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("FAIL  installer timed out: \(updater.status)")
        return 1
    }

    static func checkPublishedRelease() async -> Int32 {
        Preferences.shared.automaticallyChecksForUpdates = false
        let updater = UpdateChecker(currentVersion: "0.0.0")
        var prompted = false
        updater.onUpdateAvailable = { _ in prompted = true }
        await updater.check()
        guard let release = updater.available, prompted else {
            print("FAIL  live GitHub release: \(updater.status)")
            return 1
        }
        print("PASS  live GitHub release \(release.tagName): detected, validated, cached and notified")
        return 0
    }

    static func run() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ result: Bool) {
            print("\(result ? "PASS" : "FAIL")  \(label)")
            if !result { failures += 1 }
        }
        check("repository accepts GitHub HTTPS and .git", GitHubRepository("https://github.com/NotWizard/ClipDock.git")?.slug == "NotWizard/ClipDock")
        check("repository rejects foreign hosts and path traversal", GitHubRepository("https://evil.example/a/b") == nil && GitHubRepository("a/..") == nil)
        check("repository rejects credentials and query injection", GitHubRepository("https://user@github.com/a/b") == nil && GitHubRepository("a/b?x=1") == nil)
        let repository = GitHubRepository("NotWizard/ClipDock")!
        check("appcast stays inside the configured GitHub repository", repository.appcastURL.absoluteString == "https://github.com/NotWizard/ClipDock/releases/latest/download/appcast.xml")
        check("release URL restricted to the configured repository", !repository.containsReleaseURL(URL(string: "https://github.com/another/repo/releases/tag/v2.0.0")!) && !repository.containsReleaseURL(URL(string: "http://github.com/NotWizard/ClipDock/releases/tag/v2.0.0")!))
        check("version compares numbers rather than text", ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.9")!)
        check("major and minor versions compare correctly", ReleaseVersion("2.0.0")! > ReleaseVersion("1.99.99")! && ReleaseVersion("1.2")! == ReleaseVersion("1.2.0")!)
        check("build metadata is not a new version", ReleaseVersion("1.2.0+8")! == ReleaseVersion("v1.2.0+9")!)
        check("stable supersedes prerelease", ReleaseVersion("1.2.0")! > ReleaseVersion("1.2.0-rc.9")!)
        check("prerelease numbers compare numerically", ReleaseVersion("1.2.0-beta.11")! > ReleaseVersion("1.2.0-beta.2")!)
        check("invalid and overflowing versions are rejected", ReleaseVersion("latest") == nil && ReleaseVersion("1..2") == nil && ReleaseVersion("999999999999999999999999.0") == nil)
        let now = Date()
        check("first automatic check is due", UpdateChecker.isDue(lastCheck: nil, automatic: true, now: now))
        check("24-hour interval persists across launches", !UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-86399), automatic: true, now: now) && UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-86400), automatic: true, now: now))
        check("disabled automatic checks stay disabled", !UpdateChecker.isDue(lastCheck: nil, automatic: false))
        check("clock rollback does not defer updates forever", UpdateChecker.isDue(lastCheck: now.addingTimeInterval(3600), automatic: true, now: now))

        let prefs = Preferences.shared
        prefs.updateRepository = "NotWizard/ClipDock"
        prefs.automaticallyChecksForUpdates = true
        prefs.lastUpdateCheck = nil
        prefs.lastNotifiedUpdate = ""
        prefs.cachedUpdate = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func fixture(_ tag: String, draft: Bool = false, prerelease: Bool = false, url: String? = nil) {
            UpdateFixtureProtocol.responseCode = 200
            UpdateFixtureProtocol.data = try! JSONEncoder().encode(AppRelease(tagName: tag,
                htmlURL: URL(string: url ?? "https://github.com/NotWizard/ClipDock/releases/tag/\(tag)")!,
                body: "合成测试版本说明", draft: draft, prerelease: prerelease))
        }
        let updater = UpdateChecker(prefs: prefs, session: session, currentVersion: "1.2.0")
        var prompts = 0
        updater.onUpdateAvailable = { _ in prompts += 1 }
        fixture("v1.3.0")
        await updater.checkIfDue(now: now)
        check("new release is detected and prompts", updater.available?.tagName == "v1.3.0" && prompts == 1 && !updater.isChecking)
        check("last attempt is persisted", prefs.lastUpdateCheck == now)
        let count = UpdateFixtureProtocol.requests
        await updater.checkIfDue(now: now.addingTimeInterval(100))
        check("automatic checks do not repeat before 24 hours", UpdateFixtureProtocol.requests == count)
        await updater.check(manual: false)
        check("same release is not automatically prompted twice", prompts == 1)
        await updater.check(manual: true)
        check("manual check can reopen available update", prompts == 2)
        let restored = UpdateChecker(prefs: prefs, session: session, currentVersion: "1.2.0")
        check("available update survives relaunch", restored.available?.tagName == "v1.3.0")
        let upgraded = UpdateChecker(prefs: prefs, session: session, currentVersion: "1.3.0")
        check("installing the release clears stale availability", upgraded.available == nil)

        var cancelled = false
        updater.showDownloadInitiated { cancelled = true }
        check("download starts without assuming a known size", updater.installState == .downloading && updater.downloadProgress == nil && updater.canCancelDownload)
        updater.showDownloadDidReceiveExpectedContentLength(100)
        updater.showDownloadDidReceiveData(ofLength: 40)
        check("download exposes real byte progress", updater.downloadProgress == 0.4 && updater.downloadedBytes == 40)
        updater.showDownloadDidReceiveData(ofLength: UInt64.max)
        check("untrusted lengths cannot overflow progress", updater.downloadedBytes == UInt64.max && updater.downloadProgress == 1 && !updater.transferDescription.isEmpty)
        updater.cancelDownload()
        let cancelling = cancelled && updater.installState == .cancelling && !updater.canPerformUpdateAction
        updater.dismissUpdateInstallation()
        check("cancel waits for cleanup and retains release for retry", cancelling && updater.installState == .idle && updater.available?.tagName == "v1.3.0" && updater.canPerformUpdateAction)
        updater.showDownloadDidStartExtractingUpdate()
        check("validation cannot be interrupted as a download", updater.installState == .preparing && !updater.canCancelDownload && !updater.canPerformUpdateAction)
        var installed = 0
        updater.showReady { _ in installed += 1 }
        check("verified update waits for explicit install action", installed == 0 && updater.installState == .ready && updater.updateActionTitle == "安装并重启")
        let requestsBeforeReadyCheck = UpdateFixtureProtocol.requests
        await updater.check()
        check("checking while ready reopens the same update", UpdateFixtureProtocol.requests == requestsBeforeReadyCheck && updater.installState == .ready)
        updater.performUpdateAction()
        updater.performUpdateAction()
        check("install is committed once and cannot be double-triggered", installed == 1 && updater.installState == .installing)
        updater.dismissUpdateInstallation()
        var acknowledged = false
        updater.showUpdaterError(URLError(.notConnectedToInternet)) { acknowledged = true }
        updater.dismissUpdateInstallation()
        check("installation failure keeps release and retry state", acknowledged && updater.installState == .failed && updater.available != nil && updater.canPerformUpdateAction && updater.lastError != nil)

        prefs.updateRepository = "other/repo"
        check("cached release cannot cross repositories", UpdateChecker(prefs: prefs, session: session).available == nil)
        prefs.updateRepository = "NotWizard/ClipDock"
        fixture("v1.2.0")
        await updater.check()
        check("same version reports up to date", updater.available == nil && updater.status == "已是最新版本")
        fixture("v1.1.9")
        await updater.check()
        check("older release cannot offer a downgrade", updater.available == nil)
        fixture("v2.0.0-beta.1", prerelease: true)
        await updater.check()
        check("prereleases do not reach stable channel", updater.available == nil)
        fixture("v2.0.0", draft: true)
        await updater.check()
        check("draft releases are ignored", updater.available == nil)
        fixture("v3.0.0", url: "https://evil.example/download")
        await updater.check()
        check("untrusted download URL is rejected", updater.available == nil && updater.lastError != nil)
        fixture("latest")
        await updater.check()
        check("unversioned release reports an actionable error", updater.lastError != nil)
        UpdateFixtureProtocol.responseCode = 404
        await updater.check()
        check("no release is distinct from up-to-date", updater.status.contains("尚无正式 Release") && updater.lastError != nil)
        UpdateFixtureProtocol.responseCode = 429
        await updater.check()
        check("rate limiting gives retry feedback", updater.lastError?.contains("限制") == true)
        UpdateFixtureProtocol.responseCode = -1
        await updater.check()
        check("offline failure resets checking state", updater.lastError?.contains("网络") == true && !updater.isChecking)
        UpdateFixtureProtocol.responseCode = 200
        UpdateFixtureProtocol.data = Data("invalid".utf8)
        await updater.check()
        check("malformed server response is explained", updater.lastError?.contains("无法识别") == true)
        prefs.updateRepository = ""
        await updater.check()
        check("missing repository never makes a request", updater.status.contains("先设置") && !updater.isChecking)
        print(failures == 0 ? "UPDATE CHECKS OK" : "UPDATE FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
