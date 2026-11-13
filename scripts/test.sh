#!/bin/sh
# Run the full suite on an available iPhone simulator, locally or in CI.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

# Pin local testing to the two approved devices; never fall back to a user's device.
export TEST_DESTINATION="${TEST_DESTINATION:-}"
export CI="${CI:-}"
destination="$(xcrun simctl list devices available --json | python3 -c '
import json, os, sys
approved = ["0ED9A62A-B9F4-4BC9-AA3B-0CF0B3D93F1E", "D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5"]
protected = "28474273-D7E2-4599-9D76-43642D39CB22"
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if d.get("isAvailable")]
known = {d["udid"]: d for d in devices}
ci = os.environ.get("CI", "").lower() == "true"
request = os.environ.get("TEST_DESTINATION", "")
if request:
    parts = dict(part.strip().split("=", 1) for part in request.split(",") if "=" in part)
    uid = parts.get("id", "")
    if parts.get("platform") != "iOS Simulator" or uid not in known or uid == protected or (not ci and uid not in approved):
        sys.exit("Use an explicit approved simulator UDID from AGENTS.md; no replacement device will be created.")
else:
    uid = next((uid for uid in approved if uid in known), None)
    if uid is None and ci:
        uid = next((d["udid"] for d in devices if d["name"].startswith("iPhone") and d["udid"] != protected), None)
    if uid is None:
        sys.exit("No approved simulator is available. Report this; do not create or clone a device.")
print("platform=iOS Simulator,id=" + uid)
')"

if [ "${TEST_DRY_RUN:-0}" = "1" ]; then
  echo "$destination"
  exit 0
fi

# Different simulator runtimes thin Assets.car differently. Sharing a product
# directory can let Xcode reuse CodeResources after relinking the asset catalog.
# Keep each approved destination's build/signing cache separate; no device clones.
device_id="${destination##*id=}"
derived_data="${TEST_DERIVED_DATA:-$root/build/TestDerivedData-$device_id}"

xcodebuild \
  -project "$root/Gitling.xcodeproj" \
  -scheme Gitling \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  test
