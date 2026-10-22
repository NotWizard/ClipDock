#!/usr/bin/env python3
"""Reuse ClipDock's private signing identity; pin its public certificate in source."""
import argparse
import hashlib
import os
import plistlib
import re
import secrets
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CERTIFICATE = ROOT / 'Resources/Signing/ClipDock.cer'
PRIVATE = Path(os.environ.get('CLIPDOCK_SIGNING_DIR',
    str(Path.home() / 'Library/Application Support/ClipDock Release Signing'))).resolve()
KEYCHAIN = PRIVATE / 'app-signing.keychain-db'
PASSWORD = PRIVATE / 'app-signing-password'
BACKUP = PRIVATE / 'app-signing-identity.p12'


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        message = result.stderr
        if PASSWORD.exists():
            message = message.replace(PASSWORD.read_text().strip(), '[redacted]')
        raise SystemExit(Path(args[0]).name + ' failed: ' + message.strip())
    return result.stdout + result.stderr


def initialize():
    if PRIVATE.is_relative_to(ROOT):
        raise SystemExit('Signing secrets must be stored outside the repository.')
    if any(p.exists() for p in [CERTIFICATE, KEYCHAIN, PASSWORD, BACKUP]):
        raise SystemExit('Signing identity already exists. Restore its backup; do not regenerate it for updates.')
    os.umask(0o077)
    PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    password = secrets.token_hex(32)
    with PASSWORD.open('x') as file:
        file.write(password + '\n')
    with tempfile.TemporaryDirectory(prefix='ClipDock-signing-init-') as directory:
        work = Path(directory)
        config = work / 'certificate.cnf'
        config.write_text('''[req]
prompt=no
distinguished_name=dn
x509_extensions=signing
[dn]
CN=ClipDock Local Code Signing
[signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
''')
        run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '7300',
             '-nodes', '-config', config, '-keyout', work / 'key.pem', '-out', work / 'cert.pem'])
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', work / 'key.pem', '-in', work / 'cert.pem',
             '-out', BACKUP, '-passout', 'file:' + str(PASSWORD)])
        run(['security', 'create-keychain', '-p', password, KEYCHAIN])
        run(['security', 'set-keychain-settings', '-lut', '7200', KEYCHAIN])
        run(['security', 'import', BACKUP, '-k', KEYCHAIN, '-P', password, '-T', '/usr/bin/codesign'])
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, KEYCHAIN])
        CERTIFICATE.parent.mkdir(parents=True, exist_ok=True)
        run(['/usr/bin/openssl', 'x509', '-in', work / 'cert.pem', '-outform', 'DER', '-out', CERTIFICATE])
        CERTIFICATE.chmod(0o644)
    print('Created one persistent self-signed identity. Back up the private signing directory securely.')


def requirement(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+', identifier):
        raise SystemExit('Invalid signing identifier.')
    # ponytail: pin one certificate; replacing it requires another permission migration.
    fingerprint = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest()
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'


def verify(app):
    expected = requirement(app)
    run(['codesign', '--verify', '--deep', '--strict', '-R', '=' + expected, app])
    output = run(['codesign', '-d', '-r-', app])
    match = re.search(r'(?:# )?designated => (.+)', output)
    if not match or match[1] != expected:
        raise SystemExit('The designated requirement must pin the certificate and identifier, without a version hash.')
    print('Verified stable signing identity: ' + expected)


def sign(app, require_stable):
    if PRIVATE.is_relative_to(ROOT):
        raise SystemExit('Signing secrets must be stored outside the repository.')
    if not KEYCHAIN.exists() and not PASSWORD.exists() and not require_stable:
        run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none', app])
        run(['codesign', '--verify', '--deep', '--strict', app])
        print('Local ad-hoc build: Accessibility authorization may reset after rebuilding.')
        return
    if not all(p.is_file() for p in [CERTIFICATE, KEYCHAIN, PASSWORD]):
        raise SystemExit('Stable signing identity unavailable. Restore its private backup; release signing cannot fall back to ad-hoc.')
    if PASSWORD.stat().st_mode & 0o077:
        raise SystemExit('Signing password must have owner-only permissions (chmod 600).')
    run(['security', 'unlock-keychain', '-p', PASSWORD.read_text().strip(), KEYCHAIN])
    run(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', CERTIFICATE, '-checkend', '0', '-noout'])
    identity = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest()
    run(['codesign', '--force', '--deep', '--sign', identity, '--keychain', KEYCHAIN, '--timestamp=none', app])
    verify(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?')
    parser.add_argument('--init', action='store_true')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--require-stable', action='store_true',
                        default=os.environ.get('CLIPDOCK_REQUIRE_STABLE_SIGNING') == '1')
    args = parser.parse_args()
    if args.init and args.app is None and not args.verify:
        initialize()
    elif args.app is not None and not args.init:
        if args.verify:
            verify(args.app.resolve())
        else:
            sign(args.app.resolve(), args.require_stable)
    else:
        parser.error('Use --init once, or provide an app to sign/verify.')
