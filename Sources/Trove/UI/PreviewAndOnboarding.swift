import AppKit
import SwiftUI

// MARK: - Big preview

struct ItemPreviewWindowView: View {
    let item: ClipItem
    @ObservedObject var store: Store
    var close: () -> Void

    @LocalState private var draftText: String = ""
    @LocalState private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 300)
        .background(Theme.windowBackground)
        .onAppear {
            draftText = item.text ?? ""
        }
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
                Paster.shared.copy(items: [item])
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                Paster.shared.rememberFrontmostTarget()
                _ = Paster.shared.paste(items: [item], hide: { close() })
            } label: {
                Label("Paste", systemImage: "arrow.down.doc")
            }
            .keyboardShortcut(.return, modifiers: [])

            Spacer()

            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
            Button("Add to Stack") { TroveWindows.shared.stackModel.append([item.id]) }

            if !item.filePaths.isEmpty || item.imageURL != nil {
                Button {
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
    @ObservedObject var prefs: Preferences
    var finish: () -> Void

    @LocalState private var accessibilityGranted = Paster.shared.hasAccessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accent.opacity(0.18))
                    Image(nsImage: TroveBrand.statusIcon()).renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 30, height: 30)
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text("欢迎使用 \(AppIdentity.name)")
                        .font(.system(size: 20, weight: .semibold))
                    Text("A time machine for your clipboard.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            step(
                number: 1,
                title: "\(AppIdentity.name) 会保存你复制的内容",
                body: "Text, images, links, colours and files land here automatically. Pick a history limit you're comfortable with.",
                done: true
            ) {
                Picker("", selection: $prefs.historyLimit) {
                    Text("250 items").tag(250)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("Unlimited").tag(0)
                }
                .labelsHidden()
                .frame(width: 140)
            }

            step(
                number: 2,
                title: "Paste straight into other apps",
                body: accessibilityGranted
                    ? "已获得辅助功能权限，可以直接粘贴。"
                    : "直接粘贴需要 macOS 辅助功能权限。",
                done: accessibilityGranted
            ) {
                Button(accessibilityGranted ? "Granted" : "Allow…") {
                    Paster.shared.requestAccessibility()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        accessibilityGranted = Paster.shared.hasAccessibility
                    }
                }
                .disabled(accessibilityGranted)
            }

            step(
                number: 3,
                title: "随时唤起 \(AppIdentity.name)",
                body: "Press this shortcut in any app to bring up your clipboard.",
                done: KeyCombo.decode(prefs.activateShortcut) != nil
            ) {
                ShortcutRecorder(encoded: $prefs.activateShortcut)
                    .frame(width: 120, height: 24)
                    .onChange(of: prefs.activateShortcut) { _, _ in
                        HotKeyCenter.shared.apply(from: prefs)
                    }
            }

            step(
                number: 4,
                title: "Keep it running",
                body: "登录时打开 \(AppIdentity.name)，持续记录剪贴板。",
                done: prefs.openAtLogin
            ) {
                Toggle("", isOn: $prefs.openAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Spacer(minLength: 12)

            HStack {
                Text("Everything is stored locally on this Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started") {
                    prefs.hasCompletedOnboarding = true
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
        .background(Theme.windowBackground)
    }

    private func step<Accessory: View>(
        number: Int,
        title: String,
        body: String,
        done: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.18) : Color.primary.opacity(0.06))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(body)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 9)
    }
}
