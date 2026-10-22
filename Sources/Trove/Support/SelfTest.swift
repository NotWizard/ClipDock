import AppKit
import SwiftUI

/// Headless verification entry points. Triggered by command-line flags so the
/// same binary can be smoke-tested without a running UI.
@MainActor
enum SelfTest {

    // MARK: Core query / storage checks

    static func run() -> Int32 {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Trove-selftest-\(UUID().uuidString)", isDirectory: true)
        setenv("TROVE_TEST_DATA_DIR", testRoot.path, 1)
        let pb = NSPasteboard.withUniqueName()
        defer {
            pb.releaseGlobally()
            try? FileManager.default.removeItem(at: testRoot)
            UserDefaults.standard.removePersistentDomain(forName: "app.trove.test.\(testRoot.lastPathComponent)")
        }
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name) \(detail)")
            }
        }

        let store = Store.shared
        let marker = "trove-selftest-\(UUID().uuidString.prefix(6))"
        var created: [UUID] = []
        let board = store.createPinboard(name: "\(marker) board", colorHex: "34A853")

        // Insert one item per kind.
        for (index, kind) in ItemKind.allCases.enumerated() {
            var item = ClipItem()
            item.kind = kind
            item.sourceBundleID = "com.example.app\(index)"
            item.sourceName = "Example \(index)"
            item.title = "\(marker) title \(index)"
            item.searchText = "\(marker) body zebra\(index)"
            item.checksum = "\(marker)-checksum-\(index)"
            item.createdAt = Date().addingTimeInterval(TimeInterval(-index * 60))
            let result = store.insert(item)
            if result.inserted { created.append(result.id) }
        }

        check("inserted one item per kind", created.count == ItemKind.allCases.count, "got \(created.count)")

        let matches = store.items(in: nil, query: marker, kind: nil, bundleID: nil, since: nil)
        check("text search finds the batch", matches.count == ItemKind.allCases.count, "got \(matches.count)")

        let zebra = store.items(in: nil, query: "zebra3", kind: nil, bundleID: nil, since: nil)
        check("token search narrows to one", zebra.count == 1, "got \(zebra.count)")

        let images = store.items(in: nil, query: marker, kind: .image, bundleID: nil, since: nil)
        check("kind filter", images.count == 1 && images.first?.kind == .image, "got \(images.count)")

        let appFiltered = store.items(in: nil, query: marker, kind: nil, bundleID: "com.example.app2", since: nil)
        check("app filter", appFiltered.count == 1, "got \(appFiltered.count)")

        let today = store.items(in: nil, query: marker, kind: nil, bundleID: nil, since: Calendar.current.startOfDay(for: Date()))
        check("date filter keeps today's items", today.count == ItemKind.allCases.count, "got \(today.count)")

        // Pinboard movement.
        if let first = created.first {
            store.setPinboard(first, to: board.id)
            let inBoard = store.items(in: board.id, query: "", kind: nil, bundleID: nil, since: nil)
            check("pinboard contains the moved item", inBoard.count == 1 && inBoard.first?.id == first, "got \(inBoard.count)")
            let stillInClipboard = store.items(in: nil, query: marker, kind: nil, bundleID: nil, since: nil)
            check("item left the clipboard list", stillInClipboard.count == ItemKind.allCases.count - 1, "got \(stillInClipboard.count)")
            store.setPinboard(first, to: nil)
        }

        // Duplicate suppression.
        var duplicate = ClipItem()
        duplicate.kind = .text
        duplicate.title = "\(marker) dup"
        duplicate.checksum = "\(marker)-checksum-0"
        let dedupeResult = store.insert(duplicate)
        check("identical checksum is not stored twice", dedupeResult.inserted == false, "inserted=\(dedupeResult.inserted)")

        // Pasteboard round-trip: rich text must survive copy → read.
        let rich = NSAttributedString(string: "roundtrip", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            var richItem = ClipItem()
            richItem.kind = .text
            richItem.text = "roundtrip"
            richItem.title = "roundtrip"
            richItem.payloads = store.storePayloads(for: richItem.id, captured: [
                (NSPasteboard.PasteboardType.rtf.rawValue, rtf, 0),
                (NSPasteboard.PasteboardType.string.rawValue, Data("roundtrip".utf8), 0),
            ])
            store.insert(richItem)
            created.append(richItem.id)

            Paster.shared.write(items: [richItem], store: store, pasteboard: pb)
            let types = Set((pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
            check("pasteboard keeps rtf flavour", types.contains(NSPasteboard.PasteboardType.rtf.rawValue), "\(types)")
            check("pasteboard keeps plain text flavour", pb.string(forType: .string) == "roundtrip")
        } else {
            check("rtf fixture builds", false)
        }

        // Colour round-trip: capture a live colour pasteboard, store, write back.
        pb.clearContents()
        pb.writeObjects([NSColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)])
        var colourPayloads: [(type: String, data: Data, index: Int)] = []
        for (index, entry) in (pb.pasteboardItems ?? []).enumerated() {
            for type in entry.types {
                if let data = entry.data(forType: type) { colourPayloads.append((type.rawValue, data, index)) }
            }
        }
        var colourItem = ClipItem()
        colourItem.kind = .color
        colourItem.colorHex = "33B366"
        colourItem.title = "#33B366"
        colourItem.payloads = store.storePayloads(for: colourItem.id, captured: colourPayloads)
        store.insert(colourItem)
        created.append(colourItem.id)
        Paster.shared.write(items: [colourItem], store: store, pasteboard: pb)
        let back = (pb.readObjects(forClasses: [NSColor.self]) as? [NSColor])?.first
        check("colour round-trip", back?.usingColorSpace(.sRGB)?.hexString.uppercased() == "33B366",
              String(describing: back?.usingColorSpace(.sRGB)?.hexString))

        // File round-trip.
        let files = ["a.txt", "b.txt"].map { testRoot.appendingPathComponent($0).path }
        for path in files { try? "x".write(toFile: path, atomically: true, encoding: .utf8) }
        let filePB = pb
        filePB.clearContents()
        filePB.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
        var filePayloads: [(type: String, data: Data, index: Int)] = []
        for (index, entry) in (filePB.pasteboardItems ?? []).enumerated() {
            for type in entry.types {
                if let data = entry.data(forType: type) { filePayloads.append((type.rawValue, data, index)) }
            }
        }
        var fileItem = ClipItem()
        fileItem.kind = .files
        fileItem.filePaths = files
        fileItem.title = "2 files"
        fileItem.payloads = store.storePayloads(for: fileItem.id, captured: filePayloads)
        store.insert(fileItem)
        created.append(fileItem.id)
        Paster.shared.write(items: [fileItem], store: store, pasteboard: pb)
        let readFiles = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        check("multiple files round-trip", readFiles.count == files.count, "got \(readFiles.count)")

        // Always exercise images, including in a fresh isolated library.
        let fixtureImage = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        if let data = ClipboardMonitor.pngData(from: fixtureImage) {
            var image = ClipItem()
            image.kind = .image
            image.checksum = marker + "-image"
            image.imageName = store.storeImage(for: image.id, data: data)
            image.payloads = store.storePayloads(for: image.id, captured: [(NSPasteboard.PasteboardType.png.rawValue, data, 0)])
            store.insert(image)
            created.append(image.id)
        }
        // Image round-trip using whatever image the library holds.
        if let imageItem = store.items.first(where: { $0.kind == .image && !$0.payloads.isEmpty }) {
            Paster.shared.write(items: [imageItem], store: store, pasteboard: pb)
            let restored = NSImage(pasteboard: pb)
            check("image round-trip", restored != nil && (restored?.size.width ?? 0) > 0,
                  String(describing: restored?.size))
        }

        // Successful clipboard writes promote history across every paste/copy route.
        let usageItems = (0..<3).map { index -> ClipItem in
            var item = ClipItem()
            item.title = "usage-\(index)"
            item.text = item.title
            item.checksum = "\(marker)-usage-\(index)"
            item.createdAt = Date().addingTimeInterval(Double(-600 - index * 60))
            store.insert(item)
            created.append(item.id)
            return item
        }
        let countBeforeUse = store.totalCount
        _ = Paster.shared.write(items: [usageItems[2]], store: store, pasteboard: pb)
        check("using an older history item promotes the existing entry", store.items.first?.id == usageItems[2].id && store.totalCount == countBeforeUse)
        let beforeDeferredUse = store.items.map(\.id)
        _ = Paster.shared.write(items: [usageItems[0]], store: store, pasteboard: pb, promote: false)
        check("preparing a paste does not move visible history", store.items.map(\.id) == beforeDeferredUse)
        Paster.shared.markUsed([usageItems[0]], store: store)
        check("completing a paste promotes the existing entry once", store.items.first?.id == usageItems[0].id && store.totalCount == countBeforeUse)
        _ = Paster.shared.write(items: [usageItems[1], usageItems[0]], store: store, pasteboard: pb)
        check("batch use preserves the selected order at the front", Array(store.items.prefix(2).map(\.id)) == [usageItems[1].id, usageItems[0].id])
        let orderBeforeFailure = store.items.map(\.id)
        var unusable = usageItems[2]
        unusable.text = nil
        check("failed clipboard write does not change history order", !Paster.shared.write(items: [unusable], store: store, pasteboard: pb) && store.items.map(\.id) == orderBeforeFailure)
        store.save(immediately: true)
        let manifest = (try? Data(contentsOf: Store.root.appendingPathComponent("library.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let savedItems = manifest?["items"] as? [[String: Any]]
        check("recently used order is persisted", savedItems?.prefix(2).compactMap { $0["id"] as? String } == [usageItems[1].id.uuidString, usageItems[0].id.uuidString])
        for item in usageItems.prefix(2) { store.setPinboard(item.id, to: board.id) }
        let boardOrder = store.items(in: board.id, query: "", kind: nil, bundleID: nil, since: nil).map(\.id)
        if let boardItem = store.items.first(where: { $0.id == usageItems[1].id }) {
            _ = Paster.shared.write(items: [boardItem], store: store, pasteboard: pb)
            check("using a Pinboard item keeps its manual order", store.items(in: board.id, query: "", kind: nil, bundleID: nil, since: nil).map(\.id) == boardOrder)
        }
        for item in usageItems { store.setPinboard(item.id, to: nil) }

        // Shared panel state, default keys, reordering and real drag representations.
        let model = MainViewModel(store: store, prefs: .shared)
        model.preparePanel()
        let firstIDs = model.items.map(\.id)
        check("panel initially selects newest item", model.current?.id == firstIDs.first && model.selection.count == 1)
        model.moveSelection(by: 1)
        check("horizontal navigation advances one item", model.current?.id == firstIDs.dropFirst().first)
        let selection = model.selection
        check("missing quick-paste number leaves selection intact", !model.selectQuickItem(999) && model.selection == selection)
        check("quick-paste number addresses ordered results", model.selectQuickItem(0) && model.current?.id == firstIDs.first)
        model.query = "no-such-item-\(marker)"
        model.reconcileSelection()
        check("empty search clears stale selection", model.current == nil && model.selection.isEmpty)
        model.query = ""

        let orderedIDs = Array(created.prefix(3))
        for id in orderedIDs { store.setPinboard(id, to: board.id) }
        if orderedIDs.count == 3 {
            store.reorder(orderedIDs[2], relativeTo: orderedIDs[0])
            let order = store.items(in: board.id, query: "", kind: nil, bundleID: nil, since: nil).map(\.id)
            check("pinboard reorder preserves a complete stable order", order == [orderedIDs[2], orderedIDs[0], orderedIDs[1]])
            store.reorder(orderedIDs[2], relativeTo: orderedIDs[1], after: true)
            check("pinboard reorder can move to the final position", store.items(in: board.id, query: "", kind: nil, bundleID: nil, since: nil).last?.id == orderedIDs[2])
            store.reorder(orderedIDs[2], relativeTo: orderedIDs[0])
            model.selectDestination(.pinboard(board.id))
            check("pinboard tab selects first board item", model.current?.id == orderedIDs[2])
            model.cycleDestination(forward: true)
            check("pinboard cycling includes clipboard history", model.destination == .clipboard)
        }
        for id in orderedIDs { store.setPinboard(id, to: nil) }

        Preferences.shared.resetShortcutDefaults()
        check("shortcut reset uses Carbon command and shift masks",
              KeyCombo.decode(Preferences.shared.activateShortcut)?.modifiers == KeyCombo.command | KeyCombo.shift)
        check("shortcut reset uses valid quick-paste masks",
              KeyCombo.decode(Preferences.shared.quickPasteShortcut)?.modifiers == KeyCombo.command | KeyCombo.control)
        check("shortcut reset uses valid stack masks",
              KeyCombo.decode(Preferences.shared.pasteStackShortcut)?.modifiers == KeyCombo.command | KeyCombo.control | KeyCombo.option)

        // Source colors must describe the whole icon, not just its center or a tiny badge.
        func icon(_ draw: @escaping (NSRect) -> Void) -> NSImage {
            NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                draw(rect)
                return true
            }
        }
        let majority = SourceAppearance.dominantColor(in: icon { rect in
            NSColor.green.setFill(); rect.fill()
            NSColor.blue.setFill(); NSRect(x: 20, y: 20, width: 24, height: 24).fill()
        })
        check("source color follows whole-icon area over center", majority != nil && majority!.greenComponent > majority!.blueComponent)
        let redSeam = SourceAppearance.dominantColor(in: icon { rect in
            NSColor(srgbRed: 0.9, green: 0.05, blue: 0.1, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.05, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 32, height: 64).fill()
        })
        check("source color joins red across hue boundary", redSeam != nil && redSeam!.redComponent > 0.7 && redSeam!.greenComponent < 0.2 && redSeam!.blueComponent < 0.2)
        let monochrome = SourceAppearance.dominantColor(in: icon { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); NSRect(x: 16, y: 16, width: 32, height: 32).fill()
        })
        check("monochrome source keeps a neutral header", monochrome != nil && SourceAppearance.readableHeader(monochrome!).saturationComponent < 0.02)
        let noise = SourceAppearance.dominantColor(in: icon { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        })
        check("tiny colored badge does not tint monochrome source", noise != nil && noise!.saturationComponent < 0.02)
        check("empty transparent icon has no representative color", SourceAppearance.dominantColor(in: icon { _ in }) == nil)
        let transparent = SourceAppearance.dominantColor(in: icon { _ in
            NSColor.red.setFill(); NSRect(x: 24, y: 24, width: 16, height: 16).fill()
        })
        check("transparent margins do not dilute source color", transparent != nil && transparent!.redComponent > 0.9 && transparent!.greenComponent < 0.1)
        let colors = ItemKind.allCases.map(\.accent) + (0..<36).flatMap { hue in
            [CGFloat(0), 0.25, 0.6, 1].map {
                NSColor(calibratedHue: CGFloat(hue) / 36, saturation: $0, brightness: 0.8, alpha: 1)
            }
        }
        let readable = colors.allSatisfy { source in
            let color = SourceAppearance.readableHeader(source)
            return (SourceAppearance.luminance(color) + 0.05) / (SourceAppearance.luminance(SourceAppearance.headerInk) + 0.05) >= 4.5
        }
        check("bright source header text meets 4.5 contrast", readable)

        if let textID = created.first {
            let edited = "已编辑的中文文本 ✓"
            check("text editing saves a real clipboard payload", store.updateText(textID, text: edited))
            if let item = store.items.first(where: { $0.id == textID }) {
                check("edited text is immediately searchable", store.items(in: nil, query: edited, kind: nil, bundleID: nil, since: nil).contains(where: { $0.id == textID }))
                let provider = Paster.shared.itemProvider(for: item)
                var exported: String?
                provider.loadDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.string.rawValue) { data, _ in
                    DispatchQueue.main.async { exported = data.flatMap { String(data: $0, encoding: .utf8) } }
                }
                let deadline = Date().addingTimeInterval(2)
                while exported == nil && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
                check("external drag exports content rather than UUID", exported == edited)
                check("internal drag has a separate private identifier", provider.hasItemConformingToTypeIdentifier(Paster.itemIdentifier))
            }
        }

        pb.clearContents()
        pb.setString("keep-this", forType: .string)
        var missing = ClipItem()
        missing.kind = .unknown
        check("unavailable payload does not erase clipboard", !Paster.shared.write(items: [missing], store: store, pasteboard: pb) && pb.string(forType: .string) == "keep-this")
        let screen = NSRect(x: -1920, y: 120, width: 1920, height: 1000)
        let frame = TroveWindows.clipboardPanelFrame(in: screen)
        check("panel geometry respects secondary-screen origin", frame.minX == -1912 && frame.minY == 128 && frame.width == 1904 && frame.height == 332 && screen.contains(frame))

        // Cleanup.
        store.delete(ids: Set(created))
        store.deletePinboard(board.id)
        let leftovers = store.items(in: nil, query: marker, kind: nil, bundleID: nil, since: nil)
        check("cleanup removed test items", leftovers.isEmpty, "left \(leftovers.count)")

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }

    // MARK: Native panel regression

    static func copyPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        var backup: [NSPasteboardItem] = []
        for original in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type) else { return nil }
                copy.setData(data, forType: type)
            }
            backup.append(copy)
        }
        return backup
    }

    static func checkPanel(to directory: URL) -> Int32 {
        let clipboard = NSPasteboard.general
        guard let backup = copyPasteboard(clipboard) else {
            print("FAIL cannot preserve an original clipboard representation")
            return 2
        }
        var ownedChange: Int?
        defer {
            if clipboard.changeCount == ownedChange {
                clipboard.clearContents()
                if !backup.isEmpty { clipboard.writeObjects(backup) }
            }
        }
        let menuDelegate = AppDelegate()
        menuDelegate.installMenus()
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }
        func pump(_ seconds: TimeInterval = 0.25) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        let store = Store.shared
        let prefs = Preferences.shared
        prefs.generateLinkPreviews = false
        prefs.pasteToActiveApp = false
        prefs.soundEffects = false
        let board = store.createPinboard(name: "常用片段", colorHex: "4C8BF5")
        var fixtureIDs: [UUID] = []
        for (index, text) in ["第一张卡片：原生剪贴板面板", "第二张卡片：中文输入与快捷选择", "第三张卡片：内容可以直接拖到其他应用"].enumerated() {
            var item = ClipItem()
            item.title = text
            item.text = text
            item.searchText = text
            item.checksum = "panel-fixture-\(index)"
            item.sourceBundleID = index == 1 ? "com.apple.TextEdit" : "com.apple.Safari"
            item.sourceName = index == 1 ? "文本编辑" : "Safari"
            item.createdAt = Date().addingTimeInterval(Double(-index * 60))
            item.payloads = store.storePayloads(for: item.id, captured: [
                (NSPasteboard.PasteboardType.string.rawValue, Data(text.utf8), 0),
                ("org.nspasteboard.TransientType", Data(), 0)
            ])
            store.insert(item)
            fixtureIDs.append(item.id)
        }
        let windows = TroveWindows.shared
        let model = TroveApp.shared.mainModel
        windows.showQuickPaste()
        pump(0.4)
        guard let panel = windows.quickPanel else { print("FAIL panel was not created"); return 1 }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: KeyCodeNames.name(for: UInt32(code)).lowercased(),
                             charactersIgnoringModifiers: KeyCodeNames.name(for: UInt32(code)).lowercased(), isARepeat: false, keyCode: code)!
        }
        check("native panel is visible without a title bar",
              panel.isVisible && panel.styleMask.contains(.nonactivatingPanel) && !panel.styleMask.contains(.titled))
        check("primary entry does not create the manager", windows.mainWindow == nil)
        if let screen = panel.screen {
            check("native panel is anchored to full screen bottom", panel.frame == TroveWindows.clipboardPanelFrame(in: screen.frame))
        } else { check("native panel has a display", false) }
        check("native panel stays above the Dock", panel.level.rawValue > CGWindowLevelForKey(.dockWindow))
        check("native search field owns keyboard input", panel.firstResponder is NSTextView)
        func searchField(in view: NSView?) -> NSSearchField? {
            guard let view else { return nil }
            return (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        func clickSearchIcon(_ field: NSSearchField) {
            let icon = (field.cell as? NSSearchFieldCell)?.searchButtonRect(forBounds: field.bounds) ?? field.bounds
            let point = field.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil)
            if let hit = panel.contentView?.hitTest(point) { print("INFO search click hit: \(type(of: hit))") }
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                        timestamp: down.timestamp + 0.01, windowNumber: panel.windowNumber,
                                        context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            // Native text/cell tracking may synchronously wait for mouse-up.
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let queuedUp = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(queuedUp)
            }
        }
        if let field = searchField(in: panel.contentView) {
            let editor = field.currentEditor()
            clickSearchIcon(field)
            pump()
            check("first mouse click on search icon expands the field", model.isSearching && field.frame.width > 300)
            check("search click immediately focuses the existing editor", editor != nil && field.currentEditor() === editor && editor === panel.firstResponder)
            let textPoint = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            check("expanded search retains native text hit testing", panel.contentView?.hitTest(textPoint) is NSTextView)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            capture(panel, to: directory.appendingPathComponent("search-expanded.png"))
            model.preparePanel()
            pump()
        } else { check("search icon has a native field", false) }
        if let editor = panel.firstResponder as? NSTextView {
            editor.insertText("TROVE_UI_AUDIT", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            pump()
            check("native input retains punctuation", model.query == "TROVE_UI_AUDIT")
            let all = NSApp.mainMenu?.performKeyEquivalent(with: key(0, flags: .command)) ?? false
            check("native Edit menu selects the full search query", all && editor.selectedRange().length == editor.string.utf16.count)
            // A modifier-driven render must not replace an edit that has not reached its control notification yet.
            editor.string = "TROVE_UI_AUDIT_"
            model.showNumberHints.toggle()
            pump()
            check("state refresh does not overwrite an in-flight native edit", editor.string == "TROVE_UI_AUDIT_")
            model.query = ""
            model.isSearching = false
            model.preparePanel()
            pump()
        }
        _ = windows.handlePanelEvent(key(124))
        check("Right selects the next horizontal card", model.current?.id == fixtureIDs[1])
        _ = windows.handlePanelEvent(key(123))
        check("Left returns to previous card", model.current?.id == fixtureIDs[0])
        _ = windows.handlePanelEvent(key(124, flags: .command))
        check("Command Right switches to a pinboard", model.destination == .pinboard(board.id))
        _ = windows.handlePanelEvent(key(123, flags: .command))
        check("Command Left includes clipboard history", model.destination == .clipboard)

        _ = windows.handlePanelEvent(key(3, flags: .command))
        check("Command F expands the existing search field", model.isSearching)
        model.query = "第二张"
        pump()
        check("query filters cards and updates selection", model.items.count == 1 && model.current?.id == fixtureIDs[1])
        check("search editing retains Command Right text navigation", !windows.handlePanelEvent(key(124, flags: .command)))
        if let editor = panel.firstResponder as? NSTextView {
            editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            let selection = model.selection
            check("IME composition keeps its arrow key", !windows.handlePanelEvent(key(124)) && model.selection == selection)
            check("IME composition keeps Escape", !windows.handlePanelEvent(key(53)))
            editor.unmarkText()
        } else { check("native field editor remains available", false) }
        model.query = "第二张"
        _ = windows.handlePanelEvent(key(53))
        check("first Escape clears the query", model.query.isEmpty && model.isSearching && panel.isVisible)
        _ = windows.handlePanelEvent(key(53))
        check("second Escape collapses search", !model.isSearching && panel.isVisible)
        pump()
        _ = model.selectQuickItem(0)
        _ = windows.handlePanelEvent(key(49))
        pump(0.4)
        check("Space opens the selected attached preview", model.previewID == fixtureIDs[0] && NSApp.windows.contains(where: { $0 !== panel && $0.isVisible }))
        _ = windows.handlePanelEvent(key(53))
        pump()
        check("Escape closes preview while retaining panel", model.previewID == nil && panel.isVisible)
        _ = windows.handlePanelEvent(key(53))
        pump()
        check("Escape dismisses browsing panel", !panel.isVisible)
        windows.showQuickPaste()
        pump()
        check("reopening cancels stale dismissals", panel.isVisible && panel.alphaValue == 1)
        let pasteboard = NSPasteboard.withUniqueName()
        if let older = store.items.first(where: { $0.id == fixtureIDs[2] }) {
            model.selection = [older.id]
            _ = Paster.shared.write(items: [older], store: store, pasteboard: pasteboard)
            pump()
            check("using an older card promotes it without changing selection", model.items.first?.id == older.id && model.current?.id == older.id)
            windows.closeQuickPaste(restoreTarget: false)
            pump()
            windows.showQuickPaste()
            pump()
            check("reopened panel starts with the recently used card", model.items.first?.id == older.id && model.current?.id == older.id)
        }
        pasteboard.releaseGlobally()
        if let field = searchField(in: panel.contentView) {
            clickSearchIcon(field)
            pump()
            check("first search click works again after reopening the panel", model.isSearching && field.frame.width > 300)
        } else { check("reopened panel retains its native search field", false) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture(panel, to: directory.appendingPathComponent("panel-native.png"))
        let geometry: [String: Any] = ["frame": NSStringFromRect(panel.frame), "keyWindow": panel.isKeyWindow,
                                       "screenFrame": NSStringFromRect(panel.screen?.frame ?? .zero),
                                       "visibleFrame": NSStringFromRect(panel.screen?.visibleFrame ?? .zero),
                                       "windowLevel": panel.level.rawValue, "dockWindowLevel": CGWindowLevelForKey(.dockWindow),
                                       "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                                       "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("panel-check.json"))
        }
        if let older = store.items.first(where: { $0.id == fixtureIDs[0] }) {
            model.selection = [older.id]
            let order = store.items.map(\.id)
            windows.commitSelection(copyOnly: true)
            ownedChange = clipboard.changeCount
            check("commit starts closing without moving the visible card", panel.isVisible && store.items.map(\.id) == order)
            pump()
            check("commit promotes history only after the panel is hidden", !panel.isVisible && store.items.first?.id == older.id)
            windows.showQuickPaste()
            pump()
            check("next invocation selects the item from the completed commit", model.current?.id == older.id)
        }
        var didClose: Bool?
        windows.closeQuickPaste(restoreTarget: false) { didClose = $0 }
        windows.showQuickPaste()
        pump()
        check("reopening cancels the pending close completion", didClose == false && panel.isVisible)
        let shortcut = prefs.activateShortcut
        windows.showOnboarding()
        pump()
        let guide = windows.onboardingWindow
        check("onboarding has its own visible native window", guide?.isVisible == true && guide?.contentView?.bounds.width == OnboardingView.size.width && (guide?.contentView?.bounds.height ?? 0) >= OnboardingView.size.height)
        windows.showOnboarding()
        check("reopening onboarding reuses its existing window", windows.onboardingWindow === guide)
        check("opening onboarding preserves existing preferences", prefs.activateShortcut == shortcut && !prefs.pasteToActiveApp)
        guide?.performClose(nil)
        pump()
        check("closing onboarding completes it and opens clipboard", prefs.hasCompletedOnboarding && windows.onboardingWindow == nil && panel.isVisible)
        windows.hideAll()
        print(failures == 0 ? "PANEL CHECK OK" : "PANEL CHECK FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }

    static func capture(_ window: NSWindow, to url: URL) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    // MARK: Global hot keys

    static func checkHotKeys() -> Int32 {
        var failures = 0
        let report = HotKeyCenter.shared.applyAndReport(from: Preferences.shared)
        for (action, combo, ok) in report {
            let name = String(describing: action)
            if ok {
                print("PASS  hot key \(name) → \(combo)")
            } else {
                failures += 1
                print("FAIL  hot key \(name) → \(combo) (rejected)")
            }
        }
        HotKeyCenter.shared.unregisterAll()
        print(failures == 0 ? "HOTKEYS OK" : "HOTKEY FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }

    // MARK: Offscreen UI rendering

    static func renderPreviews(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = Store.shared
        let prefs = Preferences.shared

        var samples: [ClipItem] = []

        var text = ClipItem()
        text.kind = .text
        text.title = "Deploy notes"
        text.text = """
        Ship the 4.2 release after the parity check passes.
        • verify clipboard round-trip
        • confirm OCR latency under 300ms
        • publish changelog
        """
        text.sourceBundleID = "com.apple.Safari"
        text.sourceName = "Safari"
        text.createdAt = Date().addingTimeInterval(-120)
        samples.append(text)

        var link = ClipItem()
        link.kind = .link
        link.title = "Human Interface Guidelines"
        link.urlString = "https://developer.apple.com/design/human-interface-guidelines/"
        link.sourceName = "Safari"
        link.sourceBundleID = "com.apple.Safari"
        link.createdAt = Date().addingTimeInterval(-900)
        samples.append(link)

        var color = ClipItem()
        color.kind = .color
        color.colorHex = "1F8C6B"
        color.title = "#1F8C6B"
        color.createdAt = Date().addingTimeInterval(-3700)
        samples.append(color)

        var files = ClipItem()
        files.kind = .files
        files.title = "Design tokens"
        files.filePaths = ["/System/Library/CoreServices/Finder.app", "/System/Library/CoreServices/Dock.app", "/System/Library/CoreServices/ScreenSaverEngine.app"]
        files.createdAt = Date().addingTimeInterval(-7200)
        samples.append(files)

        var pinned = text
        pinned.id = UUID()
        pinned.pinned = true
        pinned.title = "Pinned snippet"
        samples.append(pinned)

        // Real captured image, when one exists.
        if let imageItem = store.items.first(where: { $0.kind == .image }) {
            samples.insert(imageItem, at: 1)
        }

        // Cards
        for (index, item) in samples.enumerated() {
            render(
                AnyView(ItemCard(item: item, isSelected: index == 0)),
                size: CGSize(width: 232, height: 232),
                to: dir.appendingPathComponent("card-\(index)-\(item.kind.title.lowercased()).png")
            )
        }

        // Composite screens
        let mainModel = MainViewModel(store: store, prefs: prefs)
        render(
            AnyView(MainWindowView(store: store, prefs: prefs, model: mainModel)),
            size: CGSize(width: 1040, height: 660),
            to: dir.appendingPathComponent("window-main.png")
        )

        let quickModel = MainViewModel(store: store, prefs: prefs)
        quickModel.preparePanel()
        render(
            AnyView(QuickPasteView(model: quickModel, store: store, prefs: prefs)),
            size: CGSize(width: 1200, height: 332),
            to: dir.appendingPathComponent("window-quickpaste.png")
        )

        render(
            AnyView(SettingsView(prefs: prefs, store: store)),
            size: CGSize(width: 680, height: 540),
            to: dir.appendingPathComponent("window-settings.png")
        )

        render(
            AnyView(OnboardingView(prefs: prefs, finish: {})),
            size: CGSize(width: 560, height: 480),
            to: dir.appendingPathComponent("window-onboarding.png")
        )

        let stack = PasteStackModel(store: store)
        render(
            AnyView(PasteStackView(model: stack, store: store, close: {})),
            size: CGSize(width: 480, height: 380),
            to: dir.appendingPathComponent("window-stack.png")
        )

        print("rendered previews to \(dir.path)")
    }

    // MARK: Real window snapshots

    /// Renders a real NSWindow (AppKit + SwiftUI) into a PNG. Unlike
    /// `ImageRenderer` this keeps controls, materials and scrolling containers
    /// intact, and needs no screen-recording permission because the drawing is
    /// done in-process.
    static func snapshot(named name: String, to url: URL) {
        let store = Store.shared
        let prefs = Preferences.shared

        let view: AnyView
        var size = CGSize(width: 1040, height: 660)

        switch name {
        case "main", "main-ready", "main-downloading":
            if name == "main-ready" { UpdateChecker.shared.showReady(toInstallAndRelaunch: { _ in }) }
            if name == "main-downloading" { UpdateChecker.shared.showDownloadInitiated(cancellation: {}) }
            view = AnyView(MainWindowView(store: store, prefs: prefs, model: MainViewModel(store: store, prefs: prefs)))
        case "quick", "quick-search":
            size = CGSize(width: 1200, height: 332)
            let model = MainViewModel(store: store, prefs: prefs)
            model.preparePanel()
            if name == "quick-search" { model.isSearching = true }
            view = AnyView(QuickPasteView(model: model, store: store, prefs: prefs))
        case "settings":
            size = CGSize(width: 680, height: 540)
            view = AnyView(SettingsView(prefs: prefs, store: store))
        case "about":
            size = CGSize(width: 680, height: 540)
            view = AnyView(SettingsView(prefs: prefs, store: store, initialTab: .about))
        case "update", "update-downloading", "update-ready", "update-error":
            size = CGSize(width: 440, height: 420)
            if name == "update-downloading" {
                UpdateChecker.shared.showDownloadInitiated(cancellation: {})
                UpdateChecker.shared.showDownloadDidReceiveExpectedContentLength(8_000_000)
                UpdateChecker.shared.showDownloadDidReceiveData(ofLength: 3_000_000)
            } else if name == "update-ready" {
                UpdateChecker.shared.showReady(toInstallAndRelaunch: { _ in })
            } else if name == "update-error" {
                UpdateChecker.shared.showUpdaterError(URLError(.notConnectedToInternet), acknowledgement: {})
            }
            view = AnyView(UpdatePrompt(updates: .shared, close: {}))
        case "onboarding", "onboarding-keys", "onboarding-privacy":
            size = OnboardingView.size
            let step: OnboardingView.Step = name == "onboarding-keys" ? .shortcuts : (name == "onboarding-privacy" ? .privacy : .welcome)
            view = AnyView(OnboardingView(prefs: prefs, initialStep: step, finish: {}))
        case "stack":
            size = CGSize(width: 480, height: 380)
            view = AnyView(PasteStackView(model: PasteStackModel(store: store), store: store, close: {}))
        default:
            print("unknown snapshot: \(name)")
            return
        }

        let rect = NSRect(origin: NSPoint(x: 40, y: 40), size: size)
        let window: NSWindow = ["quick", "quick-search"].contains(name)
            ? QuickPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)

        // Let SwiftUI lay out and the run loop deliver the first display pass.
        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("snapshot: no bitmap rep")
            return
        }
        content.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("snapshot \(name) → \(url.path)")
        } else {
            print("snapshot: encoding failed")
        }
        window.orderOut(nil)
    }

    private static func render(_ view: AnyView, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            print("render failed: \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
