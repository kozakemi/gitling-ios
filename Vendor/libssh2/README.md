# Prebuilt libssh2 for Gitling iOS

Static `libssh2` and OpenSSL slices used by the libgit2 SSH transport.

- libssh2: 1.10.1-dev (xibbon baseline)
- OpenSSL: 3.5.6
- Source: https://github.com/migueldeicaza/Libssh2Prebuild
- Build used for both slices: arm64 iOS device and arm64 iOS Simulator

Files:

```text
ios-arm64/lib/libssh2.a
ios-arm64-simulator/lib/libssh2.a
*/include/libssh2*.h
```

Licenses:

- `LICENSE-libssh2` — BSD-3-Clause
- `LICENSE-OpenSSL` — Apache-2.0
