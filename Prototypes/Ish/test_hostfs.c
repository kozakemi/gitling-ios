// Run the exact descriptor walker used in the simulator kernel against real
// Darwin filesystem operations, including a concurrent symlink swap attack.
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "SecureHostFS.h"
#undef openat
#undef symlinkat
#undef unlinkat
#undef renameat
#undef mkdirat
#undef linkat
#undef fstatat
#undef readlinkat
static atomic_bool stop;
static int root;
static const char *sentinel;
static void *swap(void *unused) {
    while (!atomic_load(&stop)) {
        unlinkat(root,"flip",0); symlinkat(sentinel,root,"flip");
        unlinkat(root,"flip",0);
        int f=openat(root,"flip",O_CREAT|O_EXCL|O_WRONLY,0600); if(f>=0) close(f);
    }
    return NULL;
}
static void *swap_parent(void *unused) {
    while (!atomic_load(&stop)) {
        renameat(root,"branch",root,"held");
        symlinkat("../outside",root,"branch");
        unlinkat(root,"branch",0);
        renameat(root,"held",root,"branch");
    }
    return NULL;
}
int main(int argc,char **argv) {
    assert(argc==2); root=open(argv[1],O_DIRECTORY|O_RDONLY); assert(root>=0);
    char out[4096]; snprintf(out,sizeof(out),"%s/../outside/value",argv[1]); sentinel=out;
    assert(symlinkat("../outside",root,"door")==0);
    assert(gp_openat(root,"door/value",O_RDONLY)<0);
    assert(gp_openat(root,"../outside/value",O_RDONLY)<0);
    assert(gp_renameat(root,"door/value",root,"stolen")<0);
    assert(gp_mkdirat(root,"door/created",0700)<0);
    assert(linkat(AT_FDCWD,out,root,"hard",0)==0);
    assert(gp_openat(root,"hard",O_WRONLY|O_TRUNC)<0);
    struct stat st; assert(gp_statat(root,"hard",&st,0)<0);
    assert(gp_statat(root,"door",&st,AT_SYMLINK_NOFOLLOW)==0 && S_ISLNK(st.st_mode));
    assert(unlinkat(root,"hard",0)==0);
    pthread_t worker; assert(pthread_create(&worker,NULL,swap,NULL)==0);
    for(int i=0;i<20000;i++) { int f=gp_openat(root,"flip",O_WRONLY|O_TRUNC); if(f>=0) close(f); }
    atomic_store(&stop,true); pthread_join(worker,NULL);
    // Exercise both atomic-parent and fallback resolvers with a concurrent
    // intermediate-component symlink swap; stat must not expose outside data.
    assert(mkdirat(root,"branch",0700)==0);
    int inside=openat(root,"branch/value",O_CREAT|O_WRONLY,0600); assert(inside>=0); close(inside);
    struct stat outside_stat; assert(stat(out,&outside_stat)==0);
    atomic_store(&stop,false); assert(pthread_create(&worker,NULL,swap_parent,NULL)==0);
    for (int i=0;i<20000;i++) {
        struct stat st;
        if (gp_statat(root,"branch/value",&st,0)==0) assert(st.st_ino!=outside_stat.st_ino);
        int fd=gp_openat(root,"branch/value",O_WRONLY|O_TRUNC); if(fd>=0) close(fd);
    }
    atomic_store(&stop,true); pthread_join(worker,NULL);
    int f=open(out,O_RDONLY); assert(f>=0); char text[16]={0}; read(f,text,15); close(f);
    assert(strcmp(text,"unchanged")==0);
    puts("Host path traversal, parent/final symlinks, hardlink truncation, rename/mkdir escape and 20000 swap attempts blocked.");
    close(root); return 0;
}
