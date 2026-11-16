#include "RuntimeBridge.h"
#include "ishembed.h"
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>

static ish_embed_instance_t *instance;
static pthread_mutex_t execution = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t cancelled_token;
extern int gp_kernel_mount_shared(const char *);
extern int gp_kernel_stop_tree(void);
extern int gp_kernel_active_threads(void);
int gp_ish_active_threads(void) { return gp_kernel_active_threads(); }
void gp_ish_cancel(uint64_t token) { atomic_store(&cancelled_token,token); }
int gp_ish_mount_shared(const char *path) { return gp_kernel_mount_shared(path); }
static double now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
int gp_ish_boot(const char *rootfs) {
    ish_embed_boot_opts_t opts = {.rootfs_path = rootfs, .workdir = "/", .kernel_log_fd = -1};
    return ish_embed_boot(&opts, &instance);
}
int gp_ish_run(const char *script, unsigned timeout_ms, char *output,
               size_t capacity, int *truncated, uint64_t token) {
    if (!token || !capacity) return -1002;
    if (pthread_mutex_trylock(&execution)) return -1003;
    if (gp_kernel_active_threads()) { pthread_mutex_unlock(&execution); return -1001; }
    const char *argv[] = {"/bin/sh", "-c", script, NULL};
    const char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/root",
        "LC_ALL=C", "GIT_TERMINAL_PROMPT=0", "GIT_PAGER=cat", NULL};
    ish_embed_spawn_opts_t opts = {.argv = argv, .cwd = "/", .envp = env,
        .merge_stderr_into_stdout = 1};
    ish_embed_session_t *session = NULL;
    output[0] = 0; *truncated = 0;
    int rc = ish_embed_spawn(instance, &opts, &session);
    if (rc != ISH_OK) { pthread_mutex_unlock(&execution); return rc; }
    // No interactive stdin in this evaluation lane. EOF also prevents an
    // accidental credential prompt from holding the lease indefinitely.
    ish_embed_session_close_stdin(session);
    double deadline = now_ms() + timeout_ms;
    int expired = 0, was_cancelled = 0, exited = 0, stopping = 0;
    int result = -1001; size_t used = 0;
    while (1) {
        uint8_t *buf = NULL; size_t len = 0; int kind = 0;
        uint64_t seq = 0; int32_t code = 0, signal = 0;
        rc = ish_embed_session_read(session, 50, &buf, &len, &kind, &seq, &code, &signal);
        if (rc == ISH_OK && kind == 3) {
            exited=1; result=signal ? 128+signal : code;
            // Even successful parent exit may leave detached descendants.
            if (!stopping) { stopping=1; deadline=now_ms()+5000; }
        }
        if (rc == ISH_OK && len) {
            size_t take = len < capacity - used - 1 ? len : capacity - used - 1;
            memcpy(output + used, buf, take); used += take; output[used] = 0;
            if (take != len) *truncated = 1;
        }
        ish_embed_free(buf);
        if (rc != ISH_OK && rc != ISH_ERR_TIMEOUT) {
            ish_embed_session_close(session); pthread_mutex_unlock(&execution); return -1001;
        }
        int cancel=atomic_load(&cancelled_token)==token;
        if (!stopping && (cancel || now_ms()>=deadline)) {
            stopping=1; expired=!cancel; was_cancelled=cancel; deadline=now_ms()+5000;
        }
        if (stopping) {
            int active=gp_kernel_stop_tree();
            if (exited && active==0) {
                ish_embed_session_close(session); pthread_mutex_unlock(&execution);
                return was_cancelled ? -1004 : expired ? -1000 : result;
            }
            if (now_ms()>=deadline) {
                ish_embed_session_close(session); pthread_mutex_unlock(&execution); return -1001;
            }
        }
    }
}

extern int gp_kernel_mount_at(const char *, const char *);
extern int gp_kernel_unmount_shares(void);
extern int gp_kernel_install_package(const char *, const char *);
static pthread_mutex_t controls = PTHREAD_MUTEX_INITIALIZER;
static ish_embed_session_t *interactive;
static uint64_t interactive_token;
static uint64_t visibility_token;
static int requested_suspension;
extern int gp_kernel_pause_tree(void);
extern void gp_kernel_resume_tree(void);
void gp_ish_set_suspended(uint64_t token,int paused) {
    pthread_mutex_lock(&controls);
    if (!interactive || interactive_token==token) { visibility_token=token; requested_suspension=!!paused; }
    pthread_mutex_unlock(&controls);
}
int gp_ish_install_package(const char *path, const char *name) {
    if (pthread_mutex_trylock(&execution)) return -1003;
    int rc=gp_kernel_install_package(path,name);
    pthread_mutex_unlock(&execution); return rc;
}
int gp_ish_write(uint64_t token,const uint8_t *data,size_t length) {
    // Bound each input frame, including pasted text. The app chunks pastes.
    if (length>4096) return -1002;
    pthread_mutex_lock(&controls);
    int rc=interactive && interactive_token==token ? ish_embed_session_write(interactive,data,length) : -1003;
    pthread_mutex_unlock(&controls); return rc;
}
int gp_ish_resize(uint64_t token,unsigned rows,unsigned cols) {
    if (!rows || !cols || rows>1000 || cols>1000) return -1002;
    pthread_mutex_lock(&controls);
    int rc=interactive && interactive_token==token ? ish_embed_session_resize(interactive,rows,cols,0,0) : -1003;
    pthread_mutex_unlock(&controls); return rc;
}
int gp_ish_interrupt(uint64_t token) {
    pthread_mutex_lock(&controls);
    int rc=interactive && interactive_token==token ? ish_embed_session_signal(interactive,2) : -1003;
    pthread_mutex_unlock(&controls); return rc;
}
int gp_ish_shell_managed(const char *workspace,const char *gitdata,unsigned rows,
    unsigned cols,uint64_t token,gp_ish_output output,gp_ish_transition transition,void *context) {
    if (!token || !workspace || !output) return -1002;
    if (pthread_mutex_trylock(&execution)) return -1003;
    int rc=-1001;
    if (gp_kernel_active_threads()) goto done;
    rc=gp_kernel_unmount_shares(); if (rc) goto done;
    rc=gp_kernel_mount_at(workspace,"/shared"); if (rc) goto unmount;
    if (gitdata && *gitdata) { rc=gp_kernel_mount_at(gitdata,"/gitdata"); if (rc) goto unmount; }
    if (atomic_load(&cancelled_token)==token) { rc=-1004; goto unmount; }
    const char *argv[]={"/bin/sh","-i",NULL};
    const char *env[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin","HOME=/root",
        "TERM=xterm-256color","LANG=C.UTF-8","LC_ALL=C.UTF-8","GIT_PAGER=less",
        "PS1=\\w \\$ ", "GIT_CONFIG_COUNT=2",
        "GIT_CONFIG_KEY_0=safe.directory", "GIT_CONFIG_VALUE_0=/shared",
        "GIT_CONFIG_KEY_1=safe.directory", "GIT_CONFIG_VALUE_1=/gitdata/.git",
        gitdata && *gitdata ? "GIT_DIR=/gitdata/.git" : "GITLING_WORKSPACE=/shared",
        gitdata && *gitdata ? "GIT_WORK_TREE=/shared" : "GITLING_METADATA=/shared/.git",NULL};
    ish_embed_spawn_opts_t opts={.argv=argv,.cwd="/shared",.envp=env,.allocate_tty=1,
        .merge_stderr_into_stdout=1,.init_rows=rows ? rows : 24,.init_cols=cols ? cols : 80};
    ish_embed_session_t *session=NULL;
    rc=ish_embed_spawn(instance,&opts,&session); if (rc) goto unmount;
    pthread_mutex_lock(&controls); interactive=session; interactive_token=token; pthread_mutex_unlock(&controls);
    int exited=0,stopping=0,pausing=0,paused=0; double deadline=0;
    for (;;) {
        uint8_t *buf=NULL; size_t len=0; int kind=0; uint64_t seq=0; int32_t code=0,sig=0;
        int read_rc=ish_embed_session_read(session,30,&buf,&len,&kind,&seq,&code,&sig);
        if (len) output(buf,len,context);
        ish_embed_free(buf);
        if (read_rc==ISH_OK && kind==3) { exited=1; rc=sig ? 128+sig : code; }
        if (!stopping && (exited || atomic_load(&cancelled_token)==token || (read_rc && read_rc!=ISH_ERR_TIMEOUT))) {
            stopping=1; deadline=now_ms()+5000;
        }
        if (transition) {
            pthread_mutex_lock(&controls);
            int want_pause=visibility_token==token && requested_suspension;
            pthread_mutex_unlock(&controls);
            if (!stopping && (want_pause || pausing) && !paused) {
                pausing=1;
                if (gp_kernel_pause_tree()) {
                    if (transition(1,context)==0) { paused=1; pausing=0; }
                }
            }
            if (paused && (stopping || !want_pause)) {
                if (transition(0,context)!=0) continue;
                gp_kernel_resume_tree(); paused=0;
                if (stopping) deadline=now_ms()+5000;
            }
        }
        if (stopping) {
            if (pausing) { gp_kernel_resume_tree(); pausing=0; }
            int active=gp_kernel_stop_tree();
            if (exited && !active) break;
            // Keep the repository lease on an unconfirmed exit. No new shell
            // may start until app restart, even if the leader already exited.
            if (now_ms()>=deadline) { rc=-1001; break; }
        }
    }
    pthread_mutex_lock(&controls); interactive=NULL; interactive_token=0; pthread_mutex_unlock(&controls);
    ish_embed_session_close(session);
    if (rc==-1001 || gp_kernel_active_threads()) { rc=-1001; goto done; }
unmount:
    if (gp_kernel_unmount_shares()) rc=-1001;
done:
    pthread_mutex_unlock(&execution); return rc;
}

int gp_ish_shell(const char *workspace,const char *gitdata,unsigned rows,
    unsigned cols,uint64_t token,gp_ish_output output,void *context) {
    return gp_ish_shell_managed(workspace,gitdata,rows,cols,token,output,NULL,context);
}
