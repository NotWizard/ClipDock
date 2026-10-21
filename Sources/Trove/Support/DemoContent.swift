import AppKit

/// Explicit --demo / --demo-update launch modes use an isolated temporary library.
@MainActor
enum DemoContent {
    static func prepare(update: Bool) {
        let prefs = Preferences.shared
        prefs.hasCompletedOnboarding = true
        prefs.generateLinkPreviews = false
        prefs.automaticallyChecksForUpdates = false
        prefs.pasteToActiveApp = false
        prefs.soundEffects = false
        let store = Store.shared
        let board = store.createPinboard(name: "常用片段", colorHex: "4C8BF5")
        let samples = [
            ("com.google.Chrome", "Google Chrome", "设计灵感随手存\n好想法，下一次用得到。\n\n合成演示内容"),
            ("com.apple.Notes", "备忘录", "周末清单\n买一束花\n整理照片\n读完一本书"),
            ("com.apple.Safari", "Safari", "https://github.com/NotWizard/ClipDock"),
            ("com.apple.TextEdit", "文本编辑", "Hi! Thanks for getting in touch.\nI'll get back to you shortly."),
            ("com.apple.MobileSMS", "信息", "晚上七点见！\n地址已经发给你了。"),
            ("com.apple.Preview", "预览", "#FF8C73")
        ]
        for (index, sample) in samples.enumerated() {
            var item = ClipItem()
            item.title = sample.2.components(separatedBy: "\n").first ?? sample.2
            item.text = sample.2
            item.searchText = sample.2
            item.sourceBundleID = sample.0
            item.sourceName = sample.1
            item.createdAt = Date().addingTimeInterval(Double(-index * 180))
            item.checksum = "clipdock-demo-\(index)"
            if index == 2 { item.kind = .link; item.urlString = sample.2; item.title = "ClipDock · GitHub" }
            if index == 5 { item.kind = .color; item.colorHex = "FF8C73" }
            item.payloads = store.storePayloads(for: item.id, captured: [(NSPasteboard.PasteboardType.string.rawValue, Data(sample.2.utf8), 0)])
            store.insert(item)
        }
        if let first = store.items.first {
            var pinned = ClipItem()
            pinned.title = "常用签名（合成示例）"
            pinned.text = "Best regards,\nAlex"
            pinned.searchText = pinned.text!
            pinned.sourceBundleID = first.sourceBundleID
            pinned.checksum = "clipdock-demo-board"
            pinned.pinboardID = board.id
            store.insert(pinned)
        }
        store.save(immediately: true)
        if update {
            let release = AppRelease(tagName: "v1.3.0", htmlURL: URL(string: "https://github.com/NotWizard/ClipDock/releases/tag/v1.3.0")!,
                                     body: "合成演示版本，用于展示更新提醒。\n\n• 更快地找回复制的内容\n• 改善键盘导航与卡片预览", draft: false, prerelease: false)
            let object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(release))
            prefs.cachedUpdate = try! JSONSerialization.data(withJSONObject: ["repository": prefs.updateRepository, "release": object])
        }
    }
}
