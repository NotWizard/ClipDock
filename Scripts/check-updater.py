#!/usr/bin/env python3
"""Exercise Sparkle against signed, disposable bundles; never update /Applications."""
import functools
import hashlib
import http.server
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "build/ClipDock.app"
TOOLS = REPO / ".build/artifacts/sparkle/Sparkle/bin"
OUTPUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REPO / "build/updater-check"
OUTPUT.mkdir(parents=True, exist_ok=True)
WORK = Path(tempfile.mkdtemp(prefix="ClipDock-updater-e2e-"))
SERVE = WORK / "serve"
SERVE.mkdir()
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


def run(args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout


def write_info(app, info, ad_hoc=False):
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    if ad_hoc:
        run(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", app])
    else:
        run([sys.executable, REPO / "Scripts/sign-app.py", app, "--require-stable"])


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def copyfile(self, source, output):
        if not self.path.endswith("cancel-download.zip"):
            return super().copyfile(source, output)
        try:
            while chunk := source.read(32768):
                output.write(chunk)
                output.flush()
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass


key = WORK / "fixture-private-key"
keygen = subprocess.run(["swift", "-", str(key)], input="""
import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let file = CommandLine.arguments[1]
guard FileManager.default.createFile(atPath: file,
    contents: Data(key.rawRepresentation.base64EncodedString().utf8),
    attributes: [.posixPermissions: 0o600]) else { fatalError("Cannot save disposable key") }
print(key.publicKey.rawRepresentation.base64EncodedString())
""", check=True, capture_output=True, text=True)
public_key = keygen.stdout.strip()
info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
build = int(info["CFBundleVersion"])
assert build > 1
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(SERVE)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base_url = "http://127.0.0.1:" + str(server.server_port)
results = []
old_process = None

try:
    for case in ["tampered-feed", "tampered-archive", "cancel-download", "valid-update", "ad-hoc-transition"]:
        identifier = "app.trove.updater-test." + uuid.uuid4().hex
        case_dir = WORK / case
        old = case_dir / "old/ClipDock.app"
        new = case_dir / "new/ClipDock.app"
        probe = case_dir / ("probe-" + uuid.uuid4().hex)
        for app in [old, new]:
            run(["ditto", APP, app])
            data = dict(info, CFBundleIdentifier=identifier, SUPublicEDKey=public_key)
            if case in ["valid-update", "ad-hoc-transition"]:
                data["ClipDockUpdaterProbeDirectory"] = str(probe)
                data["ClipDockUpdaterProbeExitVersion"] = str(build)
            if app == old:
                data["CFBundleVersion"] = str(build - 1)
                data["CFBundleShortVersionString"] = "1.2.2"
            write_info(app, data, ad_hoc=case == "ad-hoc-transition" and app == old)
        old_requirement = run(["codesign", "-d", "-r-", old]).strip()
        new_requirement = run(["codesign", "-d", "-r-", new]).strip()
        if case == "ad-hoc-transition":
            assert "cdhash" in old_requirement and "certificate leaf" in new_requirement
        else:
            assert old_requirement == new_requirement
        archive = SERVE / (case + ".zip")
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", new, archive])
        signature = run([TOOLS / "sign_update", "--ed-key-file", key, "-p", archive]).strip()
        rss = ET.Element("rss", version="2.0")
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Disposable ClipDock updater check"
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = "ClipDock " + version
        ET.SubElement(item, "{" + NS + "}version").text = str(build)
        ET.SubElement(item, "{" + NS + "}shortVersionString").text = version
        ET.SubElement(item, "{" + NS + "}minimumSystemVersion").text = "14.0"
        ET.SubElement(item, "enclosure", {
            "url": base_url + "/" + archive.name,
            "length": str(archive.stat().st_size), "type": "application/octet-stream",
            "{" + NS + "}edSignature": signature,
        })
        feed = SERVE / (case + ".xml")
        ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
        run([TOOLS / "sign_update", "--ed-key-file", key, feed])
        if case == "tampered-feed":
            feed.write_bytes(feed.read_bytes().replace(b"Disposable ClipDock updater check", b"Tampered ClipDock updater check"))
        elif case == "tampered-archive":
            damaged = bytearray(archive.read_bytes())
            damaged[len(damaged) // 2] ^= 1
            archive.write_bytes(damaged)
        command = [APP / "Contents/MacOS/Trove", "--check-installer", old, base_url + "/" + feed.name, new / "Contents/MacOS/Trove"]
        if case.startswith("tampered-"):
            command.append("--expect-rejection")
        elif case == "cancel-download":
            command.append("--cancel-download")
        old_process = None
        if case in ["valid-update", "ad-hoc-transition"]:
            with (OUTPUT / (case + "-relaunch-probe.log")).open("w") as log:
                old_process = subprocess.Popen([str(old / "Contents/MacOS/Trove")], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 15
            while not (probe / ("probe-" + str(build - 1) + ".json")).exists():
                if time.monotonic() > deadline or old_process.poll() is not None:
                    raise RuntimeError("Disposable old app did not launch; see " + case + "-relaunch-probe.log")
                time.sleep(0.05)
        with (OUTPUT / (case + ".log")).open("w") as log:
            result = subprocess.run([str(x) for x in command], stdout=log, stderr=subprocess.STDOUT, timeout=110)
        if result.returncode != 0:
            raise RuntimeError(case + " failed; see " + str(OUTPUT / (case + ".log")))
        run(["codesign", "--verify", "--deep", "--strict", old])
        if case in ["valid-update", "ad-hoc-transition"]:
            assert digest(old / "Contents/MacOS/Trove") == digest(new / "Contents/MacOS/Trove")
            assert (old / "Contents/Info.plist").read_bytes() == (new / "Contents/Info.plist").read_bytes()
            after_path = probe / ("probe-" + str(build) + ".json")
            deadline = time.monotonic() + 20
            while not after_path.exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("Updated app was not relaunched")
                time.sleep(0.05)
            before = json.loads((probe / ("probe-" + str(build - 1) + ".json")).read_text())
            after = json.loads(after_path.read_text())
            assert before["pid"] != after["pid"] and old_process.wait(timeout=10) == 0
            assert all(before[k] == after[k] for k in ["items", "pinboards", "historyLimit", "shortcut"])
            (OUTPUT / (case + "-preservation.json")).write_text(json.dumps({"before": before, "after": after}, indent=2) + "\n")
        results.append({"case": case, "passed": True, "oldRequirement": old_requirement, "newRequirement": new_requirement})
        print("PASS  " + case, flush=True)
    (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
except Exception:
    if old_process is not None and old_process.poll() is None:
        old_process.terminate()
        old_process.wait(timeout=10)
    print("Disposable failure evidence retained at " + str(WORK), file=sys.stderr)
    raise
else:
    shutil.rmtree(WORK)
finally:
    server.shutdown()
