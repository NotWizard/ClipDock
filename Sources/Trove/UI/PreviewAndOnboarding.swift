import AppKit
import SwiftUI

// MARK: - Big preview

struct ItemPreviewWindowView: View {
    private let originalItem: ClipItem
    @ObservedObject var store: Store
    var close: () -> Void

    var item: ClipItem { store.items.first(where: { $0.id == originalItem.id }) ?? originalItem }
    var canUseItem: Bool { store.items.contains(where: { $0.id == originalItem.id }) }

    init(item: ClipItem, store: Store, close: @escaping () -> Void) {
        originalItem = item
        self.store = store
        self.close = close
    }

    var body: some View {
        Group {
            if canUseItem {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                    Divider()
                    footer
                }
            } else { Text("条目已删除").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 420, minHeight: 300)
        .background(Theme.windowBackground)
        .overlay(alignment: .top) { StoreNotice(store: store).padding(12) }
        .onChange(of: canUseItem) { _, available in if !available { close() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            KindBadge(kind: item.kind, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(Format.relative(item.createdAt) + (item.sourceName.map { " · \($0)" } ?? ""))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 900, maxHeight: 620)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            }
        case .color:
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: NSColor(hex: item.colorHex ?? "888888") ?? .gray))
                    .frame(height: 200)
                    .padding(.horizontal, 20)
                Text("#\(item.colorHex ?? "")")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                if let urlString = item.urlString, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Text(urlString)
                            .font(.system(size: 12))
                            .lineLimit(3)
                    }
                }
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        case .files:
            List(item.filePaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 11))
                        Text(path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .listStyle(.plain)
        default:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                guard canUseItem else { return }
                Paster.shared.copy(items: [item])
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                guard canUseItem else { return }
                Paster.shared.rememberFrontmostTarget()
                _ = Paster.shared.paste(items: [item], hide: { done in
                    close()
                    TroveWindows.shared.hideForPaste(completion: done)
                })
            } label: {
                Label("Paste", systemImage: "arrow.down.doc")
            }
            .keyboardShortcut(.return, modifiers: [])

            Spacer()

            Button(item.pinned ? "Unpin" : "Pin") { if canUseItem { store.togglePin(item.id) } }
            Button("Add to Stack") { if canUseItem { TroveWindows.shared.stackModel.append([item.id]) } }

            if !item.filePaths.isEmpty || item.imageURL != nil {
                Button {
                    guard canUseItem else { return }
                    if !item.filePaths.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(item.filePaths.map { URL(fileURLWithPath: $0) })
                    } else if let url = item.imageURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "folder")
                }
            }
            Button("Done") { close() }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    static let size = NSSize(width: 760, height: 560)
    private let secondaryText = Color(nsColor: .labelColor).opacity(0.75)
    enum Step: Int, CaseIterable {
        case welcome, shortcuts, privacy
        var title: String {
            switch self {
            case .welcome: return "认识 ClipDock"
            case .shortcuts: return "唤起与取用"
            case .privacy: return "记录与隐私"
            }
        }
        var symbol: String {
            switch self {
            case .welcome: return "rectangle.stack"
            case .shortcuts: return "keyboard"
            case .privacy: return "hand.raised"
            }
        }
    }

    @ObservedObject var prefs: Preferences
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    var finish: () -> Void
    @LocalState private var step: Step = .welcome
    @LocalState private var accessibilityGranted = Paster.shared.hasAccessibility

    init(prefs: Preferences, initialStep: Step = .welcome, finish: @escaping () -> Void) {
        self.prefs = prefs
        self.finish = finish
        _step = LocalState(wrappedValue: initialStep)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .shortcuts: shortcuts
                    case .privacy: privacy
                    }
                }
                Spacer(minLength: 16)
                Divider().padding(.bottom, 18)
                HStack(spacing: 12) {
                    if step != .welcome {
                        Button("上一步") { step = Step(rawValue: step.rawValue - 1)! }
                    }
                    Text("第 \(step.rawValue + 1) 步，共 3 步")
                        .font(.system(size: 12)).foregroundStyle(secondaryText)
                    Spacer()
                    Button(step == .privacy ? "打开剪贴板" : "继续") {
                        if step == .privacy { complete() }
                        else { step = Step(rawValue: step.rawValue + 1)! }
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.windowBackground)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Paster.shared.hasAccessibility
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: TroveBrand.appIcon()).resizable().frame(width: 64, height: 64)
                .padding(.bottom, 12)
            Text(AppIdentity.name).font(.system(size: 22, weight: .semibold))
            Text("复制的内容，随时取回。")
                .font(.system(size: 12)).foregroundStyle(secondaryText).padding(.top, 5)
            VStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { page in
                    Button { step = page } label: {
                        HStack(spacing: 9) {
                            Image(systemName: page.symbol).frame(width: 18)
                            Text(page.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: page == step ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .background(page == step ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(page == step ? "当前步骤" : "")
                }
            }
            .padding(.top, 36)
            Spacer()
            Label("资料保存在这台 Mac", systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(secondaryText)
                .padding(.bottom, 14)
            Button("跳过引导，直接开始", action: complete)
                .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(.horizontal, 20).padding(.vertical, 28)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("刚才复制的，\n下一次还用得到。")
                .font(.system(size: 27, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("文字、链接、图片和文件，留在本机。需要时唤起底部浮层，就能找到之前复制的内容。")
                .font(.system(size: 13)).foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ForEach(Self.examples) { item in
                    ItemCard(item: item, isSelected: false)
                        .scaleEffect(0.57).frame(width: 132, height: 132)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)
            Text("示例卡片").font(.system(size: 11)).foregroundStyle(secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                instruction("doc.on.doc", "照常复制", "ClipDock 会记住复制过的内容。")
                instruction("keyboard", "快捷键唤起", "直接输入搜索，方向键选择。")
                instruction("return", "回车取用", "空格先预览，回车或双击提交。")
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("随手一按，找回内容。")
                .font(.system(size: 25, weight: .semibold))
            Text("在其他 App 中也能唤起。点击下方组合键，可换成你习惯的快捷键。")
                .font(.system(size: 13)).foregroundStyle(secondaryText)
            HStack {
                Label("显示剪贴板", systemImage: "keyboard")
                Spacer()
                ShortcutRecorder(encoded: $prefs.activateShortcut).frame(width: 144, height: 28)
                    .onChange(of: prefs.activateShortcut) { _, _ in HotKeyCenter.shared.apply(from: prefs) }
            }
            .font(.system(size: 13)).padding(.vertical, 6)
            if !hotKeys.conflicts.isEmpty {
                Label("快捷键已被占用，请重新录制；也可点击菜单栏图标打开。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.primary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("直接粘贴到当前 App", isOn: $prefs.pasteToActiveApp)
                    .font(.system(size: 14, weight: .medium))
                Text("授权后，选中的内容会回贴到唤起前的 App。也可以先使用复制模式，再手动按 ⌘V。")
                    .font(.system(size: 12)).foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(accessibilityGranted ? "辅助功能已授权" : "辅助功能尚未授权",
                          systemImage: accessibilityGranted ? "checkmark.circle.fill" : "hand.raised")
                        .font(.system(size: 12))
                    Spacer()
                    if !accessibilityGranted && prefs.pasteToActiveApp {
                        Button("前往授权…") { Paster.shared.requestAccessibility() }
                    }
                }
            }
            Text("授权是可选项，稍后可在“设置 → 粘贴”中调整。")
                .font(.system(size: 12)).foregroundStyle(secondaryText)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("记录什么，由你决定。")
                .font(.system(size: 25, weight: .semibold))
            Text("历史保存在本机，无需账号。下面的选项都可以稍后在设置中修改。")
                .font(.system(size: 13)).foregroundStyle(secondaryText)
            HStack {
                Text("保留历史条目")
                Spacer()
                Picker("保留历史条目", selection: $prefs.historyLimit) {
                    ForEach([50, 100, 250, 500, 1000, 5000], id: \.self) { count in
                        Text("\(count.formatted()) 项").tag(count)
                    }
                    Text("不限数量").tag(0)
                }
                .labelsHidden().frame(width: 140)
            }
            .font(.system(size: 13))
            Text("固定条目和 Pinboard 不受历史数量限制。")
                .font(.system(size: 12)).foregroundStyle(secondaryText)
            Divider()
            Toggle("登录时打开 ClipDock", isOn: $prefs.openAtLogin)
                .font(.system(size: 13))
            Toggle("生成链接预览", isOn: $prefs.generateLinkPreviews)
                .font(.system(size: 13))
            Text("链接预览会访问对应网站；启用更新检查时会访问 GitHub。隐私设置还可排除指定 App，以及标记为机密或临时的内容。")
                .font(.system(size: 12)).foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instruction(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(secondaryText)
            Text(title).fontWeight(.medium).frame(width: 78, alignment: .leading)
            Text(detail).foregroundStyle(secondaryText)
        }
        .font(.system(size: 12))
    }

    private func complete() {
        prefs.hasCompletedOnboarding = true
        finish()
    }

    private static var examples: [ClipItem] {
        [("设计灵感", "好想法，下一次用得到。", "com.google.Chrome"),
         ("周末清单", "买一束花\n整理照片\n读完一本书", "com.apple.Notes"),
         ("常用回复", "收到，谢谢！\n我会尽快回复。", "com.apple.MobileSMS")].map { title, text, bundle in
            var item = ClipItem()
            item.title = title
            item.text = title + "\n" + text
            item.sourceBundleID = bundle
            return item
        }
    }
}
