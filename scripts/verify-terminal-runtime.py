#!/usr/bin/env python3
"""Fail packaging if the ordinary IPA omits the shell or offline dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def verify(read, names, app):
    prefix = app + '/TerminalRuntime/'
    manifest = json.loads(read(prefix + 'manifest.json'))
    expected = json.loads((ROOT / 'Prototypes/Ish/dependencies.json').read_text())
    for key in ('kernel', 'rootfs', 'kernelSource', 'packages'):
        if manifest[key] != expected[key]:
            raise ValueError('Unexpected bundled runtime manifest: ' + key)
    expected_names = {row['name'] for row in expected['packages']}
    actual_names = {n[len(prefix + 'packages/'):] for n in names if n.startswith(prefix + 'packages/') and not n.endswith('/')}
    if expected_names != actual_names:
        raise ValueError('Missing or unexpected offline APK files')
    for row in expected['packages']:
        if hashlib.sha256(read(prefix + 'packages/' + row['name'])).hexdigest() != row['sha256']:
            raise ValueError('Offline APK checksum mismatch: ' + row['name'])
    terminfo = expected['terminfo']
    if hashlib.sha256(read(prefix + terminfo['name'])).hexdigest() != terminfo['fileSha256']:
        raise ValueError('Terminfo entry checksum mismatch')
    for path in ('fs/data/bin/busybox', 'fs/data/sbin/ishsv'):
        data = read(prefix + path)
        if data[:4] != b'\x7fELF' or struct.unpack_from('<H', data, 18)[0] != 183:
            raise ValueError('Expected arm64 Linux runtime: ' + path)
    for path in ('fs/meta.db', 'SOURCE.md', 'Licenses/GPL-3.0.txt', 'Licenses/LICENSE.IOS'):
        if not read(prefix + path):
            raise ValueError('Missing runtime metadata or license: ' + path)
    binary = read(app + '/Gitling')
    if binary[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', binary, 4)[0] != 0x100000c:
        raise ValueError('Expected arm64 Mach-O application')
    # These constants come from the production PTY bridge, which is referenced
    # by the Swift terminal. Release strips symbols, so nm is not sufficient.
    for marker in (b'GIT_CONFIG_VALUE_0=/shared', b'GIT_DIR=/gitdata/.git', b'GIT_WORK_TREE=/shared'):
        if marker not in binary:
            raise ValueError('Production PTY bridge missing from application')
    print('Verified production arm64 terminal, supervisor, fakefs, 25 offline APKs and source/license notices.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.ipa) as archive:
        names = archive.namelist()
        apps = [name.rsplit('/', 1)[0] for name in names if name.startswith('Payload/') and name.endswith('.app/Info.plist') and name.count('/') == 2]
        if len(apps) != 1:
            raise ValueError('Expected exactly one top-level application')
        verify(archive.read, names, apps[0])


if __name__ == '__main__':
    main()
