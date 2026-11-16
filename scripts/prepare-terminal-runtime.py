#!/usr/bin/env python3
"""Build the pinned, hardened iSH library and bundle offline runtime assets.

Called by Xcode for simulator AND device builds. Verified downloads are cached
on the external build volume; subsequent builds require no network.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Prototypes/Ish'))
import prepare
import build_policy


def main():
    platform = os.environ.get('PLATFORM_NAME', 'iphonesimulator')
    if platform not in ('iphoneos', 'iphonesimulator'):
        raise SystemExit('Embedded terminal supports arm64 iOS and iOS Simulator only')
    if any(a != 'arm64' for a in os.environ.get('ARCHS', 'arm64').split()):
        raise SystemExit('The pinned iSH runtime requires arm64')
    out = ROOT / 'build/terminal-runtime' / platform
    out.mkdir(parents=True, exist_ok=True)
    inputs = [ROOT / 'Prototypes/Ish' / f for f in
              ('dependencies.json', 'build_policy.py', 'KernelPolicy.c', 'SecureHostFS.h', 'RuntimeBridge.c', 'RuntimeBridge.h')]
    inputs += sorted((ROOT / 'Vendor/IshRuntime/Licenses').glob('*'))
    inputs.append(ROOT / 'Vendor/IshRuntime/README.md')
    sdk = subprocess.check_output(['xcrun', '--sdk', platform, '--show-sdk-path'], text=True).strip()
    digest = hashlib.sha256((platform + sdk + Path(__file__).read_text()).encode())
    for path in inputs:
        digest.update(path.read_bytes())
    force_walk = os.environ.get('ISH_HOST_PATH_STRATEGY') == 'component-walk'
    digest.update(str(force_walk).encode())
    version = digest.hexdigest()
    stamp = out / 'version'
    assets = out / 'TerminalRuntime'
    if not stamp.exists() or stamp.read_text() != version or not (out / 'libGitlingIsh.a').exists() or not assets.exists():
        prepare.main()
        build_policy.main(platform, force_component_walk=force_walk)
        slice_name = 'ios-arm64' + ('-simulator' if platform == 'iphonesimulator' else '')
        headers = prepare.CACHE / 'kernel/libIshKernel.xcframework' / slice_name / 'Headers'
        triple = 'arm64-apple-ios18.0' + ('-simulator' if platform == 'iphonesimulator' else '')
        subprocess.run(['xcrun', 'clang', '-target', triple, '-isysroot', sdk, '-O2', '-I', str(headers),
                        '-c', str(ROOT / 'Prototypes/Ish/RuntimeBridge.c'), '-o', str(out / 'bridge.o')], check=True)
        policy = prepare.CACHE / ('policy' if platform == 'iphonesimulator' else 'policy-device') / 'libIshKernel.a'
        subprocess.run(['xcrun', 'libtool', '-static', '-o', str(out / 'libGitlingIsh.a'), str(policy), str(out / 'bridge.o')], check=True)
        staging = out / 'TerminalRuntime.tmp'
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir()
        shutil.copytree(prepare.CACHE / 'rootfs-original/fs', staging / 'fs')
        (staging / 'packages').mkdir()
        package_manifest = json.loads(inputs[0].read_text())
        for row in package_manifest['packages']:
            shutil.copy2(prepare.CACHE / 'packages' / row['name'], staging / 'packages' / row['name'])
        terminfo = package_manifest['terminfo']
        shutil.copy2(prepare.CACHE / terminfo['name'], staging / terminfo['name'])
        manifest = json.loads(inputs[0].read_text())
        shutil.copytree(ROOT / 'Vendor/IshRuntime/Licenses', staging / 'Licenses')
        shutil.copy2(ROOT / 'Vendor/IshRuntime/README.md', staging / 'SOURCE.md')
        manifest['version'] = version
        (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        shutil.rmtree(assets, ignore_errors=True)
        staging.rename(assets)
        stamp.write_text(version)
    if os.environ.get('TARGET_BUILD_DIR') and os.environ.get('UNLOCALIZED_RESOURCES_FOLDER_PATH'):
        destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'TerminalRuntime'
        # ditto preserves fakefs metadata files; source contains no host symlinks.
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(destination, ignore_errors=True)
        subprocess.run(['/usr/bin/ditto', str(assets), str(destination)], check=True)
    print('Offline terminal runtime ready: ' + platform)


if __name__ == '__main__':
    (ROOT / 'build/terminal-runtime').mkdir(parents=True, exist_ok=True)
    with (ROOT / 'build/terminal-runtime/prepare.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
