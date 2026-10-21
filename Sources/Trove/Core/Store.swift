import AppKit
import Combine
import Foundation

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // MARK: Locations

    nonisolated static var root: URL {
        if let directory = ProcessInfo.processInfo.environment["TROVE_TEST_DATA_DIR"] {
            return URL(fileURLWithPath: directory, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Trove", isDirectory: true)
    }

    nonisolated static var itemsDirectory: URL {
        root.appendingPathComponent("Items", isDirectory: true)
    }

    nonisolated private static var manifestURL: URL {
        root.appendingPathComponent("library.json")
    }

    // MARK: State

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var pinboards: [Pinboard] = []
    @Published var lastCopiedID: UUID?

    private var saveWorkItem: DispatchWorkItem?

    private struct Manifest: Codable {
        var version: Int = 1
        var pinboards: [Pinboard]
        var items: [ClipItem]
    }

    // MARK: Init

    private init() {
        try? FileManager.default.createDirectory(at: Store.itemsDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Store.manifestURL) else {
            pinboards = []
            items = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            pinboards = []
            items = []
            return
        }
        pinboards = manifest.pinboards
        items = manifest.items
    }

    func save(immediately: Bool = false) {
        if immediately {
            saveWorkItem?.cancel()
            writeManifest()
            return
        }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.writeManifest() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @discardableResult
    private func writeManifest() -> Bool {
        let manifest = Manifest(pinboards: pinboards, items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(manifest)
            try FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
            try data.write(to: Store.manifestURL, options: .atomic)
            return true
        } catch {
            NSLog("Trove: library save failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Item payload storage

    /// Persists raw pasteboard flavours next to the manifest.
    func storePayloads(for id: UUID, captured: [(type: String, data: Data, index: Int)]) -> [PayloadFile] {
        let dir = Store.itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [PayloadFile] = []
        for (index, entry) in captured.enumerated() {
            let name = String(format: "%02d-%@.bin", index, Store.sanitize(entry.type))
            let url = dir.appendingPathComponent(name)
            do {
                try entry.data.write(to: url, options: .atomic)
                files.append(PayloadFile(type: entry.type,
                                         filename: "\(id.uuidString)/\(name)",
                                         itemIndex: entry.index))
            } catch {
                continue
            }
        }
        return files
    }

    func storeImage(for id: UUID, data: Data, fileExtension: String = "png") -> String? {
        let dir = Store.itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "preview.\(fileExtension)"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return "\(id.uuidString)/\(name)"
        } catch {
            return nil
        }
    }

    func payloadData(for item: ClipItem) -> [(type: String, data: Data, index: Int)] {
        item.payloads.compactMap { payload in
            let url = Store.itemsDirectory.appendingPathComponent(payload.filename)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (payload.type, data, payload.itemIndex ?? 0)
        }
    }

    private static func sanitize(_ type: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(type.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // MARK: Mutations

    /// Inserts a capture, or promotes an identical existing entry.
    /// Returns the identifier actually present in the library plus whether the
    /// capture was new — callers must use this id for follow-up work (OCR,
    /// link previews) because deduplication can discard the incoming id.
    @discardableResult
    func insert(_ item: ClipItem) -> (id: UUID, inserted: Bool) {
        if let existing = items.first(where: { $0.checksum == item.checksum && $0.pinboardID == nil }) {
            moveToTop(existing.id)
            return (existing.id, false)
        }
        items.insert(item, at: 0)
        trimHistory()
        save()
        return (item.id, true)
    }

    func moveToTop(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.createdAt = Date()
        items.insert(item, at: 0)
        save()
    }

    func update(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    @discardableResult
    func updateText(_ id: UUID, text: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .text else { return false }
        let previous = items[index]
        var item = previous
        let data = Data(text.utf8)
        let name = "\(id.uuidString)/edited-\(UUID().uuidString).txt"
        do {
            try FileManager.default.createDirectory(at: Store.itemsDirectory.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
            try data.write(to: Store.itemsDirectory.appendingPathComponent(name), options: .atomic)
        }
        catch { return false }
        // ponytail: keep earlier payload versions inside this item's directory; compact if editing volume grows.
        item.payloads = [PayloadFile(type: NSPasteboard.PasteboardType.string.rawValue, filename: name, itemIndex: 0)]
        item.text = text
        item.title = ClipboardMonitor.title(for: text)
        item.searchText = text
        item.checksum = ClipboardMonitor.checksum([(NSPasteboard.PasteboardType.string.rawValue, data, 0)])
        items[index] = item
        if writeManifest() {
            saveWorkItem?.cancel()
            return true
        }
        items[index] = previous
        return false
    }

    func delete(ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for item in removed {
            try? FileManager.default.removeItem(at: Store.itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true))
        }
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        if !items[index].pinned {
            // unpinning removes it from any pinboard
            items[index].pinboardID = nil
        }
        save()
    }

    func setPinboard(_ id: UUID, to pinboardID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinboardID = pinboardID
        items[index].pinned = pinboardID != nil
        if let pinboardID {
            let nextOrder = (items.filter { $0.pinboardID == pinboardID }.map(\.displayOrder).max() ?? 0) + 1
            items[index].displayOrder = nextOrder
            if let pIndex = pinboards.firstIndex(where: { $0.id == pinboardID }), pinboards[pIndex].name.isEmpty {
                pinboards[pIndex].name = "Pinboard"
            }
        }
        save()
    }

    func reorder(_ id: UUID, relativeTo target: UUID, after: Bool = false) {
        guard id != target,
              let source = items.first(where: { $0.id == id }),
              let board = source.pinboardID,
              items.first(where: { $0.id == target })?.pinboardID == board else { return }
        var ordered = items(in: board, query: "", kind: nil, bundleID: nil, since: nil).map(\.id)
        ordered.removeAll { $0 == id }
        guard let targetIndex = ordered.firstIndex(of: target) else { return }
        ordered.insert(id, at: targetIndex + (after ? 1 : 0))
        for (order, itemID) in ordered.enumerated() {
            if let index = items.firstIndex(where: { $0.id == itemID }) { items[index].displayOrder = order }
        }
        save()
    }

    func eraseHistory(keepingPinned: Bool = true) {
        let survivors = keepingPinned ? items.filter { $0.pinned || $0.pinboardID != nil } : []
        let removed = items.filter { item in !survivors.contains(where: { $0.id == item.id }) }
        items = survivors
        for item in removed {
            try? FileManager.default.removeItem(at: Store.itemsDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true))
        }
        save(immediately: true)
    }

    private func trimHistory() {
        let limit = Preferences.shared.historyLimit
        guard limit > 0 else { return }
        let loose = items.filter { $0.pinboardID == nil }
        guard loose.count > limit else { return }
        let overflow = loose.dropFirst(limit)
        let ids = Set(overflow.map(\.id))
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            try? FileManager.default.removeItem(at: Store.itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }

    // MARK: Pinboards

    @discardableResult
    func createPinboard(name: String, colorHex: String) -> Pinboard {
        let board = Pinboard(name: name, colorHex: colorHex, createdAt: Date())
        pinboards.append(board)
        save()
        return board
    }

    func renamePinboard(_ id: UUID, name: String) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].name = name
        save()
    }

    func recolorPinboard(_ id: UUID, colorHex: String) {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[index].colorHex = colorHex
        save()
    }

    func deletePinboard(_ id: UUID) {
        pinboards.removeAll { $0.id == id }
        for index in items.indices where items[index].pinboardID == id {
            items[index].pinboardID = nil
            items[index].pinned = false
        }
        save()
    }

    func pinboard(_ id: UUID?) -> Pinboard? {
        guard let id else { return nil }
        return pinboards.first { $0.id == id }
    }

    // MARK: Queries

    /// Items for a destination. `nil` destination == clipboard history.
    func items(in board: UUID?, query: String, kind: ItemKind?, bundleID: String?, since: Date?) -> [ClipItem] {
        var pool = items.filter { item in
            if let board {
                return item.pinboardID == board
            }
            return item.pinboardID == nil
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            let tokens = needle.split(separator: " ").map(String.init)
            pool = pool.filter { item in
                let haystack = (item.title + " " + item.searchText).lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }
        }
        if let kind { pool = pool.filter { $0.kind == kind } }
        if let bundleID { pool = pool.filter { $0.sourceBundleID == bundleID } }
        if let since { pool = pool.filter { $0.createdAt >= since } }

        if board != nil {
            return pool.sorted { $0.displayOrder < $1.displayOrder }
        }
        return pool.sorted { $0.createdAt > $1.createdAt }
    }

    var totalCount: Int { items.count }

    func count(in board: UUID?) -> Int {
        items.reduce(0) { $0 + ((board == nil ? $1.pinboardID == nil : $1.pinboardID == board) ? 1 : 0) }
    }

    /// Distinct source applications present in the library, for the filter menu.
    var knownApplications: [(bundleID: String, name: String)] {
        var seen: [String: String] = [:]
        for item in items {
            guard let bundleID = item.sourceBundleID else { continue }
            seen[bundleID] = item.sourceName ?? bundleID
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
