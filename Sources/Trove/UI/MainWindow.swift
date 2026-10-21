import AppKit
import Combine
import SwiftUI

// MARK: - Destination

enum Destination: Hashable {
    case clipboard
    case pinboard(UUID)

    var pinboardID: UUID? {
        if case .pinboard(let id) = self { return id }
        return nil
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case newest, oldest
    var id: String { rawValue }
    var title: String { self == .newest ? "Newest first" : "Oldest first" }
}

// MARK: - View model

@MainActor
final class MainViewModel: ObservableObject {
    @Published var destination: Destination = .clipboard
    @Published var query: String = ""
    @Published var kindFilter: ItemKind?
    @Published var appFilter: String?
    @Published var dateFilter: Date?
    @Published var sort: SortOrder = .newest
    @Published var layout: LayoutMode = .grid
    @Published var selection: Set<UUID> = []
    @Published var showFilters = false
    @Published var isSearching = false
    @Published var previewID: UUID?
    @Published var previewEditing = false
    @Published var showNumberHints = false
    @Published var plainTextMode = false
    @Published var showNewPinboard = false
    @Published var searchFocusRequest = 0
    @Published var feedback: String?

    enum LayoutMode { case grid, list }

    private let store: Store
    private let prefs: Preferences

    init(store: Store, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
    }

    var items: [ClipItem] {
        let base = store.items(in: destination.pinboardID, query: query, kind: kindFilter, bundleID: appFilter, since: dateFilter)
        return sort == .newest && destination.pinboardID == nil ? base : (sort == .oldest ? base.reversed() : base)
    }

    var title: String {
        if let id = destination.pinboardID {
            return store.pinboard(id)?.name ?? "Pinboard"
        }
        return "Clipboard"
    }

    var subtitle: String {
        let count = items.count
        let noun = count == 1 ? "item" : "items"
        if !query.isEmpty { return "\(count) \(noun) matching “\(query)”" }
        return "\(count) \(noun)"
    }

    var activeFilterCount: Int {
        var n = 0
        if kindFilter != nil { n += 1 }
        if appFilter != nil { n += 1 }
        if dateFilter != nil { n += 1 }
        return n
    }

    func clearFilters() {
        kindFilter = nil
        appFilter = nil
        dateFilter = nil
    }

    func toggleSelection(_ id: UUID, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    var current: ClipItem? { selectedItems.first ?? items.first }

    func preparePanel() {
        if let board = destination.pinboardID, store.pinboard(board) == nil { destination = .clipboard }
        query = ""
        isSearching = false
        previewID = nil
        showFilters = false
        feedback = nil
        showNumberHints = false
        plainTextMode = false
        selection = Set(items.prefix(1).map(\.id))
        searchFocusRequest += 1
    }

    func selectDestination(_ destination: Destination) {
        self.destination = destination
        previewID = nil
        selection = Set(items.prefix(1).map(\.id))
        searchFocusRequest += 1
    }

    func cycleDestination(forward: Bool) {
        let destinations: [Destination] = [.clipboard] + store.pinboards.map { .pinboard($0.id) }
        let index = destinations.firstIndex(of: destination) ?? 0
        selectDestination(destinations[(index + (forward ? 1 : destinations.count - 1)) % destinations.count])
    }

    func selectQuickItem(_ index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        selection = [items[index].id]
        return true
    }

    func reconcileSelection() {
        selection.formIntersection(Set(items.map(\.id)))
        if selection.isEmpty { selection = Set(items.prefix(1).map(\.id)) }
        if let id = previewID, !items.contains(where: { $0.id == id }) { previewID = nil }
    }

    func moveSelection(by delta: Int) {
        let pool = items
        guard !pool.isEmpty else { return }
        if let current = selectedItems.first?.id, let index = pool.firstIndex(where: { $0.id == current }) {
            let next = min(max(index + delta, 0), pool.count - 1)
            selection = [pool[next].id]
        } else {
            selection = [pool[delta >= 0 ? 0 : pool.count - 1].id]
        }
    }

    var selectedItems: [ClipItem] {
        let pool = items
        let chosen = pool.filter { selection.contains($0.id) }
        return chosen.isEmpty ? [] : chosen
    }

    // MARK: Actions

    func pasteSelection(plainText: Bool = false) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        TroveWindows.shared.commitSelection(plainText: plainText)
    }

    func copySelection(plainText: Bool = false) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        if TroveWindows.shared.quickPanel?.isVisible == true {
            TroveWindows.shared.commitSelection(copyOnly: true, plainText: plainText)
            return
        }
        Paster.shared.copy(items: chosen, plainText: plainText)
    }

    func deleteSelection() {
        let chosen = selection
        guard !chosen.isEmpty else { return }
        store.delete(ids: chosen)
        selection = []
    }

    func togglePinSelection() {
        for id in selection { store.togglePin(id) }
    }

    func moveSelection(to pinboard: UUID?) {
        for id in selection { store.setPinboard(id, to: pinboard) }
    }

    func revealSelectionInFinder() {
        for item in selectedItems {
            let paths = item.filePaths
            if paths.isEmpty, let imageURL = item.imageURL {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            }
        }
    }
}

// MARK: - Main window view

struct MainWindowView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: MainViewModel

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store, prefs: prefs, model: model)
                .frame(width: Theme.sidebarWidth)

            Divider()

            VStack(spacing: 0) {
                header
                Divider()
                if model.items.isEmpty {
                    EmptyStateView(model: model, store: store)
                } else {
                    content
                }
                Divider()
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.windowBackground)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .troveFocusSearch)) { _ in
            searchFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.title)
                    .font(.system(size: 19, weight: .semibold))
                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()

                if model.activeFilterCount > 0 {
                    Button {
                        model.clearFilters()
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    Divider()
                    Picker("Layout", selection: $model.layout) {
                        Text("Grid").tag(MainViewModel.LayoutMode.grid)
                        Text("List").tag(MainViewModel.LayoutMode.list)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)

                Button {
                    model.showFilters.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 13, weight: .medium))
                        if model.activeFilterCount > 0 {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $model.showFilters, arrowEdge: .bottom) {
                    FilterPopover(model: model, store: store)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("Search your clipboard", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("⌘F")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .frame(maxWidth: 360)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let kind = model.kindFilter {
                            Chip(text: kind.title, selected: true, action: { model.kindFilter = nil })
                        }
                        if let app = model.appFilter {
                            Chip(text: appName(app), selected: true, action: { model.appFilter = nil })
                        }
                        if model.dateFilter != nil {
                            Chip(text: "Today", selected: true, action: { model.dateFilter = nil })
                        }
                        ForEach(ItemKind.allCases.filter { $0 != .unknown }) { kind in
                            if model.kindFilter != kind {
                                Chip(text: kind.title, action: { model.kindFilter = kind })
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func appName(_ bundleID: String) -> String {
        store.knownApplications.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            switch model.layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 260), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(model.items) { item in
                        ItemCard(item: item, isSelected: model.selection.contains(item.id))
                            .onTapGesture(count: 2) {
                                model.selection = [item.id]
                                model.pasteSelection()
                            }
                            .onTapGesture {
                                let extending = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                                model.toggleSelection(item.id, extending: extending)
                            }
                            .contextMenu {
                                ItemContextMenu(item: item, model: model, store: store)
                            }
                            .onDrag {
                                Paster.shared.itemProvider(for: item)
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            case .list:
                LazyVStack(spacing: 1) {
                    ForEach(model.items) { item in
                        ItemRow(item: item, isSelected: model.selection.contains(item.id))
                            .onTapGesture(count: 2) {
                                model.selection = [item.id]
                                model.pasteSelection()
                            }
                            .onTapGesture {
                                let extending = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                                model.toggleSelection(item.id, extending: extending)
                            }
                            .contextMenu {
                                ItemContextMenu(item: item, model: model, store: store)
                            }
                            .onDrag { Paster.shared.itemProvider(for: item) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.contentBackground)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let feedback = model.feedback {
                Text(feedback).foregroundStyle(.primary)
            } else if TroveApp.shared.monitor.isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Text(pauseLabel)
                Button("Resume") { TroveApp.shared.resumeCapture() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "record.circle")
                    .foregroundStyle(.green)
                Text("Watching the clipboard")
            }
            Spacer()
            Text("\(store.totalCount) saved")
                .foregroundStyle(.secondary)
            if !Paster.shared.hasAccessibility {
                Button("Enable direct paste") { Paster.shared.requestAccessibility() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var pauseLabel: String {
        if let until = TroveApp.shared.monitor.pausedUntil {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Paused until \(formatter.string(from: until))"
        }
        return "Paused"
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: MainViewModel
    @ObservedObject private var updates = UpdateChecker.shared
    @LocalState private var newBoardSheet = false
    @LocalState private var dropTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppIdentity.name)
                    .font(.system(size: 18, weight: .semibold))
                Text("复制的内容，随时取回")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(
                        title: "Clipboard",
                        symbol: "clock.arrow.circlepath",
                        count: store.count(in: nil),
                        selected: model.destination == .clipboard,
                        tint: Theme.accent
                    ) {
                        model.destination = .clipboard
                        model.selection = []
                    }

                    HStack {
                        Text("PINBOARDS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            newBoardSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New pinboard")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                    if store.pinboards.isEmpty {
                        Text("No pinboards yet")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                    }

                    ForEach(store.pinboards) { board in
                        SidebarRow(
                            title: board.name,
                            symbol: "square.fill",
                            count: store.count(in: board.id),
                            selected: model.destination == .pinboard(board.id),
                            tint: Color(nsColor: board.color),
                            dot: true
                        ) {
                            model.destination = .pinboard(board.id)
                            model.selection = []
                        }
                        .overlay(alignment: .trailing) {
                            if dropTarget == board.id {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .onDrop(of: [Paster.itemIdentifier], isTargeted: Binding(
                            get: { dropTarget == board.id },
                            set: { dropTarget = $0 ? board.id : nil }
                        )) { providers in
                            handleDrop(providers, into: board.id)
                        }
                        .contextMenu {
                            Button("Rename…") { renameBoard(board) }
                            Button("Delete Pinboard", role: .destructive) { store.deletePinboard(board.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            if let release = updates.available {
                Button { updates.showAvailableUpdate() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("有可用更新").font(.system(size: 12, weight: .semibold))
                            Text("\(release.tagName) · 查看并下载").font(.system(size: 11))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }
                    .padding(10).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).padding(10)
                .accessibilityLabel("有可用更新 \(release.tagName)，查看并下载")
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    TroveWindows.shared.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Settings")

                Spacer()

                Button {
                    TroveWindows.shared.showPasteStack()
                } label: {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Paste stack")

                Menu {
                    Button("打开 \(AppIdentity.name)") { TroveWindows.shared.showMainWindow() }
                    Divider()
                    Button("Pause for 5 minutes") { TroveApp.shared.pauseCapture(300) }
                    Button("Pause for 1 hour") { TroveApp.shared.pauseCapture(3600) }
                    Button("Resume") { TroveApp.shared.resumeCapture() }
                    Divider()
                    Button("退出 \(AppIdentity.name)") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.thinMaterial)
        .sheet(isPresented: $newBoardSheet) {
            NewPinboardSheet(store: store) { board in
                model.destination = .pinboard(board.id)
                newBoardSheet = false
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], into board: UUID) -> Bool {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(Paster.itemIdentifier) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: Paster.itemIdentifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
                Task { @MainActor in
                    store.setPinboard(id, to: board)
                }
            }
        }
        return true
    }

    private func renameBoard(_ board: Pinboard) {
        let alert = NSAlert()
        alert.messageText = "Rename pinboard"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = board.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { store.renamePinboard(board.id, name: name) }
        }
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let tint: Color
    var dot: Bool = false
    var action: () -> Void

    @LocalState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if dot {
                        Circle().fill(tint).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? tint : Color.secondary)
                    }
                }
                .frame(width: 12)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? tint.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rows and menus

struct ItemRow: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: item.kind, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if item.kind == .text, let text = item.text {
                    Text(text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if item.kind == .link, let host = item.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if item.kind == .files {
                    Text("\(item.filePaths.count) file(s)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
            }
            SourceBadge(item: item, size: 14)
            Text(Format.relative(item.createdAt))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct ItemContextMenu: View {
    let item: ClipItem
    @ObservedObject var model: MainViewModel
    @ObservedObject var store: Store
    var onPreview: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        Button("粘贴到\(Paster.shared.destinationName)") {
            model.selection = [item.id]
            model.pasteSelection()
        }
        Button("以纯文本粘贴") {
            model.selection = [item.id]
            model.pasteSelection(plainText: true)
        }
        Button("复制") {
            model.selection = [item.id]
            model.copySelection()
        }
        Button("复制为纯文本") {
            model.selection = [item.id]
            model.copySelection(plainText: true)
        }
        Divider()
        Button("预览") {
            if let onPreview { onPreview() }
            else if let url = TroveWindows.shared.previewWindow(for: item, store: store) {
                url.makeKeyAndOrderFront(nil)
            }
        }
        if item.kind == .text, let onEdit { Button("编辑文本…", action: onEdit) }
        Button("加入粘贴队列") { TroveWindows.shared.stackModel.append([item.id]) }
        Button(item.pinned ? "取消固定" : "固定") {
            model.selection = [item.id]
            model.togglePinSelection()
        }
        Menu("固定到") {
            ForEach(store.pinboards) { board in
                Button(board.name) {
                    model.selection = [item.id]
                    model.moveSelection(to: board.id)
                }
            }
            Divider()
            Button("创建 Pinboard…") {
                model.selection = [item.id]
                TroveWindows.shared.showQuickPaste()
                model.showNewPinboard = true
            }
        }
        if !item.filePaths.isEmpty || item.imageURL != nil {
            Button("在访达中显示") {
                model.selection = [item.id]
                model.revealSelectionInFinder()
            }
        }
        Divider()
        Button("删除", role: .destructive) {
            model.selection = [item.id]
            model.deleteSelection()
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? (model.destination.pinboardID == nil ? "Nothing copied yet" : "This pinboard is empty") : "No matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty
                 ? "Copy something — text, images, links, colours or files — and it lands here."
                 : "Try a different search, or clear the filters.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if model.activeFilterCount > 0 {
                Button("Clear filters") { model.clearFilters() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter popover

struct FilterPopover: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("筛选")
                .font(.system(size: 12, weight: .semibold))

            filterSection("类型") {
                Picker("", selection: $model.kindFilter) {
                    Text("全部").tag(ItemKind?.none)
                    ForEach(ItemKind.allCases) { kind in
                        Text(kind.title).tag(ItemKind?.some(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            filterSection("来源应用") {
                Picker("", selection: $model.appFilter) {
                    Text("全部应用").tag(String?.none)
                    ForEach(store.knownApplications, id: \.bundleID) { app in
                        Text(app.name).tag(String?.some(app.bundleID))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            filterSection("复制时间") {
                Picker("", selection: Binding(
                    get: { model.dateFilter == nil ? 0 : 1 },
                    set: { model.dateFilter = $0 == 1 ? Calendar.current.startOfDay(for: Date()) : nil }
                )) {
                    Text("不限时间").tag(0)
                    Text("今天").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()
            HStack {
                Button("清除筛选") { model.clearFilters() }
                    .buttonStyle(.link)
                Spacer()
                Button("完成") { model.showFilters = false }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 300)
    }

    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - New pinboard sheet

struct NewPinboardSheet: View {
    @ObservedObject var store: Store
    var onCreate: (Pinboard) -> Void

    @LocalState private var name = ""
    @LocalState private var color = Pinboard.palette[0]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("创建 Pinboard")
                .font(.system(size: 15, weight: .semibold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                ForEach(Pinboard.palette, id: \.self) { hex in
                    Button {
                        color = hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(color == hex ? Color.primary.opacity(0.7) : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    let board = store.createPinboard(name: name.isEmpty ? "Pinboard" : name, colorHex: color)
                    onCreate(board)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}
