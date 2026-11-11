#!/bin/sh
# Run the full suite on an available iPhone simulator, locally or in CI.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

if [ -n "${TEST_DESTINATION:-}" ]; then
  destination="$TEST_DESTINATION"
else
  device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not devices:
    sys.exit("No available iPhone simulator runtime. Install one in Xcode Settings > Components.")
print(next((d for d in devices if d["state"] == "Booted"), devices[0])["udid"])
')"
  destination="platform=iOS Simulator,id=$device_id"
fi

xcodebuild \
  -project "$root/Gitling.xcodeproj" \
  -scheme Gitling \
  -destination "$destination" \
  -derivedDataPath "${TEST_DERIVED_DATA:-$root/build/TestDerivedData}" \
  -parallel-testing-enabled NO \
  test
