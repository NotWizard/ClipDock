import AppKit

@MainActor
enum CaptureChecks {
    static func run() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL")  \(label)")
            if !passed { failures += 1 }
        }
        let pasteboard = NSPasteboard.withUniqueName()
        let store = Store.shared
        let prefs = Preferences.shared
        prefs.generateLinkPreviews = false
        let monitor = ClipboardMonitor(store: store, prefs: prefs, pasteboard: pasteboard)
        defer { monitor.stop(); pasteboard.releaseGlobally() }
        func write(_ value: String, marker: String? = nil) async {
            let entry = NSPasteboardItem()
            entry.setString(value, forType: .string)
            if let marker { entry.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
            pasteboard.clearContents(); pasteboard.writeObjects([entry])
            try? await Task.sleep(for: .milliseconds(450))
        }
        monitor.start()
        await write("before pause")
        check("monitor records changes before pause", store.items.first?.text == "before pause")
        monitor.pause(for: nil)
        await write("private manual pause")
        check("manual pause ignores content", !store.items.contains { $0.text == "private manual pause" })
        monitor.resume()
        try? await Task.sleep(for: .milliseconds(450))
        check("manual resume does not backfill", !store.items.contains { $0.text == "private manual pause" })
        await write("after manual resume")
        check("new copy after resume is captured", store.items.first?.text == "after manual resume")
        monitor.pause(for: 0.1)
        await write("private timed pause")
        check("timed pause expires without backfill", !monitor.isPaused && !store.items.contains { $0.text == "private timed pause" })
        await write("after timed resume")
        check("new copy after timed resume is captured", store.items.first?.text == "after timed resume")
        await write("concealed", marker: "org.nspasteboard.ConcealedType")
        await write("transient", marker: "org.nspasteboard.TransientType")
        check("privacy markers remain effective after resumes", !store.items.contains { ["concealed", "transient"].contains($0.text ?? "") })
        var capturedIDs: [UUID] = []
        monitor.onCapture = { capturedIDs.append($0.id) }
        await write("duplicate capture")
        await write("duplicate capture")
        check("duplicate notifications use the retained record ID", capturedIDs.count == 2 && Set(capturedIDs).count == 1 && store.items.contains { $0.id == capturedIDs[0] })
        let directories = (try? FileManager.default.contentsOfDirectory(at: Store.itemsDirectory, includingPropertiesForKeys: nil)) ?? []
        check("duplicate capture leaves no unreferenced directories", directories.count == store.items.count)
        print(failures == 0 ? "CAPTURE CHECK OK" : "CAPTURE FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
