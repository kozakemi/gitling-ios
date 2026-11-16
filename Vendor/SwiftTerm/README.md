# SwiftTerm (vendored)

Terminal emulator from https://github.com/migueldeicaza/SwiftTerm, v1.12.0,
revision `3c45fdcfcf4395c72d2a4ee23c0bce79017b5391` (MIT).
Sources are unchanged; the local package manifest includes only the library,
without benchmark, documentation or command-line dependencies. Metal shader
source is copied for the upstream runtime fallback, so building does not require
the optional Xcode Metal Toolchain. This keeps
Gitling builds independent of additional package downloads.
