import AppKit
import Combine
import Foundation
import Sparkle

enum AppIdentity {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ClipDock" }
}

struct GitHubRepository: Equatable {
    let slug: String
    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") {
            guard let url = URLComponents(string: value), url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        slug = parts.joined(separator: "/")
    }
    var apiURL: URL { URL(string: "https://api.github.com/repos/\(slug)/releases/latest")! }
    var releasesURL: URL { URL(string: "https://github.com/\(slug)/releases")! }
    var appcastURL: URL { releasesURL.appendingPathComponent("latest/download/appcast.xml") }

    func containsReleaseURL(_ url: URL) -> Bool {
        let path = url.pathComponents
        let base = slug.split(separator: "/").map(String.init)
        return url.scheme == "https" && url.host?.lowercased() == "github.com" && url.user == nil && url.password == nil && url.port == nil &&
            path.count == 6 && Array(path[1...2]).map { $0.lowercased() } == base.map { $0.lowercased() } && path[3] == "releases" && path[4] == "tag"
    }
}

/// Release tags use vMAJOR.MINOR.PATCH; build metadata does not change precedence.
struct ReleaseVersion: Comparable {
    let numbers: [UInt]
    let prerelease: [String]
    init?(_ input: String) {
        var value = input
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let main = value.split(separator: "+", omittingEmptySubsequences: false)
        guard main.count <= 2, main.count == 1 || !main[1].isEmpty else { return nil }
        let parts = main[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(core.count), core.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              core.compactMap({ UInt($0) }).count == core.count else { return nil }
        numbers = core.compactMap { UInt($0) } + Array(repeating: 0, count: 3 - core.count)
        let pre = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { return nil }
        prerelease = pre
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = UInt(a), let y = UInt(b) { return x < y }
            if UInt(a) != nil { return true }
            if UInt(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct AppRelease: Codable, Equatable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease
    }
}

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    static let interval: TimeInterval = 24 * 60 * 60

    @Published private(set) var isChecking = false
    @Published private(set) var available: AppRelease?
    @Published private(set) var status = "可检查新版本"
    @Published private(set) var lastError: String?
    enum InstallState: String {
        case idle, checking, downloading, cancelling, preparing, ready, installing, failed
    }
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var downloadedBytes: UInt64 = 0
    @Published private(set) var expectedBytes: UInt64 = 0
    private(set) var installationError: NSError?
    var onUpdateAvailable: ((AppRelease) -> Void)?

    private let prefs: Preferences
    private let session: URLSession
    private let currentVersion: String
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0
    private let hostBundle: Bundle
    private let testFeedURL: URL?
    private var installer: SPUUpdater?
    private var installerRepository: GitHubRepository?
    private var cancelTransfer: (() -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?

    var installationInProgress: Bool { ![.idle, .failed].contains(installState) }
    var canCancelDownload: Bool { cancelTransfer != nil }
    var downloadProgress: Double? {
        expectedBytes == 0 ? nil : min(1, Double(downloadedBytes) / Double(expectedBytes))
    }
    var transferDescription: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: Int64(clamping: downloadedBytes), countStyle: .file)
        guard expectedBytes > 0 else { return "已下载 \(downloaded)" }
        return "\(downloaded) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: expectedBytes), countStyle: .file))"
    }
    var updateActionTitle: String {
        switch installState {
        case .ready: return "安装并重启"
        case .checking: return "正在准备…"
        case .downloading: return "正在下载…"
        case .cancelling: return "正在取消…"
        case .preparing: return "正在校验…"
        case .installing: return "正在安装…"
        case .failed: return "重试下载"
        case .idle: return "下载更新"
        }
    }
    var canPerformUpdateAction: Bool { available != nil && !isChecking && [.idle, .failed, .ready].contains(installState) }

    private struct CachedRelease: Codable {
        let repository: String
        let release: AppRelease
    }

    init(prefs: Preferences? = nil, session: URLSession = .shared, currentVersion: String = Bundle.main.shortVersion,
         hostBundle: Bundle = .main, testFeedURL: URL? = nil) {
        self.prefs = prefs ?? .shared
        self.session = session
        self.currentVersion = currentVersion
        self.hostBundle = hostBundle
        self.testFeedURL = testFeedURL
        super.init()
        restoreCachedRelease()
    }

    var repository: GitHubRepository? { GitHubRepository(prefs.updateRepository) }

    func start() {
        prefs.$automaticallyChecksForUpdates.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
        prefs.$updateRepository.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.repositoryChanged() }.store(in: &cancellables)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        Task { await checkIfDue() }
    }

    static func isDue(lastCheck: Date?, automatic: Bool, now: Date = Date()) -> Bool {
        guard automatic else { return false }
        guard let lastCheck else { return true }
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
    }

    func checkIfDue(now: Date = Date()) async {
        if Self.isDue(lastCheck: prefs.lastUpdateCheck, automatic: prefs.automaticallyChecksForUpdates, now: now) {
            await check(manual: false, now: now)
        } else { schedule() }
    }

    func check(manual: Bool = true, now: Date = Date()) async {
        if installationInProgress {
            if manual { showAvailableUpdate() }
            return
        }
        guard !isChecking else { return }
        guard let repository else {
            status = "请先设置 GitHub 更新仓库"
            lastError = nil
            return
        }
        isChecking = true
        lastError = nil
        status = "正在检查更新…"
        prefs.lastUpdateCheck = now
        let requestGeneration = generation
        var request = URLRequest(url: repository.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClipDock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard requestGeneration == generation else { return }
            guard let response = response as? HTTPURLResponse else { throw UpdateFailure("无法读取服务器响应，请稍后重试。") }
            switch response.statusCode {
            case 404:
                status = "仓库尚无正式 Release，或仓库不可公开访问。"
                lastError = status
            case 403, 429:
                throw UpdateFailure("GitHub 暂时限制了检查请求，请稍后再试。")
            case 200:
                guard data.count <= 2 * 1024 * 1024 else { throw UpdateFailure("更新信息过大，无法读取。") }
                guard let release = try? JSONDecoder().decode(AppRelease.self, from: data) else {
                    throw UpdateFailure("服务器返回了无法识别的更新信息，请稍后重试。")
                }
                guard let version = ReleaseVersion(release.tagName), let current = ReleaseVersion(currentVersion),
                      repository.containsReleaseURL(release.htmlURL) else { throw UpdateFailure("Release 版本或下载页面无效，请联系发布者。") }
                guard !release.draft, !release.prerelease, version.prerelease.isEmpty else {
                    status = "暂无新的正式版本"
                    break
                }
                if version > current {
                    available = release
                    prefs.cachedUpdate = try JSONEncoder().encode(CachedRelease(repository: repository.slug, release: release))
                    status = "发现新版本 \(release.tagName)"
                    let identity = repository.slug.lowercased() + "#" + release.tagName
                    if manual || (prefs.automaticallyChecksForUpdates && prefs.lastNotifiedUpdate != identity) {
                        prefs.lastNotifiedUpdate = identity
                        onUpdateAvailable?(release)
                    }
                } else {
                    available = nil
                    prefs.cachedUpdate = nil
                    status = "已是最新版本"
                }
            default: throw UpdateFailure("检查失败（HTTP \(response.statusCode)），请稍后重试。")
            }
        } catch {
            guard requestGeneration == generation else { return }
            lastError = (error as? UpdateFailure)?.message ?? "无法连接 GitHub，请检查网络后重试。"
            status = lastError!
        }
        isChecking = false
        schedule()
    }

    func showAvailableUpdate() {
        if let available { onUpdateAvailable?(available) }
    }

    func performUpdateAction() {
        if installState == .ready {
            guard let reply = installReply else { return }
            guard Store.shared.isReadOnly || Store.shared.save(immediately: true) else {
                lastError = Store.shared.notice ?? "资料库未能保存，请重试后再安装更新。"
                status = lastError!
                showAvailableUpdate()
                return
            }
            lastError = nil
            installReply = nil
            installState = .installing
            status = "正在安装并重启…"
            reply(.install)
        } else { downloadUpdate() }
    }

    func downloadUpdate() {
        guard !isChecking, !installationInProgress, let available, let repository,
              repository.containsReleaseURL(available.htmlURL) else { return }
        lastError = nil
        installationError = nil
        downloadedBytes = 0
        expectedBytes = 0
        installerRepository = repository
        do {
            if installer == nil {
                let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: self, delegate: self)
                try updater.start()
                // ClipDock owns the persisted 24-hour schedule; only this explicit action downloads.
                updater.automaticallyChecksForUpdates = false
                updater.automaticallyDownloadsUpdates = false
                updater.sendsSystemProfile = false
                installer = updater
            }
            guard installer?.canCheckForUpdates == true else { return }
            installState = .checking
            status = "正在获取签名更新信息…"
            installer?.checkForUpdates()
        } catch { installationFailed(error) }
    }

    func cancelDownload() {
        guard let cancel = cancelTransfer else { return }
        cancelTransfer = nil
        installState = .cancelling
        status = "正在取消下载…"
        cancel()
    }

    private func installationFailed(_ error: Error) {
        installationError = error as NSError
        installState = .failed
        cancelTransfer = nil
        installReply = nil
        var cause: NSError? = error as NSError
        var invalidSignature = false
        while let current = cause {
            if current.domain == SUSparkleErrorDomain, [3001, 3002].contains(current.code) { invalidSignature = true }
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        lastError = invalidSignature ? "更新信息或安装包未通过签名校验，请重新检查更新。"
            : (error as? UpdateFailure)?.message ?? "更新未完成，请检查网络或安装权限后重试。"
        status = lastError!
    }

    private func repositoryChanged() {
        generation += 1
        isChecking = false
        available = nil
        lastError = nil
        prefs.cachedUpdate = nil
        prefs.lastUpdateCheck = nil
        prefs.lastNotifiedUpdate = ""
        status = repository == nil ? "请设置有效的 GitHub 仓库" : "尚未检查更新"
        Task { await checkIfDue() }
    }

    private func restoreCachedRelease() {
        guard let data = prefs.cachedUpdate, let repository,
              let cached = try? JSONDecoder().decode(CachedRelease.self, from: data),
              cached.repository.lowercased() == repository.slug.lowercased(),
              !cached.release.draft, !cached.release.prerelease,
              repository.containsReleaseURL(cached.release.htmlURL),
              let version = ReleaseVersion(cached.release.tagName), version.prerelease.isEmpty,
              let current = ReleaseVersion(currentVersion), version > current else { return }
        available = cached.release
        status = "发现新版本 \(cached.release.tagName)"
    }

    private func schedule() {
        timer?.invalidate()
        guard prefs.automaticallyChecksForUpdates, repository != nil, !isChecking, !installationInProgress else { return }
        let now = Date()
        let due = Self.isDue(lastCheck: prefs.lastUpdateCheck, automatic: true, now: now)
            ? now : (prefs.lastUpdateCheck ?? now).addingTimeInterval(Self.interval)
        timer = Timer.scheduledTimer(withTimeInterval: max(1, due.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        timer?.tolerance = 60
    }
}

// Sparkle owns downloading, signature verification, extraction, replacement and relaunch.
// This driver only connects its lifecycle to ClipDock's existing native surfaces.
extension UpdateChecker: SPUUserDriver, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        (testFeedURL ?? installerRepository?.appcastURL)?.absoluteString
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelTransfer = cancellation
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate,
              let offered = ReleaseVersion(appcastItem.displayVersionString), offered.prerelease.isEmpty,
              let selected = available.flatMap({ ReleaseVersion($0.tagName) }), offered == selected else {
            installationFailed(UpdateFailure("更新包与所选版本不一致，请重新检查更新。"))
            reply(.dismiss)
            return
        }
        // The user already chose Download in ClipDock; a second confirmation is unnecessary.
        // A previously staged installer must still wait for explicit install consent.
        if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
        } else { reply(.install) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installationFailed(error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installationFailed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelTransfer = cancellation
        installState = .downloading
        status = "正在下载更新…"
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let sum = downloadedBytes.addingReportingOverflow(length)
        downloadedBytes = sum.overflow ? .max : sum.partialValue
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelTransfer = nil
        installState = .preparing
        status = "正在校验并准备安装…"
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelTransfer = nil
        installReply = reply
        installState = .ready
        status = "更新已就绪，可以安装并重启"
        showAvailableUpdate()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        installState = .installing
        status = "正在安装并重启…"
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        status = relaunched ? "更新完成，已重新打开" : "更新安装完成"
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        cancelTransfer = nil
        installReply = nil
        if installState == .cancelling { status = "下载已取消，可以稍后重试" }
        if installState != .failed { installState = .idle }
        schedule()
    }

    func showUpdateInFocus() { showAvailableUpdate() }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Store.shared.save(immediately: true)
    }
}

private struct UpdateFailure: Error { let message: String; init(_ message: String) { self.message = message } }
