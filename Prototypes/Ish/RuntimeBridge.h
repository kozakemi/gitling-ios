#ifndef GP_RUNTIME_BRIDGE_H
#define GP_RUNTIME_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
int gp_ish_boot(const char *rootfs);
int gp_ish_mount_shared(const char *host_path);
void gp_ish_cancel(uint64_t token);
int gp_ish_active_threads(void);
// Returns the guest exit code, -1000 on timeout, -1001 if exit cannot be
// confirmed (the host must then retain its repository lease until termination).
int gp_ish_run(const char *script, unsigned timeout_ms, char *output,
               size_t capacity, int *truncated, uint64_t token);

// One blocking reader owns the session. Output is delivered on its worker
// thread. All controls are token checked; stale events cannot affect a new shell.
typedef void (*gp_ish_output)(const uint8_t *, size_t, void *);
int gp_ish_install_package(const char *host_path, const char *name);
int gp_ish_shell(const char *workspace, const char *gitdata, unsigned rows,
    unsigned cols, uint64_t token, gp_ish_output output, void *context);
int gp_ish_write(uint64_t token, const uint8_t *data, size_t length);
int gp_ish_resize(uint64_t token, unsigned rows, unsigned cols);
int gp_ish_interrupt(uint64_t token);
// State callback: 1 means all guest threads are stopped (release lease);
// 0 asks the host to acquire its lease before resuming. Nonzero retries later.
typedef int (*gp_ish_transition)(int suspended, void *);
int gp_ish_shell_managed(const char *workspace, const char *gitdata, unsigned rows,
    unsigned cols, uint64_t token, gp_ish_output output, gp_ish_transition transition, void *context);
void gp_ish_set_suspended(uint64_t token, int suspended);
#endif
