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
    static func checkOCR() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("\(passed ? "PASS" : "FAIL")  \(label)")
            if !passed { failures += 1 }
        }
        let store = Store.shared
        Preferences.shared.generateLinkPreviews = false
        OCRService.shared.prewarm()
        let samples: [(String, [String], NSSize)] = [
            ("English", ["CLIPDOCK OCR 2468"], NSSize(width: 1000, height: 200)),
            ("Chinese", ["中文截图检索测试"], NSSize(width: 1000, height: 200)),
            ("mixed", ["CLIPDOCK OCR 2468", "中文截图检索测试"], NSSize(width: 1000, height: 260)),
            ("wide", ["中文截图检索测试"], NSSize(width: 2000, height: 300)),
            ("tall", ["中文截图检索测试"], NSSize(width: 800, height: 2000))
        ]
        var lastData = Data()
        var lastID = UUID()
        for (label, lines, size) in samples {
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                for (index, line) in lines.enumerated() {
                    (line as NSString).draw(at: NSPoint(x: 20, y: size.height - 80 - CGFloat(index * 80)),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
                }
                return true
            }
            let data = ClipboardMonitor.pngData(from: image)!
            var item = ClipItem(); item.kind = .image; item.searchText = "image png"; item.checksum = UUID().uuidString
            item.imageName = store.storeImage(for: item.id, data: data)
            store.insert(item)
            let start = Date()
            await OCRService.shared.recognize(imageData: data, itemID: item.id)
            print("INFO OCR \(label): \(Date().timeIntervalSince(start)) seconds")
            let query = label == "English" ? "CLIPDOCK 2468" : "中文 截图"
            check("\(label) OCR is searchable through Store", store.items(in: nil, query: query, kind: .image, bundleID: nil, since: nil).contains { $0.id == item.id })
            lastData = data; lastID = item.id
        }
        let before = store.items.first(where: { $0.id == lastID })!.searchText
        await OCRService.shared.recognize(imageData: lastData, itemID: lastID)
        check("repeated OCR does not duplicate index text", store.items.first(where: { $0.id == lastID })?.searchText == before)
        await OCRService.shared.recognize(imageData: Data([0,1,2]), itemID: lastID)
        check("invalid image bytes preserve the existing index", store.items.first(where: { $0.id == lastID })?.searchText == before)
        let pending = Task { await OCRService.shared.recognize(imageData: lastData, itemID: lastID) }
        await Task.yield()
        store.delete(ids: [lastID])
        await pending.value
        check("OCR cannot resurrect a deleted image", !store.items.contains { $0.id == lastID })
        print(failures == 0 ? "OCR CHECK OK" : "OCR FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }

}
