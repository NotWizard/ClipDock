#!/usr/bin/env python3
"""Verify a real Cmd-V into a disposable native receiver; preserve the user's clipboard."""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'build/ClipDock.app'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path, nargs='?', default=ROOT / 'build/paste-check')
parser.add_argument('--queue', action='store_true', help='Exercise the actual paste queue instead of a panel selection.')
args = parser.parse_args()
OUTPUT = args.output.resolve()
OUTPUT.mkdir(parents=True, exist_ok=True)
WORK = Path(tempfile.mkdtemp(prefix='ClipDock-paste-receiver-'))
app = WORK / 'Receiver.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True)
source = WORK / 'Receiver.swift'
source.write_text(r'''
import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
final class ReceiverText: NSTextView {
    var count = 0
    override func paste(_ sender: Any?) {
        super.paste(sender)
        count += 1
        let receipt: [String: Any] = ["text": string, "count": count, "caret": selectedRange().location]
        try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("received.json"), options: .atomic)
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(); root.addItem(appItem)
        let edit = NSMenu()
        let item = NSMenuItem(); item.submenu = edit; root.addItem(item)
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        NSApp.mainMenu = root
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClipDock synthetic paste receiver"
        let text = ReceiverText(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        text.string = "left--right"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        window.contentView = text
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            try! Data("ready".utf8).write(to: output.appendingPathComponent("ready"))
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
''')
info = {'CFBundleIdentifier': 'app.trove.paste-test.' + uuid.uuid4().hex,
        'CFBundleExecutable': 'Receiver', 'CFBundleName': 'Paste Test Receiver', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc', str(source), '-framework', 'AppKit', '-o', str(macos / 'Receiver')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
for name in ['ready', 'received.json']:
    (OUTPUT / name).unlink(missing_ok=True)
receiver = None
try:
    with (OUTPUT / 'receiver.log').open('w') as log:
        receiver = subprocess.Popen([str(macos / 'Receiver'), str(OUTPUT)], stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 10
    while not (OUTPUT / 'ready').exists():
        if receiver.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Disposable receiver did not become ready')
        time.sleep(0.05)
    paste_log = OUTPUT / 'paste.log'
    paste_log.unlink(missing_ok=True)
    # Test the app's own permissions, not permissions inherited from the shell.
    subprocess.run(['open', '-n', '-g', '--stdout', str(paste_log), '--stderr', str(OUTPUT / 'host.log'),
                    str(APP), '--args', '--check-paste', str(receiver.pid), str(OUTPUT)] + (['--queue'] if args.queue else []), check=True)
    deadline = time.monotonic() + 20
    while True:
        report = paste_log.read_text() if paste_log.exists() else ''
        if 'PASTE CHECK OK' in report or 'FAIL' in report or time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    print(report)
    if 'PASTE CHECK OK' not in report:
        raise RuntimeError('Paste check failed; see ' + str(OUTPUT))
    receipt = json.loads((OUTPUT / 'received.json').read_text())
    assert receipt == {'text': 'left-CLIPDOCK_CARET_TEST-right', 'count': 1, 'caret': 24}, receipt
    (OUTPUT / 'results.json').write_text(json.dumps({'passed': True, 'receipt': receipt}, indent=2) + '\n')
finally:
    if receiver is not None and receiver.poll() is None:
        receiver.terminate()
        receiver.wait(timeout=5)
    shutil.rmtree(WORK)
