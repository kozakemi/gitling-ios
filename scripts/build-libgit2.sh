#!/bin/sh
# Builds a static libgit2 xcframework for iOS 18+ (device and simulator).
# HTTPS uses SecureTransport, so the download is only the libgit2 source.
# If GitHub is blocked:
#   all_proxy=http://127.0.0.1:10911 ./scripts/build-libgit2.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:$DEVELOPER_DIR/usr/bin:$PATH"

src_root="$root/Vendor/src"
src="$src_root/libgit2-1.8.4"
work="$root/Vendor/build"
out="$root/Vendor/static-libgit2/Clibgit2.xcframework"

if [ ! -f "$src/CMakeLists.txt" ]; then
  mkdir -p "$src_root"
  tmp="$(mktemp -d)"
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp/libgit2.tar.gz" \
    "https://codeload.github.com/libgit2/libgit2/tar.gz/refs/tags/v1.8.4"
  tar -xzf "$tmp/libgit2.tar.gz" -C "$src_root"
  rm -rf "$tmp"
fi

# libgit2 only probes Security.framework when the system name is Darwin.
# iOS builds need the same probe, pointed at the SDK.
python3 - "$src/cmake/SelectHTTPSBackend.cmake" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'if(CMAKE_SYSTEM_NAME MATCHES "Darwin")'
new = 'if(CMAKE_SYSTEM_NAME MATCHES "Darwin" OR CMAKE_SYSTEM_NAME MATCHES "iOS")'
if old in text:
    path.write_text(text.replace(old, new, 1))
PY

build_one() {
  sdk="$1"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  prefix="$work/$sdk"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  cmake -S "$src" -B "$prefix/cmake" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
    -DCMAKE_FIND_ROOT_PATH="$sysroot" \
    -DCMAKE_FRAMEWORK_PATH="$sysroot/System/Library/Frameworks" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix/install" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=SecureTransport \
    -DUSE_HTTP_PARSER=builtin \
    -DREGEX_BACKEND=builtin \
    -DUSE_BUNDLED_ZLIB=OFF
  cmake --build "$prefix/cmake" --parallel
  cmake --install "$prefix/cmake"
  cat > "$prefix/install/include/module.modulemap" <<'EOF'
module Clibgit2 {
    header "git2.h"
    export *
    link "z"
    link "iconv"
    link framework "Security"
    link framework "CoreFoundation"
}
EOF
}

build_one iphoneos
build_one iphonesimulator

rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$work/iphoneos/install/lib/libgit2.a" -headers "$work/iphoneos/install/include" \
  -library "$work/iphonesimulator/install/lib/libgit2.a" -headers "$work/iphonesimulator/install/include" \
  -output "$out"
for slice in "$out"/*; do
  if [ -d "$slice/Headers" ]; then
    mkdir -p "$slice/Modules"
    cp "$slice/Headers/module.modulemap" "$slice/Modules/module.modulemap"
  fi
done
echo "Installed $out"
