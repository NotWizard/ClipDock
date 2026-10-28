import AppKit

/// Storage regressions run in a fresh process and temporary library per case.
@MainActor
enum StoreChecks {
    static func run(_ name: String) -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL")  \(label)")
            if !passed { failures += 1 }
        }
        func text(_ value: String) -> ClipItem {
            var item = ClipItem()
            item.title = value; item.text = value; item.searchText = value
            item.checksum = UUID().uuidString
            item.payloads = Store.shared.storePayloads(for: item.id, captured: [
                (NSPasteboard.PasteboardType.string.rawValue, Data(value.utf8), 0)
            ])
            Store.shared.insert(item)
            return item
        }
        guard name == "retention" else { print("FAIL unknown storage check: \(name)"); return 1 }
        let store = Store.shared
        Preferences.shared.historyLimit = 2
        let pinned = text("protected pin")
        store.togglePin(pinned.id)
        let board = store.createPinboard(name: "protected board", colorHex: "4C8BF5")
        let member = text("protected board member")
        store.setPinboard(member.id, to: board.id)
        for index in 0..<3 { _ = text("ordinary history \(index)") }
        check("history cap preserves individual pins", store.items.contains { $0.id == pinned.id && $0.pinned })
        check("history cap preserves board members", store.items.contains { $0.id == member.id && $0.pinboardID == board.id })
        check("history cap counts only unpinned loose entries", store.items.filter { !$0.pinned && $0.pinboardID == nil }.count == 2)
        check("protected pin keeps its original payload", store.payloadData(for: pinned).contains { $0.data == Data("protected pin".utf8) })
        store.save(immediately: true)
        let data = try? Data(contentsOf: Store.root.appendingPathComponent("library.json"))
        let manifest = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let saved = manifest?["items"] as? [[String: Any]] ?? []
        check("protected pin and board are committed to disk", saved.contains { $0["id"] as? String == pinned.id.uuidString && $0["pinned"] as? Bool == true } && saved.contains { $0["id"] as? String == member.id.uuidString })
        print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
