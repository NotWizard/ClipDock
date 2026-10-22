import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Shortcut recorder

final class ShortcutRecorderNSView: NSView {
    var combo: KeyCombo?
    var onChange: ((KeyCombo?) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            setAccessibilityValue(isRecording ? "正在录制" : combo?.displayString ?? "未设置")
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        if isRecording {
            text = "正在录制…"
        } else if let combo {
            text = combo.displayString
        } else {
            text = "点击录制"
        }
        let color: NSColor = isRecording ? .controlAccentColor : (combo == nil ? .tertiaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if event.keyCode == 53 { // esc
            isRecording = false
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // delete
            combo = nil
            onChange?(nil)
            isRecording = false
            return
        }

        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers != 0 else { return }

        let newCombo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        combo = newCombo
        onChange?(newCombo)
        isRecording = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var encoded: String

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("录制快捷键")
        view.combo = KeyCombo.decode(encoded)
        view.onChange = { combo in
            encoded = combo?.encoded ?? ""
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        let incoming = KeyCombo.decode(encoded)
        if view.combo != incoming {
            view.combo = incoming
            view.needsDisplay = true
        }
        view.setAccessibilityValue(incoming?.displayString ?? "未设置")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var store: Store
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @LocalState private var accessibilityGranted = Paster.shared.hasAccessibility
    @LocalState private var tab: Tab = .general

    init(prefs: Preferences, store: Store, initialTab: Tab = .general) {
        self.prefs = prefs
        self.store = store
        _tab = LocalState(wrappedValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general, history, privacy, shortcuts, paste, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "通用"
            case .history: return "历史记录"
            case .privacy: return "隐私"
            case .shortcuts: return "快捷键"
            case .paste: return "粘贴"
            case .about: return "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .history: return "clock"
            case .privacy: return "hand.raised"
            case .shortcuts: return "keyboard"
            case .paste: return "arrow.down.doc"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 16)
                            Text(item.title)
                                .font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == item ? Theme.accent.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 184)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: generalTab
                    case .history: historyTab
                    case .privacy: privacyTab
                    case .shortcuts: shortcutsTab
                    case .paste: pasteTab
                    case .about: aboutTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 540)
        .background(Theme.windowBackground)
        .onAppear { accessibilityGranted = Paster.shared.hasAccessibility }
        .onReceive(NotificationCenter.default.publisher(for: .clipdockShowUpdates)) { _ in tab = .about }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Paster.shared.hasAccessibility
        }
    }

    // MARK: General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("通用")
            toggleRow("登录时打开", subtitle: "登录后自动记录剪贴板。", isOn: $prefs.openAtLogin)
            toggleRow("显示菜单栏图标", subtitle: "点击显示剪贴板，右键打开菜单。", isOn: $prefs.showMenuBarIcon)
            toggleRow("音效", subtitle: "复制或粘贴时播放提示音。", isOn: $prefs.soundEffects)
            Divider().padding(.vertical, 12)
            Text("\(AppIdentity.name) 会在后台持续记录复制内容，关闭面板不会停止记录。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("历史记录")
            HStack {
                Text("保留条目")
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: $prefs.historyLimit) {
                    Text("50 项").tag(50)
                    Text("100 项").tag(100)
                    Text("250 项").tag(250)
                    Text("500 项").tag(500)
                    Text("1,000 项").tag(1000)
                    Text("5,000 项").tag(5000)
                    Text("不限数量").tag(0)
                }
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.vertical, 4)

            Text("固定的条目和 Pinboard 不受历史数量限制。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 14)

            HStack(spacing: 10) {
                Button("清空剪贴板历史…") {
                    confirmErase()
                }
                Text("已保存 \(store.totalCount) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confirmErase() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "固定的条目和 Pinboard 会保留。清空后无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.eraseHistory(keepingPinned: true)
        }
    }

    // MARK: Privacy

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("隐私")
            toggleRow("忽略机密内容", subtitle: "不记录密码和应用标记为机密的内容。", isOn: $prefs.ignoreConfidential)
            toggleRow("忽略临时内容", subtitle: "不记录应用标记为临时的内容。", isOn: $prefs.ignoreTransient)
            toggleRow("生成链接预览", subtitle: "联网获取网页标题和预览图片；敏感或一次性链接建议关闭此项。", isOn: $prefs.generateLinkPreviews)

            Divider().padding(.vertical, 14)

            Text("忽略应用")
                .font(.system(size: 12, weight: .semibold))
            Text("不记录从下列应用复制的内容。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if prefs.ignoredBundleIDs.isEmpty {
                Text("尚未添加")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(prefs.ignoredBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 15, height: 15)
                            }
                            Text(appName(for: bundleID))
                                .font(.system(size: 12))
                            Spacer()
                            Button {
                                prefs.removeIgnoredApp(bundleID)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Button("添加应用…") { addIgnoredApp() }
                .padding(.top, 8)
        }
    }

    private func appName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择不需要记录的应用"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        prefs.addIgnoredApp(bundleID)
    }

    // MARK: Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("快捷键")
            Text("全局快捷键可在其他应用中使用。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            if !hotKeys.conflicts.isEmpty {
                Text("快捷键被其他应用占用：\(hotKeys.conflicts.joined(separator: "、"))。请退出原版 Paste 或重新录制；菜单栏仍可打开 \(AppIdentity.name)。")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }

            shortcutRow("显示剪贴板", $prefs.activateShortcut)
            shortcutRow("显示剪贴板（备用）", $prefs.quickPasteShortcut)
            shortcutRow("粘贴队列", $prefs.pasteStackShortcut)
            shortcutRow("直接粘贴纯文本", $prefs.plainTextShortcut)
            shortcutRow("下一个 Pinboard（全局）", $prefs.nextPinboardShortcut)
            shortcutRow("上一个 Pinboard（全局）", $prefs.previousPinboardShortcut)
            Text("面板内：⌘1–9 快速粘贴 · ⇧ 纯文本 · ⌘← / ⌘→ 切换 Pinboard")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Divider().padding(.vertical, 12)
            HStack {
                Button("恢复默认") { resetShortcuts() }
                Spacer()
                Text("点击录制，Esc 取消，删除键清除。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetShortcuts() {
        prefs.resetShortcutDefaults()
        HotKeyCenter.shared.apply(from: prefs)
    }

    private func shortcutRow(_ title: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            ShortcutRecorder(encoded: binding)
                .frame(width: 128, height: 24)
                .onChange(of: binding.wrappedValue) { _, _ in
                    HotKeyCenter.shared.apply(from: prefs)
                }
        }
        .padding(.vertical, 4)
    }

    // MARK: Paste

    private var pasteTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("粘贴条目")
            Picker("", selection: $prefs.pasteToActiveApp) {
                Text("粘贴到当前应用").tag(true)
                Text("复制到剪贴板").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(prefs.pasteToActiveApp
                 ? "回贴到唤起面板之前使用的应用。"
                 : "选择后复制到剪贴板，再手动按 ⌘V 粘贴。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Divider().padding(.vertical, 14)

            Toggle("始终以纯文本粘贴", isOn: $prefs.alwaysPlainText)
                .font(.system(size: 13))

            Divider().padding(.vertical, 14)

            HStack(spacing: 8) {
                Image(systemName: accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(accessibilityGranted ? .green : .orange)
                Text(accessibilityGranted
                     ? "已获得辅助功能权限，可以直接粘贴。"
                     : "直接粘贴需要辅助功能权限；未授权时仍可复制。")
                    .font(.system(size: 12))
                Spacer()
                if !accessibilityGranted {
                    Button("启用…") { Paster.shared.requestAccessibility() }
                }
            }
        }
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: TroveBrand.appIcon())
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppIdentity.name)
                        .font(.system(size: 20, weight: .semibold))
                    Text("版本 \(Bundle.main.shortVersion)（\(Bundle.main.buildVersion)）")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.72))
                }
            }
            .padding(.bottom, 6)

            Text("原生 macOS 剪贴板管理器。历史保存在本机；链接预览和更新检查会联网。")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 8)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(updates.status).font(.system(size: 13, weight: .medium))
                        .accessibilityIdentifier("update-status")
                    if let date = prefs.lastUpdateCheck {
                        Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.72))
                    }
                }
                Spacer()
                if updates.isChecking { ProgressView().controlSize(.small).accessibilityLabel("正在检查更新") }
                Button(updates.installationInProgress ? "查看更新" : (updates.isChecking ? "检查中…" : "检查更新")) {
                    Task { await updates.check() }
                }
                .disabled(updates.isChecking || updates.repository == nil)
            }
            if let release = updates.available {
                HStack {
                    Label("\(release.tagName) 可用", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(updates.canPerformUpdateAction ? updates.updateActionTitle : "查看进度") {
                        updates.showAvailableUpdate()
                        if updates.canPerformUpdateAction { updates.performUpdateAction() }
                    }
                }
                .padding(10).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                if updates.installState == .downloading {
                    VStack(alignment: .leading, spacing: 5) {
                        if let progress = updates.downloadProgress { ProgressView(value: progress) }
                        Text(updates.transferDescription).font(.system(size: 11)).monospacedDigit()
                    }
                }
            }
            Toggle("每 24 小时自动检查更新", isOn: $prefs.automaticallyChecksForUpdates)
                .font(.system(size: 12))
            Text("发现新版本时提醒；在 App 内下载、校验并安装重启。")
                .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.72))
            Divider().padding(.vertical, 8)

            HStack {
                Text("存储").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.72))
                Spacer()
                Button("在访达中显示资料库") {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.root])
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            HStack {
                Text("已保存条目").font(.system(size: 12)).foregroundStyle(.primary.opacity(0.72))
                Spacer()
                Text("\(store.totalCount)").font(.system(size: 12))
            }
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .padding(.bottom, 14)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 5)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    var buildVersion: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}

extension Notification.Name {
    static let clipdockShowUpdates = Notification.Name("clipdockShowUpdates")
}
