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
        if name == "dynamic-limit" {
            let store = Store.shared
            let prefs = Preferences.shared
            prefs.historyLimit = 0
            let pinned = text("protected pin")
            store.togglePin(pinned.id)
            let board = store.createPinboard(name: "protected", colorHex: "4C8BF5")
            let member = text("protected member")
            store.setPinboard(member.id, to: board.id)
            for i in 0..<5 { _ = text("history \(i)") }
            prefs.historyLimit = 2
            check("lowering the cap applies before another capture", store.items.filter { !$0.pinned && $0.pinboardID == nil }.count == 2)
            check("lowering cap preserves fixed and board records", store.items.contains { $0.id == pinned.id } && store.items.contains { $0.id == member.id })
            store.togglePin(pinned.id)
            check("unpinning reapplies the cap", store.items.filter { !$0.pinned && $0.pinboardID == nil }.count == 2)
            store.deletePinboard(board.id)
            check("deleting a board reapplies the cap", store.items.count == 2)
            let retained = store.items.first!
            store.setPinboard(retained.id, to: UUID())
            check("stale board identifiers cannot hide records", store.items.first(where: { $0.id == retained.id }) == retained)
            prefs.historyLimit = 0
            for i in 0..<3 { _ = text("unlimited \(i)") }
            check("zero cap permits unlimited ordinary history", store.items.count == 5)
            store.save(immediately: true)
            let primary = Store.root.appendingPathComponent("library.json")
            let preserved = Store.root.appendingPathComponent("before-limit.json")
            try! FileManager.default.moveItem(at: primary, to: preserved)
            try! FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
            prefs.historyLimit = 1
            check("failed immediate trimming keeps all original records", store.items.count == 5 && store.items.allSatisfy { !store.payloadData(for: $0).isEmpty })
            try! FileManager.default.removeItem(at: primary)
            try! FileManager.default.moveItem(at: preserved, to: primary)
            check("retrying save reapplies the pending cap", store.save(immediately: true) && store.items.count == 1)
            print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
            return failures == 0 ? 0 : 1
        }
        if name == "dedupe" {
            let store = Store.shared
            let first = text("duplicate bytes")
            for _ in 0..<100 {
                var duplicate = first; duplicate.id = UUID()
                duplicate.payloads = store.storePayloads(for: duplicate.id, captured: [(NSPasteboard.PasteboardType.string.rawValue, Data("duplicate bytes".utf8), 0)])
                duplicate.imageName = store.storeImage(for: duplicate.id, data: Data([1,2,3]))
                let result = store.insert(duplicate)
                check("duplicate uses original ID", !result.inserted && result.id == first.id)
            }
            let directories = try! FileManager.default.contentsOfDirectory(at: Store.itemsDirectory, includingPropertiesForKeys: nil)
            check("100 duplicate captures retain exactly one directory", directories.count == 1)
            _ = store.insert(first)
            check("reinserting the same ID keeps original bytes", store.payloadData(for: first).contains { $0.data == Data("duplicate bytes".utf8) })
            _ = store.eraseHistory(keepingPinned: false)
            check("erase leaves no duplicate payload directories", (try! FileManager.default.contentsOfDirectory(at: Store.itemsDirectory, includingPropertiesForKeys: nil)).isEmpty)
            print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
            return failures == 0 ? 0 : 1
        }
        if ["startup-cleanup", "missing-manifest", "recovery-cleanup"].contains(name) {
            let fm = FileManager.default
            let orphanID = UUID()
            let orphan = Store.itemsDirectory.appendingPathComponent(orphanID.uuidString)
            try! fm.createDirectory(at: orphan, withIntermediateDirectories: true)
            try! Data("orphan bytes".utf8).write(to: orphan.appendingPathComponent("payload.bin"))
            let primary = Store.root.appendingPathComponent("library.json")
            let empty = try! JSONSerialization.data(withJSONObject: ["version":1,"pinboards":[],"items":[]])
            if name != "missing-manifest" { try! empty.write(to: primary) }
            if name == "recovery-cleanup" {
                try! empty.write(to: Store.root.appendingPathComponent("library-backup.json"))
                try! Data("{broken".utf8).write(to: primary)
            }
            let foreign = Store.itemsDirectory.appendingPathComponent("foreign-cache")
            try! fm.createDirectory(at: foreign, withIntermediateDirectories: false)
            let store = Store.shared
            if name == "startup-cleanup" {
                check("healthy startup cleans legacy orphan directories", !fm.fileExists(atPath: orphan.path))
            } else {
                check("recovery does not discard unindexed content", fm.fileExists(atPath: orphan.path))
                check("missing or damaged metadata is visible", store.notice != nil)
            }
            check("non-UUID folders are never cleaned automatically", fm.fileExists(atPath: foreign.path))
            print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
            return failures == 0 ? 0 : 1
        }
        if ["delete-failure", "erase-failure", "trim-failure", "backup-failure"].contains(name) {
            let store = Store.shared
            let first = text("first durable payload")
            let second = text("second durable payload")
            let queue = PasteStackModel(store: store)
            queue.append([first.id, second.id])
            store.save(immediately: true)
            let fm = FileManager.default
            let path = Store.root.appendingPathComponent(name == "backup-failure" ? "library-backup.json" : "library.json")
            let preserved = Store.root.appendingPathComponent("before-failure.json")
            try! fm.moveItem(at: path, to: preserved)
            try! fm.createDirectory(at: path, withIntermediateDirectories: false)
            if name == "trim-failure" {
                Preferences.shared.historyLimit = 1
                _ = text("new capture while full")
                check("failed trim retains existing records", store.items.contains { $0.id == first.id } && store.items.contains { $0.id == second.id })
            } else {
                let success = name == "erase-failure" ? store.eraseHistory(keepingPinned: false) : store.delete(ids: [first.id])
                if name == "backup-failure" {
                    check("primary commit can succeed with a stale backup", success && !store.items.contains { $0.id == first.id })
                } else {
                    check("failed destructive save reports failure", !success)
                    check("failed destructive save restores in-memory records", store.items.contains { $0.id == first.id } && store.items.contains { $0.id == second.id })
                }
            }
            if name != "backup-failure" {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                check("rolled-back deletion preserves queued records", queue.queue == [first.id, second.id])
            }
            check("failure retains the original payload bytes", store.payloadData(for: first).contains { $0.data == Data("first durable payload".utf8) })
            check("failure provides visible feedback", store.notice != nil)
            try! fm.removeItem(at: path)
            try! fm.moveItem(at: preserved, to: path)
            check("saving works again after the fault is repaired", store.save(immediately: true))
            print(failures == 0 ? "STORAGE CHECK OK" : "STORAGE FAILURES: \(failures)")
            return failures == 0 ? 0 : 1
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
