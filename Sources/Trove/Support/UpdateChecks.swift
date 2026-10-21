import AppKit
import Foundation

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

@MainActor
enum UpdateChecks {
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
