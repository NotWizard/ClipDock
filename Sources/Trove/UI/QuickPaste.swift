import AppKit
import SwiftUI

/// The primary clipboard surface. It shares search, destinations and selection with the manager.
struct QuickPasteView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var store: Store
    @ObservedObject var prefs: Preferences
    @ObservedObject private var monitor = TroveApp.shared.monitor
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LocalState private var dropTarget: UUID?
    @LocalState private var canPaste = Paster.shared.hasAccessibility

    var body: some View {
        VStack(spacing: 0) {
            toolbar.frame(height: 56)
            if model.items.isEmpty {
                emptyState.frame(height: 248)
            } else {
                cards.frame(height: 248)
            }
            footer.frame(height: 20).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 332)
        .background(PanelMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .bottom) {
            if let feedback = model.feedback {
                Label(feedback, systemImage: Paster.shared.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 30)
                    .accessibilityLabel(feedback)
            }
        }
        .sheet(isPresented: $model.showNewPinboard) {
            NewPinboardSheet(store: store) { board in
                model.selectDestination(.pinboard(board.id))
                model.showNewPinboard = false
            }
        }
        .onChange(of: model.query) { _, _ in
            model.previewID = nil
            model.selection = Set(model.items.prefix(1).map(\.id))
        }
        .onChange(of: model.items.map(\.id)) { _, _ in model.reconcileSelection() }
        .onChange(of: model.searchFocusRequest) { _, _ in canPaste = Paster.shared.hasAccessibility }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            canPaste = Paster.shared.hasAccessibility
        }
        .onChange(of: store.pinboards.map(\.id)) { _, ids in
            if let board = model.destination.pinboardID, !ids.contains(board) { model.selectDestination(.clipboard) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                if monitor.isPaused {
                    Image(systemName: "pause.circle.fill")
                    Text("已暂停").font(.system(size: 11, weight: .medium))
                } else if model.plainTextMode || prefs.alwaysPlainText {
                    Image(systemName: "textformat")
                    Text("纯文本").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                PanelSearchField(model: model)
                    .frame(width: model.isSearching ? 400 : 30, height: 32)
                    .background(model.isSearching ? Color.primary.opacity(0.06) : .clear, in: Capsule())
                    .overlay {
                        if model.isSearching {
                            Capsule().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isSearching)

                if model.isSearching {
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            model.searchFocusRequest += 1
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .help("清除搜索").accessibilityLabel("清除搜索")
                    }
                    filterButton
                    Chip(text: model.destination.pinboardID == nil ? "剪贴板" : model.title, selected: true) {
                        model.isSearching = false
                        model.query = ""
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            destinationTab("剪贴板", destination: .clipboard, color: nil)
                            ForEach(store.pinboards) { board in
                                destinationTab(board.name, destination: .pinboard(board.id), color: Color(nsColor: board.color))
                                    .onDrop(of: [Paster.itemIdentifier], isTargeted: nil) { providers in
                                        receiveDrop(providers, board: board.id)
                                    }
                                    .contextMenu {
                                        Button("重命名…") { renameBoard(board) }
                                        Menu("颜色") {
                                            ForEach(Pinboard.palette, id: \.self) { hex in
                                                Button("#\(hex)") { store.recolorPinboard(board.id, colorHex: hex) }
                                            }
                                        }
                                        Button("删除 Pinboard", role: .destructive) { store.deletePinboard(board.id) }
                                    }
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: tabStripWidth)
                    Button { model.showNewPinboard = true } label: { Image(systemName: "plus").font(.system(size: 19, weight: .light)) }
                        .help("创建 Pinboard（⇧⌘N）").accessibilityLabel("创建 Pinboard")
                    filterButton
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Menu {
                if !hotKeys.conflicts.isEmpty {
                    Text("快捷键被占用：\(hotKeys.conflicts.joined(separator: "、"))")
                    Divider()
                }
                Button("管理剪贴板…") { TroveWindows.shared.closeQuickPaste(restoreTarget: false); TroveWindows.shared.showMainWindow() }
                Button("粘贴队列…") { TroveWindows.shared.showPasteStack() }
                Button("设置…") { TroveWindows.shared.showSettings() }
                Divider()
                if monitor.isPaused {
                    Button("恢复记录") { TroveApp.shared.resumeCapture() }
                } else {
                    Menu("暂停记录") {
                        Button("5 分钟") { TroveApp.shared.pauseCapture(300) }
                        Button("1 小时") { TroveApp.shared.pauseCapture(3600) }
                        Button("直到手动恢复") { TroveApp.shared.pauseCapture(nil) }
                    }
                }
                Divider()
                Button("关闭面板") { TroveWindows.shared.closeQuickPaste() }
            } label: { Image(systemName: hotKeys.conflicts.isEmpty ? "ellipsis" : "exclamationmark.circle").font(.system(size: 18)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 84, alignment: .trailing).accessibilityLabel("更多选项")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private var filterButton: some View {
        Button { model.showFilters.toggle() } label: {
            Image(systemName: model.activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 16))
                .foregroundStyle(model.activeFilterCount > 0 ? Color.accentColor : Color.secondary)
        }
        .help("筛选").accessibilityLabel("筛选")
        .popover(isPresented: $model.showFilters, arrowEdge: .bottom) { FilterPopover(model: model, store: store) }
    }

    private var tabStripWidth: CGFloat {
        let titles = ["剪贴板"] + store.pinboards.map(\.name)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = titles.reduce(CGFloat(0)) { result, title in
            result + (title as NSString).size(withAttributes: [.font: font]).width + 49
        } + CGFloat(max(0, titles.count - 1)) * 12
        return min(620, width)
    }

    private func destinationTab(_ title: String, destination: Destination, color: Color?) -> some View {
        Button {
            model.selectDestination(destination)
        } label: {
            HStack(spacing: 7) {
                if let color { Circle().fill(color).frame(width: 9, height: 9) }
                else { Image(systemName: "clock.arrow.circlepath") }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(model.destination == destination ? Color.primary.opacity(0.09) : .clear, in: Capsule())
        }
        .accessibilityValue(model.destination == destination ? "已选择" : "")
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ItemCard(item: item, isSelected: model.selection.contains(item.id))
                            .id(item.id)
                            .overlay(alignment: .bottomTrailing) {
                                if model.showNumberHints && index < 9 {
                                    Text("⌘\(index + 1)").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Color.accentColor, in: Capsule()).padding(10)
                                }
                            }
                            .onTapGesture(count: 2) {
                                model.selection = [item.id]
                                TroveWindows.shared.commitSelection()
                            }
                            .onTapGesture {
                                model.toggleSelection(item.id, extending: NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty == false)
                            }
                            .contextMenu {
                                ItemContextMenu(item: item, model: model, store: store,
                                                onPreview: { showPreview(item, editing: false) },
                                                onEdit: { showPreview(item, editing: true) })
                            }
                            .popover(isPresented: Binding(
                                get: { model.previewID == item.id },
                                set: { if !$0 { model.previewID = nil; model.searchFocusRequest += 1 } }
                            ), arrowEdge: .bottom) {
                                PanelItemPreview(item: item, store: store, initiallyEditing: model.previewEditing) {
                                    model.previewID = nil
                                    model.searchFocusRequest += 1
                                }
                            }
                            .onDrag { Paster.shared.itemProvider(for: item) }
                            .task {
                                if prefs.generateLinkPreviews, item.kind == .link, item.imageName == nil,
                                   let url = item.urlString {
                                    await LinkPreviewService.shared.enrich(urlString: url, itemID: item.id)
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: Text("选择")) { model.selection = [item.id] }
                            .accessibilityAction(named: Text("粘贴")) {
                                model.selection = [item.id]
                                TroveWindows.shared.commitSelection()
                            }
                            .onDrop(of: [Paster.itemIdentifier], delegate: CardReorderDrop(
                                target: item.id, enabled: model.destination.pinboardID != nil, highlighted: $dropTarget
                            ) { providers, after in receiveDrop(providers, before: item.id, after: after) })
                            .overlay {
                                if dropTarget == item.id && model.destination.pinboardID != nil {
                                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [5, 3]))
                                }
                            }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
            .onChange(of: model.selection) { _, _ in
                guard let id = model.current?.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.destination) { _, _ in
                if let id = model.items.first?.id { proxy.scrollTo(id, anchor: .leading) }
            }
            .onChange(of: model.items.map(\.id)) { _, _ in
                if let id = model.current?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.searchFocusRequest) { _, _ in
                if !model.isSearching, let id = model.current?.id { proxy.scrollTo(id, anchor: .leading) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
            Text(!model.query.isEmpty || model.activeFilterCount > 0 ? "没有找到匹配内容" :
                    model.destination.pinboardID == nil ? "复制的内容会出现在这里" : "这个 Pinboard 还是空的")
                .font(.system(size: 16, weight: .medium))
            Text(model.destination.pinboardID == nil ? "文本、链接、图片和文件，随时回来取用。" : "将卡片拖到上方标签，即可固定到这里。")
                .font(.system(size: 12))
            if model.activeFilterCount > 0 { Button("清除筛选") { model.clearFilters() } }
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("← → 选择  ·  ↵ 粘贴  ·  空格预览  ·  ⌘1–9 快速粘贴")
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
            Spacer()
            HStack(spacing: 12) {
                if !canPaste && prefs.pasteToActiveApp {
                    Button("启用直接粘贴") { Paster.shared.requestAccessibility() }.buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: .linkColor))
                }
                Text(prefs.pasteToActiveApp && canPaste
                     ? "\(model.plainTextMode || prefs.alwaysPlainText ? "纯文本" : "")粘贴到 \(Paster.shared.destinationName)"
                     : "复制到剪贴板")
                Text("\(model.items.count) 项")
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color(nsColor: .textBackgroundColor), in: Capsule())
        }
        .font(.system(size: 11)).foregroundStyle(.primary).padding(.horizontal, 26)
    }

    private func showPreview(_ item: ClipItem, editing: Bool) {
        model.selection = [item.id]
        model.previewEditing = editing
        model.previewID = item.id
    }

    private func receiveDrop(_ providers: [NSItemProvider], board: UUID? = nil, before target: UUID? = nil, after: Bool = false) -> Bool {
        guard board != nil || (target != nil && model.destination.pinboardID != nil) else { return false }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Paster.itemIdentifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Paster.itemIdentifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                guard store.items.contains(where: { $0.id == id }) else { return }
                if let board, store.pinboard(board) != nil { store.setPinboard(id, to: board) }
                else if let target { store.reorder(id, relativeTo: target, after: after) }
            }
        }
        return true
    }

    private func renameBoard(_ board: Pinboard) {
        let alert = NSAlert()
        alert.messageText = "重命名 Pinboard"
        let field = NSTextField(string: board.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { store.renamePinboard(board.id, name: name) }
        }
    }
}

private struct CardReorderDrop: DropDelegate {
    let target: UUID
    let enabled: Bool
    @Binding var highlighted: UUID?
    let drop: ([NSItemProvider], Bool) -> Bool
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [Paster.itemIdentifier]) }
    func dropEntered(info: DropInfo) { if enabled { highlighted = target } }
    func dropExited(info: DropInfo) { if highlighted == target { highlighted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { enabled ? DropProposal(operation: .move) : nil }
    func performDrop(info: DropInfo) -> Bool {
        highlighted = nil
        return enabled && drop(info.itemProviders(for: [Paster.itemIdentifier]), info.location.x > 116)
    }
}

struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Keeping one native field mounted and focused lets the input method receive the original event.
private struct PanelSearchField: NSViewRepresentable {
    @ObservedObject var model: MainViewModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 14)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.setAccessibilityLabel("搜索剪贴板")
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.target = context.coordinator
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.action = #selector(Coordinator.beginSearch)
        field.expand = { context.coordinator.beginSearch() }
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        field.isSearching = model.isSearching
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing && context.coordinator.lastQuery != model.query {
            context.coordinator.lastQuery = model.query
            if field.stringValue != model.query { field.stringValue = model.query }
        }
        field.placeholderString = model.isSearching ? "搜索当前列表…" : ""
        (field.currentEditor() as? NSTextView)?.insertionPointColor = model.isSearching ? .controlAccentColor : .clear
        if context.coordinator.focusRequest != model.searchFocusRequest {
            context.coordinator.focusRequest = model.searchFocusRequest
            DispatchQueue.main.async {
                guard let window = field.window, window.isVisible, model.previewID == nil, !model.showNewPinboard else { return }
                window.makeFirstResponder(field)
                (field.currentEditor() as? NSTextView)?.insertionPointColor = model.isSearching ? .controlAccentColor : .clear
            }
        }
    }
    final class SearchField: NSSearchField {
        var expand: (() -> Void)?
        var isSearching = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if !isSearching {
                // Do not enter native cell tracking while SwiftUI is resizing the control.
                expand?()
                return
            }
            super.mouseDown(with: event)
        }
    }
    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: MainViewModel
        var focusRequest = -1
        var lastQuery = ""
        init(model: MainViewModel) { self.model = model }
        @objc func beginSearch() {
            model.isSearching = true
            model.searchFocusRequest += 1
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            lastQuery = value
            model.query = value
            if !field.stringValue.isEmpty || (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                model.isSearching = true
            }
        }
    }
}

private struct PanelItemPreview: View {
    let item: ClipItem
    @ObservedObject var store: Store
    var initiallyEditing = false
    var close: () -> Void
    @LocalState private var editing = false
    @LocalState private var draft = ""
    @LocalState private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: close) { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("关闭预览")
                Text(editing ? "编辑纯文本" : item.kind.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if item.kind == .text {
                    Button(editing ? "取消编辑" : "编辑") { editing.toggle() }
                }
                Button(item.pinned ? "取消固定" : "固定") { store.togglePin(item.id) }
            }
            .buttonStyle(.plain).padding(12)
            Divider()
            if editing {
                TextEditor(text: $draft).font(.system(size: 14)).padding(8)
            } else if item.kind == .text {
                ScrollView {
                    Text(item.text ?? "").font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else if item.kind == .files {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.filePaths, id: \.self) { path in
                            HStack(spacing: 10) {
                                FileThumbnail(path: path, size: 40)
                                Text(path).font(.system(size: 12)).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else {
                ItemPreviewContent(item: item).padding(16).background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                else if item.kind == .text {
                    Text("\(item.text?.count ?? 0) 个字符 · \((item.text ?? "").split(whereSeparator: \.isWhitespace).count) 个单词 · \((item.text ?? "").components(separatedBy: "\n").count) 行")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if editing {
                    Button("保存") {
                        if store.updateText(item.id, text: draft) { close() }
                        else { error = "保存失败，原内容已保留。" }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("复制") { TroveWindows.shared.commitSelection(copyOnly: true) }
                    Button("粘贴") { TroveWindows.shared.commitSelection() }
                }
            }
            .font(.system(size: 11)).padding(12)
        }
        .frame(width: item.kind == .text ? 420 : 540, height: 360)
        .onAppear { draft = item.text ?? ""; editing = initiallyEditing && item.kind == .text }
    }
}
