import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenus()

        TroveApp.shared.start()
        StatusBarController.shared.install()

        // Re-register hot keys once the run loop is live so Carbon sees a target.
        DispatchQueue.main.async {
            HotKeyCenter.shared.apply(from: Preferences.shared)
        }

        if !Preferences.shared.hasCompletedOnboarding {
            TroveWindows.shared.showOnboarding()
        } else {
            TroveWindows.shared.showQuickPaste()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { TroveWindows.shared.showQuickPaste() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Store.shared.isReadOnly || Store.shared.save(immediately: true) { return .terminateNow }
        TroveWindows.shared.showQuickPaste()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save(immediately: true)
    }

    @MainActor func installMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(title: AppIdentity.name)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let updates = NSMenuItem(title: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        let guide = NSMenuItem(title: "使用指南…", action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        appMenu.addItem(guide)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 \(AppIdentity.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "退出 \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let edit = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        for (title, selector, key) in [
            ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
            ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]
            edit.addItem(item)
        }
        let window = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        let close = NSMenuItem(title: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        close.target = self
        window.addItem(close)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @MainActor @objc private func openSettings() { TroveWindows.shared.showSettings() }
    @MainActor @objc private func openGuide() { TroveWindows.shared.showOnboarding() }
    @MainActor @objc private func checkUpdates() {
        TroveWindows.shared.showSettings(about: true)
        Task { await UpdateChecker.shared.check() }
    }
    @MainActor @objc private func closeWindow() {
        if TroveWindows.shared.quickPanel?.isVisible == true { TroveWindows.shared.closeQuickPaste() }
        else { NSApp.keyWindow?.performClose(nil) }
    }
}
