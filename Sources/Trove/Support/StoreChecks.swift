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
        let recoveryCases = ["corrupt", "backup-recovery", "missing-primary", "unreadable", "future-version"]
        if recoveryCases.contains(name) {
            let fm = FileManager.default
            try! fm.createDirectory(at: Store.root, withIntermediateDirectories: true)
            let primary = Store.root.appendingPathComponent("library.json")
            let backup = Store.root.appendingPathComponent("library-backup.json")
            let bad = Data("{broken library".utf8)
            var fixture = ClipItem()
            fixture.title = "recovered record"; fixture.text = fixture.title
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let record = try! JSONSerialization.jsonObject(with: encoder.encode(fixture))
            func snapshot(_ version: Int = 1) -> Data {
                try! JSONSerialization.data(withJSONObject: ["version": version, "pinboards": [], "items": [record]])
            }
            switch name {
            case "corrupt": try! bad.write(to: primary)
            case "backup-recovery": try! bad.write(to: primary); try! snapshot().write(to: backup)
            case "missing-primary": try! snapshot().write(to: backup)
            case "unreadable": try! fm.createDirectory(at: primary, withIntermediateDirectories: false)
            default: try! snapshot(2).write(to: primary); try! snapshot().write(to: backup)
            }
            let originalBytes = try? Data(contentsOf: primary)
            let store = Store.shared
            if ["backup-recovery", "missing-primary"].contains(name) {
                check("valid backup restores existing record", !store.isReadOnly && store.items.first?.id == fixture.id)
                check("backup recovery is visible to the user", store.notice != nil)
                if name == "backup-recovery" {
                    let originals = try! fm.contentsOfDirectory(at: Store.root, includingPropertiesForKeys: nil)
                    check("damaged original is preserved before replacement", originals.contains { $0.lastPathComponent.hasPrefix("library-corrupt-") && (try? Data(contentsOf: $0)) == bad })
                }
                check("recovered library can be committed", store.save(immediately: true))
                check("successful save mirrors the current backup", (try? Data(contentsOf: primary)) == (try? Data(contentsOf: backup)))
            } else {
                check("failed load enters visible read-only mode", store.isReadOnly && store.notice != nil)
                var incoming = ClipItem(); incoming.title = "must not overwrite"
                check("read-only mode refuses capture insertion", !store.insert(incoming).inserted && store.items.isEmpty)
                check("read-only mode refuses payload writes", store.storePayloads(for: incoming.id, captured: [("public.data", Data([1]), 0)]).isEmpty)
                store.eraseHistory(keepingPinned: false)
                check("read-only save is refused", !store.save(immediately: true))
                if name == "corrupt" {
                    check("corrupt file is unchanged after save and erase", (try? Data(contentsOf: primary)) == bad)
                    try! snapshot().write(to: primary)
                    store.reload()
                    check("retry reopens a manually repaired library", !store.isReadOnly && store.items.first?.id == fixture.id)
                } else if name == "future-version" {
                    check("newer schema cannot be downgraded by a backup", (try? Data(contentsOf: primary)) == originalBytes)
                } else {
                    var directory: ObjCBool = false
                    check("unreadable original is preserved", fm.fileExists(atPath: primary.path, isDirectory: &directory) && directory.boolValue)
                }
            }
            print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
            return failures == 0 ? 0 : 1
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
