#!/bin/sh
# Downloads the prebuilt libgit2 xcframework used by the demo.
# If GitHub is unreachable, export a proxy first, for example:
#   all_proxy=http://127.0.0.1:10911 ./scripts/fetch-libgit2.sh
set -eu
cd "$(dirname "$0")/.."
dest="Vendor/static-libgit2"
mkdir -p "$dest"
tmp="$(mktemp -d)"
url="https://github.com/flaboy/static-libgit2/releases/download/1.8.5/Clibgit2.xcframework.zip"
echo "Downloading $url"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp/Clibgit2.xcframework.zip" "$url"
echo "f62a6760f8c2ff1a82e4fb80c69fe2aa068458c7619f5b98c53c71579f72f9c7  $tmp/Clibgit2.xcframework.zip" | shasum -a 256 -c -
rm -rf "$dest/Clibgit2.xcframework"
unzip -q "$tmp/Clibgit2.xcframework.zip" -d "$dest"
if [ ! -d "$dest/Clibgit2.xcframework" ]; then
  found="$(find "$dest" -name Clibgit2.xcframework -type d | head -1)"
  mv "$found" "$dest/Clibgit2.xcframework"
fi
rm -rf "$tmp"
echo "Installed $dest/Clibgit2.xcframework"
