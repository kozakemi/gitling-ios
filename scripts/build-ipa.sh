#!/bin/sh
# Archives Gitling and writes an IPA.
#
# Without a signing team this produces an unsigned IPA at build/Gitling.ipa.
# It has the Payload layout, but iOS will not install it until it is signed.
#
# With a team, the script signs and exports a development IPA:
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build-ipa.sh
# Optional: EXPORT_METHOD=app-store-connect (default: development)
#
# If GitHub is blocked while libgit2 still needs to be built:
#   all_proxy=http://127.0.0.1:10911 ./scripts/build-ipa.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

scheme="Gitling"
configuration="${CONFIGURATION:-Release}"
archive="$root/build/Gitling.xcarchive"
ipa="$root/build/Gitling.ipa"
xcframework="$root/Vendor/static-libgit2/Clibgit2.xcframework"

if [ ! -d "$xcframework/ios-arm64" ]; then
  "$root/scripts/build-libgit2.sh"
fi

rm -rf "$archive"
mkdir -p "$root/build"

echo "Archiving $scheme ($configuration)"
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  xcodebuild \
    -project "$root/Gitling.xcodeproj" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "generic/platform=iOS" \
    -archivePath "$archive" \
    archive \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic
else
  xcodebuild \
    -project "$root/Gitling.xcodeproj" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "generic/platform=iOS" \
    -archivePath "$archive" \
    archive \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""
fi

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  method="${EXPORT_METHOD:-development}"
  options="$root/build/ExportOptions.plist"
  cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$method</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
EOF
  rm -rf "$root/build/export"
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$root/build/export" \
    -exportOptionsPlist "$options"
  exported="$(find "$root/build/export" -name '*.ipa' -print -quit)"
  cp "$exported" "$ipa"
else
  app="$(find "$archive/Products/Applications" -name '*.app' -maxdepth 1 -print -quit)"
  payload="$root/build/Payload"
  rm -rf "$payload"
  mkdir -p "$payload"
  cp -R "$app" "$payload/"
  rm -f "$ipa"
  (cd "$root/build" && zip -qry "$ipa" Payload)
  rm -rf "$payload"
fi

echo "Wrote $ipa"
