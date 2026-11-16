# Embedded offline terminal

Gitling links the iSH arm64 kernel into the ordinary iOS app, including Release
archives. `scripts/prepare-terminal-runtime.py` builds the containment changes
in `Prototypes/Ish` against the pinned kernel revision and bundles a pristine
Alpine fakefs plus checksummed offline Git, Vim and nano APKs. Downloads occur only on the
first development build; the installed app can initialize and run offline.

- Kernel source: https://github.com/Lolendor/ish-arm64/tree/2f075626049d989dc9ac350a35c09f0b18930ffc
- Embedding release: https://github.com/Lolendor/ish-arm64-pkg/releases/tag/v0.3.3
- Artifact URLs and SHA-256: `Prototypes/Ish/dependencies.json`
- All local kernel modifications: `Prototypes/Ish/build_policy.py`,
  `KernelPolicy.c`, `SecureHostFS.h`; host ABI adapter: `RuntimeBridge.c`.
- Terminal renderer: vendored MIT SwiftTerm v1.12.0 (see `../SwiftTerm`).

The kernel is GPL-3.0-or-later with the upstream additional iOS terms in
`Licenses/`. The source revision and buildable local changes must accompany
binary distribution. Alpine packages retain their upstream licenses, recorded
in their installed APK metadata. The bundle includes these notices and pinned
source/build information. The shell is Linux userspace emulated inside iOS;
it is not a host macOS shell and does not bypass iOS background limits.

One persistent PTY is permitted per app process and owned by the selected
repository's navigation scope. Entering a repository starts it automatically;
tab switches preserve its processes, environment, current directory and renderer.
The kernel acknowledges a host-only park barrier after every non-supervisor
pthread has left its CPU/syscall interval. Only then may the host release the
cross-process repository gate. Resume reacquires the gate before releasing that
barrier. Original Linux job-control stops are preserved. Native Git commands keep
their ordinary Git lock-file checks when a Guest command is parked mid-operation.

`/shared` exposes only the selected worktree. Linked worktrees additionally expose
that repository's metadata as `/gitdata`. A separate binding lease blocks
repository deletion and link/unlink until the session ends. Guests cannot mount
host paths or execute native binaries. Closing the scope cancels and drains all
descendants before unmounting; an unconfirmed exit keeps its leases until restart.
Backgrounding parks the tree, subject to iOS process-lifetime limits.

The host path adapter uses Darwin's atomic `O_NOFOLLOW_ANY` and
`AT_SYMLINK_NOFOLLOW_ANY` checks, keeping the component walker as a compatibility
fallback. Final Linux symlinks remain inspectable without following host links;
multiply linked regular files remain refused. No file-stat or directory-descriptor
cache is introduced. The exact fast and fallback paths are tested against parent
and leaf symlink swap races. Performance tests retain Git's racy-index checks,
record Trace2 phases and native index timestamp ambiguity, and check that equal-
size edits and native index changes remain visible after resuming.

For development comparisons only, `ISH_HOST_PATH_STRATEGY=component-walk` forces
the original descriptor strategy; ordinary builds use atomic checks. This setting
is part of the artifact fingerprint, so build caches cannot mix the two variants.

Offline fixture measurements are logged with `TERMINAL_PERF`, `TERMINAL_TRACE2`
and `NATIVE_INDEX_RACY`. On the same iOS 18.6 test lane, component-walk warm
status was about 1.37 s versus about 0.78 s with atomic lookups. Fresh native
indexes can still require seconds of Git's racy-timestamp content validation;
Trace2 refresh counts match the index entries ambiguous at second resolution.
These checks are retained, as are untracked scans, ctime checks and preload.
See Git's [racy timestamp implementation](https://github.com/git/git/blob/v2.43.7/read-cache.c)
and [Trace2 documentation](https://git-scm.com/docs/api-trace2).

Settings can stage a fresh private fakefs generation without deleting the running
kernel's files. A new app process selects it and removes old managed generations.
Reset removes private Linux files, packages and configurations, including private
clones; mounted Gitling worktrees, metadata and app credentials are untouched.
It does not undo changes already made to `/shared`. Reset failures leave the
previous selector intact. Regression fixtures cover failed copies, malformed
selectors and symlink-safe cleanup; an iPad two-launch check deletes Git/editors
and the shell before restoring them offline and checking repository integrity.

The local uname patch bounds Darwin hostnames and explicit overrides to the
Linux ABI field, with a deterministic fallback if the host uname call fails.
Long CI hostnames must not overflow the guest struct or trigger host libc
fortification traps. The pinned implementation is exercised with address and
undefined-behavior sanitizers in `Prototypes/Ish/test_uname.py`.
