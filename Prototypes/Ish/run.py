#!/usr/bin/env python3
"""Build/install opt-in iSH evaluation in Gitling's actual app sandbox.

Requires downloaded/verified artifacts in build/ish-prototype. No benchmark
server access. No simulator creation, cloning, erase, or deletion.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time
import json
import hashlib

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'build/ish-prototype'
APP_ID = 'com.maneeshacooray.gitling.ios'
APPROVED = ['0ED9A62A-B9F4-4BC9-AA3B-0CF0B3D93F1E',
            'D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5']
os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
os.environ['PATH'] = os.environ['DEVELOPER_DIR'] + '/usr/bin:' + os.environ['PATH']

def call(args, **kw):
    return subprocess.check_output([str(a) for a in args], **kw).decode().strip()

def fingerprint(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(directory)).encode())
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--device', choices=APPROVED, required=True)
    p.add_argument('--fresh', action='store_true', help='Archive this prototype lane and recreate fixture copies')
    args = p.parse_args()
    uid = args.device
    call(['python3', ROOT / 'Prototypes/Ish/prepare.py'])
    call(['python3', ROOT / 'Prototypes/Ish/build_policy.py'])
    # This isolated evaluation lane overrides production linking with the
    # same hardened kernel and a separately compiled ABI adapter.
    sdk = call(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    lib = CACHE / 'kernel/libIshKernel.xcframework/ios-arm64-simulator'
    call(['xcrun', 'clang', '-target', 'arm64-apple-ios18.0-simulator',
          '-isysroot', sdk, '-I', lib / 'Headers', '-c', ROOT / 'Prototypes/Ish/RuntimeBridge.c',
          '-o', CACHE / 'bridge.o'])
    call(['xcrun', 'ar', 'rcs', CACHE / 'libGitlingIshBridge.a', CACHE / 'bridge.o'])
    derived = ROOT / ('build/IshPrototypeDerivedData-' + uid)
    with (CACHE / ('build-' + uid + '.log')).open('w') as log:
        subprocess.run(['xcodebuild', '-project', str(ROOT / 'Gitling.xcodeproj'),
            '-scheme', 'Gitling', '-configuration', 'Debug', '-destination',
            'platform=iOS Simulator,id=' + uid, '-derivedDataPath', str(derived),
            '-parallel-testing-enabled', 'NO',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ISH_PROTOTYPE',
            'SWIFT_OBJC_BRIDGING_HEADER=' + str(ROOT / 'Prototypes/Ish/RuntimeBridge.h'),
            'OTHER_LDFLAGS=$(inherited) -L' + str(CACHE / 'policy') + ' -L' + str(CACHE) + ' -lGitlingIshBridge -lIshKernel -lsqlite3',
            'build'], stdout=log, stderr=subprocess.STDOUT, check=True)
    call(['xcrun', 'simctl', 'install', uid, derived / 'Build/Products/Debug-iphonesimulator/Gitling.app'])
    container = Path(call(['xcrun', 'simctl', 'get_app_container', uid, APP_ID, 'data']))
    lane = container / 'Library/Application Support/IshPrototype'
    stopped = subprocess.run(['xcrun', 'simctl', 'terminate', uid, APP_ID], capture_output=True)
    if stopped.returncode not in (0, 3):
        raise RuntimeError(stopped.stderr.decode())
    # Never remove anything outside this explicit evaluation directory.
    if lane.exists():
        if not args.fresh:
            raise SystemExit('Existing prototype lane; use --fresh to archive it before rerunning')
        shutil.move(str(lane), str(CACHE / ('previous-' + uid + '-' + str(time.time_ns()))))
    lane.mkdir(parents=True, exist_ok=True)
    shutil.copytree(CACHE / 'rootfs-original/fs', lane / 'fs')
    shared = lane / 'shared'
    shared.mkdir()
    shutil.copytree(CACHE / 'packages', shared / 'packages')
    shutil.copy2(CACHE / 'xterm-256color', shared / 'packages' / 'xterm-256color')
    shutil.copy2(ROOT / 'Prototypes/Ish/workflows.sh', shared / 'workflows.sh')
    (shared / 'host-visible').write_text('host')
    small = shared / 'small'
    call(['git', 'init', '-b', 'master', small])
    call(['git', '-C', small, 'config', 'user.name', 'Prototype'])
    call(['git', '-C', small, 'config', 'user.email', 'prototype@example.invalid'])
    (small / 'README.md').write_text('initial\n')
    call(['git', '-C', small, 'add', '.'])
    call(['git', '-C', small, 'commit', '-m', 'initial'])
    source = ROOT / 'build/performance-fixtures/Js_ms_rtos.git'
    before = fingerprint(source)
    # No hardlinks/alternates or remote credentials: independent offline copy.
    call(['git', 'clone', '--no-hardlinks', '--no-local', source, shared / 'large'])
    branches = call(['git', '-C', shared / 'large', 'for-each-ref', '--format=%(refname:strip=3)', 'refs/remotes/origin']).splitlines()
    for branch in branches:
        if branch not in ('HEAD', 'master'):
            call(['git', '-C', shared / 'large', 'branch', branch, 'origin/' + branch])
    call(['git', '-C', shared / 'large', 'remote', 'remove', 'origin'])
    (CACHE / ('container-' + uid + '.txt')).write_text(str(lane))
    print(call(['xcrun', 'simctl', 'launch', uid, APP_ID, '--ish-prototype']))
    print('Results: ' + str(lane / 'results.json'))
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if (lane / 'results.json').exists():
            rows = json.loads((lane / 'results.json').read_text())
            if any(r['name'] in ('complete', 'host.failure') for r in rows):
                break
        time.sleep(0.25)
    else:
        raise RuntimeError('Prototype did not finish within 240 seconds')
    shutil.copy2(lane / 'results.json', CACHE / ('results-' + uid + '.json'))
    shutil.copy2(lane / 'transcript.txt', CACHE / ('transcript-' + uid + '.txt'))
    assert fingerprint(source) == before, 'Original offline fixture was modified'
    bad = [r for r in rows if r['code'] != 0]
    assert not bad, bad
    assert rows[-1]['name'] == 'complete'
    print('Functional checks complete; production safety findings are retained in the report.')

if __name__ == '__main__':
    main()
