#!/usr/bin/env python3
"""Run only the prototype layout regression on an explicitly approved device."""
import argparse
import subprocess
from run import APPROVED, CACHE, ROOT

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', choices=APPROVED, required=True)
    args = parser.parse_args()
    lib = CACHE / 'kernel/libIshKernel.xcframework/ios-arm64-simulator'
    if not (CACHE / 'libGitlingIshBridge.a').exists():
        raise SystemExit('Run the prototype once to prepare the local ABI bridge first')
    subprocess.run(['xcodebuild', '-project', str(ROOT / 'Gitling.xcodeproj'),
        '-scheme', 'Gitling', '-configuration', 'Debug', '-destination',
        'platform=iOS Simulator,id=' + args.device,
        '-derivedDataPath', str(ROOT / ('build/IshPrototypeDerivedData-' + args.device)),
        '-parallel-testing-enabled', 'NO', '-only-testing:GitlingTests/IshPrototypeLayoutTests',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ISH_PROTOTYPE',
        'SWIFT_OBJC_BRIDGING_HEADER=' + str(ROOT / 'Prototypes/Ish/RuntimeBridge.h'),
        'OTHER_LDFLAGS=$(inherited) -L' + str(CACHE / 'policy') + ' -L' + str(CACHE) + ' -lGitlingIshBridge -lIshKernel -lsqlite3',
        'test'], check=True)

if __name__ == '__main__':
    main()
