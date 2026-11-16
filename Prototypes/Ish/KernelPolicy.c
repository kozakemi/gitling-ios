// Policy for one serialized Guest command tree per process. PID 1 is the
// supervisor; every other task is owned by the currently active invocation,
// regardless of setsid/setpgid/reparenting. Multi-session execution is refused.
#include <time.h>
#include <stdio.h>
#include <signal.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>
#include "kernel/calls.h"
#include "kernel/task.h"
#include "fs/real.h"
#include "fs/path.h"
#include "fs/fd.h"
#include <string.h>
#include <stdarg.h>
#include "SecureHostFS.h"

static atomic_int active_threads;
void gp_task_starting(int pid) { if (pid != 1) atomic_fetch_add(&active_threads, 1); }
void gp_task_finished(void *tracked) { if (tracked) atomic_fetch_sub(&active_threads, 1); }
int gp_kernel_active_threads(void) { return atomic_load(&active_threads); }
int gp_kernel_killed(void) {
    if (!current || !current->sighand) return 0;
    lock(&current->sighand->lock);
    int killed=sigset_has(current->pending,SIGKILL_);
    unlock(&current->sighand->lock); return killed;
}
int gp_kernel_interrupted(void) {
    if (!current || !current->sighand) return 0;
    lock(&current->sighand->lock);
    int pending=(current->pending & ~current->blocked) != 0 || sigset_has(current->pending,SIGKILL_);
    unlock(&current->sighand->lock); return pending;
}
int gp_kernel_stop_tree(void) {
    lock(&pids_lock);
    for (unsigned id=2; id<=MAX_PID; id++) {
        struct task *task=pid_get_task(id);
        if (task && !task->zombie && !task->exiting) send_signal(task, SIGKILL_, SIGINFO_NIL);
    }
    unlock(&pids_lock);
    return gp_kernel_active_threads();
}
// Darwin reports /var, /tmp and /etc through /private. Any other difference
// means a host symlink was followed, so the share is refused.
static int gp_share_path_matches(const char *opened, const char *requested) {
    if (strcmp(opened, requested) == 0) return 1;
    const char prefix[] = "/private";
    size_t prefix_len = sizeof(prefix) - 1;
    if (strncmp(opened, prefix, prefix_len) == 0 && strcmp(opened + prefix_len, requested) == 0) return 1;
    if (strncmp(requested, prefix, prefix_len) == 0 && strcmp(requested + prefix_len, opened) == 0) return 1;
    return 0;
}
static int gp_open_share(const char *path) {
    if (!path || path[0] != '/' || strcmp(path, "/") == 0) return -1;
    for (const char *cursor = path; *cursor; ) {
        while (*cursor == '/') cursor++;
        if (!*cursor) break;
        const char *start = cursor;
        while (*cursor && *cursor != '/') cursor++;
        size_t length = (size_t)(cursor - start);
        if (!length || length > NAME_MAX) return -1;
        if ((length == 1 && start[0] == '.') || (length == 2 && start[0] == '.' && start[1] == '.')) return -1;
    }
    // Open the authorized directory directly. Walking from "/" fails inside the
    // iOS sandbox and for security-scoped folders even when this path is allowed.
    int root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) return -1;
    char actual[PATH_MAX];
    if (fcntl(root, F_GETPATH, actual) < 0 || !gp_share_path_matches(actual, path)) {
        close(root);
        return -1;
    }
    return root;
}
int gp_kernel_mount_at(const char *path, const char *point) {
    if (gp_kernel_active_threads() || (strcmp(point,"/shared") && strcmp(point,"/gitdata"))) return _EPERM;
    // Called only by trusted host code, once, before exposing any shared files.
    // Keep an open descriptor as the authority instead of trusting later paths.
    int root=gp_open_share(path);
    if (root<0) return -1;
    struct task *saved=current;
    lock(&pids_lock); current=pid_get_task(1); unlock(&pids_lock);
    if (!current) { close(root); current=saved; return -1; }
    int rc=generic_mkdirat(AT_PWD,point,0755);
    if (rc && rc!=_EEXIST) { close(root); current=saved; return rc; }
    lock(&mounts_lock);
    rc=do_mount(&realfs,path,point,"",0);
    unlock(&mounts_lock);
    if (!rc) {
        char name[32]; strcpy(name,point); struct mount *mount=mount_find(name);
        close(mount->root_fd); mount->root_fd=root;
        mount_release(mount);
    } else close(root);
    current=saved; return rc;
}

// Trusted host-only lifecycle operations; never callable through a guest syscall.
int gp_kernel_unmount_shares(void) {
    if (gp_kernel_active_threads()) return _EBUSY;
    struct task *saved=current;
    lock(&pids_lock); current=pid_get_task(1); unlock(&pids_lock);
    lock(&mounts_lock);
    int a=do_umount("/shared"), b=do_umount("/gitdata");
    unlock(&mounts_lock); current=saved;
    return (a && a!=_EINVAL) ? a : (b && b!=_EINVAL) ? b : 0;
}
int gp_kernel_install_package(const char *host, const char *name) {
    if (gp_kernel_active_threads() || !name || strchr(name,'/') || strstr(name,"..")) return _EPERM;
    int input=open(host,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if (input<0) return -1;
    struct task *saved=current;
    lock(&pids_lock); current=pid_get_task(1); unlock(&pids_lock);
    int rc=generic_mkdirat(AT_PWD,"/tmp/git-packages",0700);
    char path[256]; snprintf(path,sizeof(path),"/tmp/git-packages/%s",name);
    struct fd *output=generic_open(path,O_WRONLY_|O_CREAT_|O_TRUNC_,0600);
    if (IS_ERR(output)) { rc=PTR_ERR(output); }
    else {
        char buf[65536]; ssize_t n; rc=0;
        while ((n=read(input,buf,sizeof(buf)))>0) {
            ssize_t done=0;
            while (done<n) {
                ssize_t written=output->ops->write(output,buf+done,n-done);
                if (written<=0) { rc=-1; break; }
                done+=written;
            }
            if (rc) break;
        }
        if (n<0) rc=-1;
        fd_close(output);
    }
    close(input); current=saved; return rc;
}

int gp_kernel_mount_shared(const char *path) { return gp_kernel_mount_at(path,"/shared"); }

// The counter and the transition out of the parked state share one mutex.
// A rapid pause/resume/pause can never mistake waking threads for parked ones.
static pthread_mutex_t park_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t park_changed=PTHREAD_COND_INITIALIZER;
static atomic_int host_paused;
static atomic_uint_fast64_t path_epoch = 1;
uint64_t gp_kernel_path_epoch(void) { return atomic_load(&path_epoch); }
static int parked_threads;
void gp_kernel_park_current(void) {
    if (!current || current->pid==1 || !atomic_load(&host_paused)) return;
    pthread_mutex_lock(&park_lock);
    if (host_paused) {
        parked_threads++;
        while (host_paused) pthread_cond_wait(&park_changed,&park_lock);
        parked_threads--;
    }
    pthread_mutex_unlock(&park_lock);
}
int gp_kernel_pause_tree(void) {
    pthread_mutex_lock(&park_lock); host_paused=1; pthread_mutex_unlock(&park_lock);
    lock(&pids_lock);
    for (unsigned id=2; id<=MAX_PID; id++) {
        struct task *task=pid_get_task(id);
        if (!task || task->zombie || task->exiting) continue;
        // Unmaskable wake, consumed by our signal shim without changing Linux
        // job control or invoking user handlers. Wakes blocked tty/futex IO too.
        deliver_signal(task,SIGSTOP_,(struct siginfo_){.sig=SIGSTOP_,.code=0x4750});
    }
    pthread_mutex_lock(&park_lock);
    int ready=atomic_load(&active_threads)==parked_threads;
    pthread_mutex_unlock(&park_lock);
    unlock(&pids_lock); return ready;
}
void gp_kernel_resume_tree(void) {
    pthread_mutex_lock(&park_lock);
    atomic_fetch_add(&path_epoch,1); host_paused=0;
    pthread_cond_broadcast(&park_changed); pthread_mutex_unlock(&park_lock);
}
