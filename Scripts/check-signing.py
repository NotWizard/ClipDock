#!/usr/bin/env python3
"""Verify stable identity across different binaries without changing TCC or installed apps."""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIGNER = ROOT / 'Scripts/sign-app.py'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path, nargs='?', default=ROOT / 'build/signing-check')
parser.add_argument('--check-permissions', action='store_true',
                    help='After manually authorizing the stable ClipDock identity, verify it for two different binaries.')
args = parser.parse_args()
OUTPUT = args.output.resolve()
OUTPUT.mkdir(parents=True, exist_ok=True)


def run(args, ok=True, env=None):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, env=env)
    if ok and result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result


def signature(app, flag):
    result = run(['codesign', '-d', flag, app])
    return result.stdout + result.stderr


results = []


def check(name, condition):
    assert condition, name
    results.append({'case': name, 'passed': True})
    print('PASS  ' + name, flush=True)


with tempfile.TemporaryDirectory(prefix='ClipDock-signing-check-') as directory:
    work = Path(directory)
    identifier = 'app.trove.clipboard' if args.check_permissions else 'app.trove.signing-test.' + uuid.uuid4().hex
    apps = []
    for version in [1, 2]:
        app = work / (str(version) + '/Probe.app')
        binary = app / 'Contents/MacOS/Probe'
        binary.parent.mkdir(parents=True)
        resources = app / 'Contents/Resources'
        resources.mkdir()
        (resources / 'note.txt').write_text('original resource')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Probe',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version),
        }))
        source = work / 'probe.c'
        source.write_text('''#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
int main(void) {
    printf("{\\\"probe\\\":%d,\\\"accessibility\\\":%s,\\\"postEvents\\\":%s}\\n", VERSION,
        AXIsProcessTrusted() ? "true" : "false", CGPreflightPostEventAccess() ? "true" : "false");
    return 0;
}
''')
        run(['clang', source, '-DVERSION=' + str(version), '-framework', 'ApplicationServices', '-o', binary])
        run([sys.executable, SIGNER, app, '--require-stable'])
        apps.append(app)
    old, new = apps
    requirement = re.search(r'designated => (.+)', signature(old, '-r-'))[1]
    check('different executables have different code hashes',
          re.search(r'\nCDHash=(\w+)', signature(old, '--verbose=4'))[1] !=
          re.search(r'\nCDHash=(\w+)', signature(new, '--verbose=4'))[1])
    check('both versions keep the same certificate-bound requirement',
          requirement == re.search(r'designated => (.+)', signature(new, '-r-'))[1] and
          'certificate leaf = H"' in requirement and 'cdhash' not in requirement)
    check('new binary satisfies the old identity requirement',
          run(['codesign', '--verify', '--strict', '-R', '=' + requirement, new], ok=False).returncode == 0)
    if args.check_permissions:
        receipts = []
        for index, app in enumerate(apps):
            output = OUTPUT / f'permission-{index + 1}.json'
            output.unlink(missing_ok=True)
            # LaunchServices gives each app its own TCC identity; a shell child
            # can inherit the terminal/agent's permissions and give a false pass.
            run(['open', '-n', '-g', '--stdout', output, '--stderr', OUTPUT / f'permission-{index + 1}.log', app])
            deadline = time.monotonic() + 10
            while True:
                try:
                    receipts.append(json.loads(output.read_text()))
                    break
                except (OSError, json.JSONDecodeError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Permission probe did not finish')
                    time.sleep(0.05)
        (OUTPUT / 'permissions.json').write_text(json.dumps(receipts, indent=2) + '\n')
        check('first binary retains granted Accessibility and event permissions',
              receipts[0]['accessibility'] and receipts[0]['postEvents'])
        check('different binary retains the same permissions without another prompt',
              receipts[1]['accessibility'] and receipts[1]['postEvents'])
    impostor = work / 'impostor/Probe.app'
    shutil.copytree(new, impostor)
    run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none', impostor])
    check('ad-hoc copy with the same bundle identifier is rejected',
          run(['codesign', '--verify', '-R', '=' + requirement, impostor], ok=False).returncode != 0)
    info_path = new / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] += '.other'
    info_path.write_bytes(plistlib.dumps(info))
    run([sys.executable, SIGNER, new, '--require-stable'])
    check('same certificate with a different bundle identifier is rejected',
          run(['codesign', '--verify', '-R', '=' + requirement, new], ok=False).returncode != 0)
    (old / 'Contents/Resources/note.txt').write_text('tampered resource')
    check('modified signed resource is rejected',
          run(['codesign', '--verify', '--strict', old], ok=False).returncode != 0)
    environment = dict(os.environ, CLIPDOCK_SIGNING_DIR=str(work / 'missing-identity'))
    check('release signing fails instead of falling back to ad-hoc',
          run([sys.executable, SIGNER, new, '--require-stable'], ok=False, env=environment).returncode != 0)
    check('initialization cannot replace the established signing identity',
          run([sys.executable, SIGNER, '--init'], ok=False).returncode != 0)

(OUTPUT / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('SIGNING CHECK OK')
