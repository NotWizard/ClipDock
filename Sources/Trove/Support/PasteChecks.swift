import AppKit

final class PasteCheckDelegate: NSObject, NSApplicationDelegate {
    let pid: pid_t
    let directory: URL
    let queueMode: Bool
    var status: Int32 = 1
    init(pid: pid_t, directory: URL, queueMode: Bool = false) { self.pid = pid; self.directory = directory; self.queueMode = queueMode }
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = MainActor.assumeIsolated { PasteChecks.run(pid: pid, directory: directory, queueMode: queueMode) }
        NSApp.stop(nil)
    }
}

@MainActor
enum PasteChecks {
    static func run(pid: pid_t, directory: URL, queueMode: Bool = false) -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        guard let receiver = NSRunningApplication(processIdentifier: pid),
              receiver.bundleIdentifier?.hasPrefix("app.trove.paste-test.") == true,
              Paster.shared.hasAccessibility else {
            print("FAIL disposable receiver and effective paste permissions are required")
            return 2
        }
        let pb = NSPasteboard.general
        guard let backup = SelfTest.copyPasteboard(pb) else {
            print("FAIL cannot preserve an original clipboard representation")
            return 2
        }
        var ownedChange: Int?
        defer {
            TroveWindows.shared.hideAll()
            if pb.changeCount == ownedChange {
                pb.clearContents()
                if !backup.isEmpty { pb.writeObjects(backup) }
            }
        }
        let menu = AppDelegate()
        menu.installMenus()
        let prefs = Preferences.shared
        prefs.pasteToActiveApp = true
        prefs.generateLinkPreviews = false
        prefs.soundEffects = false
        let store = Store.shared
        var chosen = ClipItem()
        for index in 0..<3 {
            var item = ClipItem()
            item.kind = .text
            item.text = index == 0 ? "CLIPDOCK_CARET_TEST" : "synthetic item \(index)"
            item.title = item.text!
            item.searchText = item.text!
            item.checksum = "paste-check-\(index)"
            item.createdAt = Date().addingTimeInterval(Double((index - 2) * 60))
            item.payloads = store.storePayloads(for: item.id, captured: [
                (NSPasteboard.PasteboardType.string.rawValue, Data(item.text!.utf8), 0),
                ("org.nspasteboard.TransientType", Data(), 0)
            ])
            store.insert(item)
            if index == 0 { chosen = item }
        }
        receiver.activate(options: [])
        pump(0.2)
        guard receiver.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            print("FAIL disposable receiver is not active; unlock the desktop and retry")
            return 2
        }
        check("disposable receiver is the original active application", true)
        let windows = TroveWindows.shared
        windows.showQuickPaste()
        pump(0.4)
        let model = TroveApp.shared.mainModel
        model.selection = [chosen.id]
        let before = store.items.map(\.id)
        let queue = TroveApp.shared.stackModel
        if queueMode {
            queue.append([chosen.id])
            queue.pasteNext { windows.hideAll() }
        } else { windows.commitSelection() }
        ownedChange = pb.changeCount
        check("commit begins with unchanged card order", store.items.map(\.id) == before && Paster.shared.isPasting && (queueMode || windows.quickPanel?.isVisible == true))
        if queueMode {
            check("queue retains its item until paste completes", queue.queue == [chosen.id])
            queue.pasteNext { windows.hideAll() }
        } else { windows.commitSelection() }
        let receipt = directory.appendingPathComponent("received.json")
        let deadline = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: receipt.path) && Date() < deadline { pump(0.05) }
        pump(0.2)
        let data = try? Data(contentsOf: receipt)
        let result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("Cmd-V reaches the receiver at its original caret", result?["text"] as? String == "left-CLIPDOCK_CARET_TEST-right")
        check("a repeated commit delivers exactly one paste", result?["count"] as? Int == 1)
        check("the panel is hidden before delivery completes", windows.quickPanel?.isVisible == false && !Paster.shared.isPasting)
        check("successful delivery promotes the existing history item", store.items.first?.id == chosen.id && store.totalCount == 3)
        check("original receiver remains active after delivery", receiver.isActive)
        if queueMode { check("successful queue delivery consumes its item", queue.isEmpty && queue.queue.isEmpty) }
        windows.showQuickPaste()
        pump(0.3)
        check("the next invocation begins with the pasted item", model.items.first?.id == chosen.id && model.current?.id == chosen.id)
        if let error = Paster.shared.lastError { print("INFO \(error)") }
        print(failures == 0 ? "PASTE CHECK OK" : "PASTE CHECK FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
