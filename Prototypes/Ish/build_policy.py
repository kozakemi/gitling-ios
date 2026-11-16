#!/usr/bin/env python3
"""Recompile policy-sensitive objects against the exact pinned kernel ABI.

Never change struct task layout or reuse objects from another source revision.
The unchanged interpreter/VDSO objects come from the checksummed release archive.
"""
import shutil
import subprocess
import json
from pathlib import Path
from prepare import CACHE, ROOT, kernel_source_path

def call(args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()

PIN = '2f075626049d989dc9ac350a35c09f0b18930ffc'

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Pinned source changed: ' + old[:70])
    return text.replace(old,new,1)

def patch_uname(text):
    # Darwin permits a longer nodename than Linux's 64-byte field. A hosted
    # runner's hostname must never overflow guest memory or abort the host.
    text = replace_once(text, '    struct utsname real_uname;\n    uname(&real_uname);',
                        '    struct utsname real_uname = {0};\n    if (uname(&real_uname) != 0) strcpy(real_uname.nodename, "gitling");')
    return replace_once(text, '    strcpy(uts->hostname, hostname);',
                        '    snprintf(uts->hostname, sizeof(uts->hostname), "%s", hostname);')

def main(platform="iphonesimulator", force_component_walk=False):
    src=kernel_source_path()
    if not src.exists() or not (src/'kernel/task.c').exists():
        raise SystemExit('Prepare pinned source with: git -C build/ish-prototype/IshEmbed submodule update --init --depth 1 third_party/ish')
    assert call(['git','-C',src,'rev-parse','HEAD']) == PIN
    out=CACHE/('policy' if platform=='iphonesimulator' else 'policy-device'); out.mkdir(exist_ok=True)
    sdk=call(['xcrun','--sdk',platform,'--show-sdk-path'])
    triple='arm64-apple-ios18.0' + ('-simulator' if platform=='iphonesimulator' else '')
    includes=['-I'+str(src),'-I'+str(ROOT/'Prototypes/Ish')]
    common=['xcrun','clang','-target',triple,'-isysroot',sdk,'-std=gnu11','-O2','-DGUEST_ARM64=1','-DENGINE_ASBESTOS=1','-DLOG_HANDLER_STDERR=1','-fno-stack-protector',*includes]
    if force_component_walk: common.append('-DGP_FORCE_COMPONENT_WALK=1')
    paths=['fs/mount.c','fs/real.c','kernel/task.c','kernel/time.c','kernel/exit.c','kernel/exec.c','fs/fake.c','kernel/calls.c','kernel/signal.c','fs/path.c','kernel/uname.c']
    for path in paths:
        text=call(['git','-C',src,'show','HEAD:'+path])+'\n'
        if path=='kernel/uname.c':
            text=patch_uname(text)
        elif path=='fs/mount.c':
            # Both mount syscalls are refused even for guest root. Trusted host
            # code retains do_mount for rootfs/proc/devpts and one pinned share.
            assert text.count('    if (is_chrooted())')==2
            text=text.replace('    if (is_chrooted())','    if (true)')
        elif path=='fs/real.c':
            text=replace_once(text,'static int getpath(', '#include "SecureHostFS.h"\n\nstatic int getpath(')
            text='extern int gp_kernel_interrupted(void);\n'+text
            text=text.replace('} while (res < 0 && errno == EINTR);','} while (res < 0 && errno == EINTR && !gp_kernel_interrupted());')
            start=text.index('int realfs_setattr('); end=text.index('\nint realfs_fsetattr(',start)
            text=text[:start]+'''int realfs_setattr(struct mount *mount, const char *path, struct attr attr) {
    if (attr.type==attr_size) return realfs_truncate(mount,path,attr.size);
    int fd=gp_openat(mount->root_fd,fix_path(path),O_RDONLY|O_NONBLOCK);
    if (fd<0) return errno_map();
    struct fd wrapper={.real_fd=fd};
    int rc=realfs_fsetattr(&wrapper,attr); close(fd); return rc;
}
'''+text[end:]
            start=text.index('int realfs_utime('); end=text.index('\nint realfs_mkdir(',start)
            text=text[:start]+'''int realfs_utime(struct mount *mount, const char *path, struct timespec atime, struct timespec mtime) {
    int fd=gp_openat(mount->root_fd,fix_path(path),O_RDONLY|O_NONBLOCK);
    if (fd<0) return errno_map();
    struct timespec times[2]={atime,mtime}; int rc=futimens(fd,times); int e=errno;
    close(fd); errno=e; return rc<0 ? errno_map() : 0;
}
'''+text[end:]
            text=replace_once(text,'    if (S_ISFIFO(mode)) {','    if (S_ISFIFO(mode)) { return _EPERM; /* no process-global cwd mutation */')
        elif path=='kernel/task.c':
            text='extern void gp_task_starting(int);\nextern void gp_task_finished(void *);\n'+text
            text=replace_once(text,'    current = vtask;','    current = vtask;\n    sigset_t wake; sigemptyset(&wake); sigaddset(&wake,SIGUSR1); pthread_sigmask(SIG_UNBLOCK,&wake,NULL);\n    pthread_cleanup_push(gp_task_finished, (void *)(uintptr_t)(current->pid != 1));')
            text=replace_once(text,'    die("task_thread returned");','    pthread_cleanup_pop(1);\n    die("task_thread returned");')
            text=replace_once(text,'    if (pthread_create(&task->thread, &task_thread_attr, task_thread, task) < 0)', '    gp_task_starting(task->pid);\n    if (pthread_create(&task->thread, &task_thread_attr, task_thread, task) != 0)')
        elif path=='kernel/time.c':
            # Bound sleeps so an uncatchable guest kill is checked promptly,
            # regardless of how the host's signal mask/restart flags behave.
            helper='''extern int gp_kernel_interrupted(void);
static int gp_bounded_sleep(struct timespec *req, struct timespec *rem) {
    if (req->tv_sec<0 || req->tv_nsec<0 || req->tv_nsec>=1000000000L) { errno=EINVAL; return -1; }
    struct timespec start,now; clock_gettime(CLOCK_MONOTONIC,&start);
    double duration=req->tv_sec + req->tv_nsec/1e9;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC,&now);
        double left=duration-((now.tv_sec-start.tv_sec)+(now.tv_nsec-start.tv_nsec)/1e9);
        if (left<=0) break;
        if (gp_kernel_interrupted()) {
            if (rem) { rem->tv_sec=(long)left; rem->tv_nsec=(long)((left-rem->tv_sec)*1e9); }
            errno=EINTR; return -1;
        }
        double step=left>0.01 ? 0.01 : left;
        struct timespec slice={0,(long)(step*1e9)};
        if (nanosleep(&slice,NULL)<0 && errno!=EINTR) return -1;
    }
    if (rem) *rem=(struct timespec){0}; return 0;
}
'''
            text=replace_once(text,'dword_t sys_nanosleep(',helper+'\ndword_t sys_nanosleep(')
            text=text.replace('nanosleep(&req, &rem)','gp_bounded_sleep(&req, &rem)')
        elif path=='kernel/exit.c':
            # Do not signal host SIGTERM or detach live pthreads. If a group
            # cannot stop, keep it alive/leased; the host will fail closed.
            marker='        if (waited_ms >= max_wait_ms) {'
            text=replace_once(text,marker,'''        if (waited_ms >= max_wait_ms) {
            for (;;) {
                lock(&pids_lock); lock(&group->lock);
                int alive=0;
                list_for_each_entry(&group->threads, task, group_links) {
                    if (task!=current) { alive++; cpu_poke(&task->cpu); }
                }
                unlock(&group->lock); unlock(&pids_lock);
                if (!alive) break;
                struct timespec delay={0,1000000}; nanosleep(&delay,NULL);
            }
        }
        if (false) {''')
        elif path=='fs/path.c':
            text=replace_once(text, 'static int path_cache_get(const char *full_path, int flags, char *out) {',
                'extern uint64_t gp_kernel_path_epoch(void);\nstatic __thread uint64_t gp_seen_epoch;\nstatic void gp_sync_path_epoch(void) {\n    uint64_t epoch=gp_kernel_path_epoch();\n    if (epoch!=gp_seen_epoch) { memset(path_cache,0,sizeof(path_cache)); gp_seen_epoch=epoch; }\n}\nstatic int path_cache_get(const char *full_path, int flags, char *out) {\n    gp_sync_path_epoch();')
            text=replace_once(text, 'static void path_cache_set(const char *full_path, int flags, const char *normalized) {',
                'static void path_cache_set(const char *full_path, int flags, const char *normalized) {\n    gp_sync_path_epoch();')
        elif path=='kernel/calls.c':
            text='extern void gp_kernel_park_current(void);\n'+text
            text=replace_once(text, '    lock(&group->lock);\n    while (group->stopped)\n        wait_for_ignore_signals(&group->stopped_cond, &group->lock, NULL);\n    unlock(&group->lock);',
                '    for (;;) {\n        gp_kernel_park_current();\n        lock(&group->lock);\n        if (!group->stopped) { unlock(&group->lock); break; }\n        wait_for_ignore_signals(&group->stopped_cond, &group->lock, NULL);\n        unlock(&group->lock);\n    }')
        elif path=='kernel/signal.c':
            text=replace_once(text, 'static void receive_signal(struct sighand *sighand, struct siginfo_ *info) {',
                'static void receive_signal(struct sighand *sighand, struct siginfo_ *info) {\n    if (info->sig == SIGSTOP_ && info->code == 0x4750) return; /* trusted park wake */')
        elif path=='kernel/exec.c':
            text=replace_once(text,'const char *native_path = native_offload_lookup(filename);','const char *native_path = NULL; /* controlled guest: no native offload */')
        elif path=='fs/fake.c':
            text=replace_once(text,'#define FAKEFS_MAX_BIND_MOUNTS 32','#include "SecureHostFS.h"\n#define FAKEFS_MAX_BIND_MOUNTS 32')
            text=replace_once(text,'int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only) {','int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only) { return _EPERM; /* no alternate host file lane */')
        name=path.replace('/','_')+'.o'; cfile=out/(name+'.c'); cfile.write_text(text)
        call([*common,'-iquote',src/Path(path).parent,'-c',cfile,'-o',out/name])
    call([*common,'-c',ROOT/'Prototypes/Ish/KernelPolicy.c','-o',out/'gp_policy.o'])
    original=CACHE/'kernel/libIshKernel.xcframework'/('ios-arm64-simulator' if platform=='iphonesimulator' else 'ios-arm64')/'libIshKernel.a'
    target=out/'libIshKernel.a'; shutil.copy2(original,target)
    call(['xcrun','ar','r',target,*[out/(p.replace('/','_')+'.o') for p in paths],out/'gp_policy.o'])
    call(['xcrun','ranlib',target])
    print('Pinned policy objects compiled and archived without ABI layout changes.')

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['iphoneos','iphonesimulator'], default='iphonesimulator')
    main(parser.parse_args().platform)
