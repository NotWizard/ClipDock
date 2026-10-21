import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private let contextMenu = NSMenu()

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = TroveBrand.statusIcon()
            button.toolTip = "\(AppIdentity.name) — 剪贴板历史（右键显示菜单）"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu.delegate = self
        statusItem = item
        setVisible(Preferences.shared.showMenuBarIcon)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil { install(); return }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    func refresh() {
        statusItem?.button?.image = TroveBrand.statusIcon(paused: TroveApp.shared.isPaused)
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = contextMenu
        menu.removeAllItems()

        let header = NSMenuItem(title: TroveApp.shared.isPaused ? TroveApp.shared.pauseDescription : "正在记录剪贴板",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = item("显示剪贴板", #selector(openQuick), "")
        if let combo = KeyCombo.decode(Preferences.shared.activateShortcut) {
            let key = KeyCodeNames.name(for: combo.keyCode)
            if key.count == 1 {
                open.keyEquivalent = key.lowercased()
                var flags: NSEvent.ModifierFlags = []
                if combo.modifiers & KeyCombo.command != 0 { flags.insert(.command) }
                if combo.modifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
                if combo.modifiers & KeyCombo.option != 0 { flags.insert(.option) }
                if combo.modifiers & KeyCombo.control != 0 { flags.insert(.control) }
                open.keyEquivalentModifierMask = flags
            }
        }
        menu.addItem(open)
        menu.addItem(item("管理剪贴板…", #selector(openMain), ""))
        menu.addItem(item("粘贴队列…", #selector(openStack), ""))
        if !HotKeyCenter.shared.conflicts.isEmpty {
            let conflict = NSMenuItem(title: "快捷键被占用：\(HotKeyCenter.shared.conflicts.joined(separator: "、"))",
                                      action: nil, keyEquivalent: "")
            conflict.isEnabled = false
            menu.addItem(conflict)
        }

        menu.addItem(.separator())

        if TroveApp.shared.isPaused {
            menu.addItem(item("恢复记录", #selector(resume), ""))
        } else {
            let pause = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(item("5 分钟", #selector(pause5), ""))
            submenu.addItem(item("1 小时", #selector(pause60), ""))
            submenu.addItem(item("直到明天", #selector(pauseTomorrow), ""))
            submenu.addItem(item("直到手动恢复", #selector(pauseForever), ""))
            pause.submenu = submenu
            menu.addItem(pause)
        }

        menu.addItem(.separator())

        let pinboards = NSMenuItem(title: "Pinboards", action: nil, keyEquivalent: "")
        let pinMenu = NSMenu()
        for board in TroveApp.shared.store.pinboards {
            let entry = item(board.name, #selector(openPinboard(_:)), "")
            entry.representedObject = board.id.uuidString
            pinMenu.addItem(entry)
        }
        if !pinMenu.items.isEmpty { pinMenu.addItem(.separator()) }
        pinMenu.addItem(item("创建 Pinboard…", #selector(newPinboard), ""))
        pinboards.submenu = pinMenu
        menu.addItem(pinboards)

        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(item("检查更新…", #selector(checkUpdates), ""))
        menu.addItem(item("清空历史…", #selector(eraseHistory), ""))
        menu.addItem(item("关于 \(AppIdentity.name)", #selector(openAbout), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 \(AppIdentity.name)", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        return entry
    }

    // MARK: Actions

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.option) {
            rebuildMenu()
            sender.highlight(true)
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            sender.highlight(false)
        } else {
            TroveApp.shared.toggleClipboardPanel()
        }
    }

    @objc private func openMain() { TroveWindows.shared.showMainWindow() }
    @objc private func openQuick() { TroveApp.shared.showQuickPaste() }
    @objc private func openStack() { TroveWindows.shared.showPasteStack() }
    @objc private func openSettings() { TroveWindows.shared.showSettings() }
    @objc private func checkUpdates() {
        TroveWindows.shared.showSettings(about: true)
        Task { await UpdateChecker.shared.check() }
    }
    @objc private func resume() { TroveApp.shared.resumeCapture() }
    @objc private func pause5() { TroveApp.shared.pauseCapture(300) }
    @objc private func pause60() { TroveApp.shared.pauseCapture(3600) }
    @objc private func pauseTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        TroveApp.shared.pauseCapture(tomorrow.timeIntervalSinceNow)
    }
    @objc private func pauseForever() { TroveApp.shared.pauseCapture(nil) }
    @objc private func newPinboard() {
        TroveWindows.shared.showQuickPaste()
        TroveApp.shared.mainModel.showNewPinboard = true
    }
    @objc private func openPinboard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        TroveWindows.shared.showQuickPaste()
        TroveApp.shared.mainModel.selectDestination(.pinboard(id))
    }
    @objc private func eraseHistory() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "固定的条目和 Pinboard 会保留。清空后无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            TroveApp.shared.store.eraseHistory(keepingPinned: true)
        }
    }
    @objc private func openAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.name,
            .applicationVersion: Bundle.main.shortVersion,
            .credits: NSAttributedString(string: "原生 macOS 剪贴板历史，内容存储在本机。\n可选的链接预览会请求对应网站。"),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
