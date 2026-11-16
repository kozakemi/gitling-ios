// Compiled into the pinned iSH realfs object, after its system includes.
// All paths are resolved relative to an already-authorized directory descriptor.
// No host symlink (including an intermediate component) is ever followed.
#include <limits.h>
#include <stdarg.h>
struct gp_parent { int fd; char name[NAME_MAX + 1]; };
static int gp_checked_relative(const char *path, char copy[4096]) {
    if (!path || strlen(path) >= 4096) { errno = ENAMETOOLONG; return -1; }
    // Only normalized mount-relative paths enter this layer.
    while (*path == '/') path++;
    strcpy(copy, *path ? path : ".");
    // Validate the complete lexical path before attempting an atomic lookup.
    for (const char *start=copy; ; ) {
        const char *end=strchr(start,'/'); size_t length=end ? (size_t)(end-start) : strlen(start);
        if (!length || length>NAME_MAX || (length==2 && start[0]=='.' && start[1]=='.')) { errno=EPERM; return -1; }
        if (!end) break;
        start=end+1;
    }
    return 0;
}
static int gp_parent_at(int root, const char *path, struct gp_parent *out) {
    char copy[4096];
    if (gp_checked_relative(path,copy)<0) return -1;
    char *last=strrchr(copy,'/');
#if !defined(GP_FORCE_COMPONENT_WALK)
    if (!last) {
        // The mount descriptor is pinned for the entire operation. Borrowing
        // it for a top-level leaf avoids a dup/close pair on every lstat.
        out->fd=root; strcpy(out->name,copy); return 0;
    }
#endif
#if defined(O_NOFOLLOW_ANY) && !defined(GP_FORCE_COMPONENT_WALK)
    *last=0;
    int parent=openat(root,copy,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NOFOLLOW_ANY|O_CLOEXEC);
    if (parent>=0) { out->fd=parent; strcpy(out->name,last+1); return 0; }
    // Unsupported kernels retain the original descriptor walker. Other errors,
    // especially ELOOP, never fall back to a less restrictive pathname lookup.
    if (errno!=EINVAL && errno!=ENOTSUP) return -1;
    *last='/';
#endif
    int dir = dup(root); if (dir < 0) return -1;
    char *part = copy;
    for (;;) {
        char *slash = strchr(part, '/');
        if (slash) *slash = 0;
        if (!slash) { out->fd = dir; strcpy(out->name, part); return 0; }
        int next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno; close(dir);
        if (next < 0) { errno = saved; return -1; }
        dir = next; part = slash + 1;
    }
}
static void gp_parent_close(int root, struct gp_parent *parent) {
    if (parent->fd != root) close(parent->fd);
}

static int gp_not_shared_inode(int parent, const char *name) {
    struct stat st;
    if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) < 0) return errno == ENOENT ? 0 : -1;
    if (S_ISREG(st.st_mode) && st.st_nlink > 1) { errno = EPERM; return -1; }
    return 0;
}
static int gp_openat(int root, const char *path, int flags, ...) {
    mode_t mode=0;
    if (flags & O_CREAT) { va_list args; va_start(args,flags); mode=va_arg(args,int); va_end(args); }
    struct gp_parent p; if (gp_parent_at(root, path, &p) < 0) return -1;
    int fd = -1;
    // O_TRUNC must be delayed until the opened inode is checked (a hardlink
    // can be swapped between the pathname preflight and open).
    if (gp_not_shared_inode(p.fd, p.name) == 0)
        fd = openat(p.fd, p.name, (flags & ~O_TRUNC) | O_NOFOLLOW | O_CLOEXEC, mode);
    int saved = errno; gp_parent_close(root,&p);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) < 0 || (S_ISREG(st.st_mode) && st.st_nlink > 1)) {
            saved = EPERM; close(fd); fd = -1;
        } else if ((flags & O_TRUNC) && ftruncate(fd, 0) < 0) {
            saved = errno; close(fd); fd = -1;
        }
    }
    errno = saved; return fd;
}
static int gp_statat(int root, const char *path, struct stat *st, int flags) {
#if defined(AT_SYMLINK_NOFOLLOW_ANY) && !defined(GP_FORCE_COMPONENT_WALK)
    char relative[4096];
    if (gp_checked_relative(path,relative)<0) return -1;
    int direct=fstatat(root,relative,st,flags|AT_SYMLINK_NOFOLLOW|AT_SYMLINK_NOFOLLOW_ANY);
    if (!direct) {
        if (S_ISREG(st->st_mode) && st->st_nlink>1) { errno=EPERM; return -1; }
        return 0;
    }
    // ELOOP may be a final Linux symlink. The descriptor resolver can lstat
    // that leaf without following it, while still rejecting parent symlinks.
    if (errno!=EINVAL && errno!=ENOTSUP && errno!=ELOOP) return -1;
#endif
    struct gp_parent p; if (gp_parent_at(root, path, &p) < 0) return -1;
    int rc = fstatat(p.fd, p.name, st, flags | AT_SYMLINK_NOFOLLOW);
    int saved = errno; gp_parent_close(root,&p);
    if (rc == 0 && S_ISREG(st->st_mode) && st->st_nlink > 1) { rc = -1; saved = EPERM; }
    errno = saved; return rc;
}
static ssize_t gp_readlinkat(int root, const char *path, char *out, size_t cap) {
    struct gp_parent p; if (gp_parent_at(root, path, &p) < 0) return -1;
    ssize_t rc = readlinkat(p.fd, p.name, out, cap); int saved = errno; gp_parent_close(root,&p); errno = saved; return rc;
}
static int gp_unlinkat(int root, const char *path, int flags) {
    struct gp_parent p; if (gp_parent_at(root, path, &p) < 0) return -1;
    int rc = unlinkat(p.fd, p.name, flags); int saved = errno; gp_parent_close(root,&p); errno = saved; return rc;
}
static int gp_renameat(int a, const char *src, int b, const char *dst) {
    struct gp_parent x, y; if (gp_parent_at(a, src, &x) < 0) return -1;
    if (gp_parent_at(b, dst, &y) < 0) { int e=errno; gp_parent_close(a,&x); errno=e; return -1; }
    int rc = renameat(x.fd,x.name,y.fd,y.name); int e=errno; gp_parent_close(a,&x); gp_parent_close(b,&y); errno=e; return rc;
}
static int gp_symlinkat(const char *target, int root, const char *path) {
    struct gp_parent p; if (gp_parent_at(root,path,&p)<0) return -1;
    int rc=symlinkat(target,p.fd,p.name); int e=errno; gp_parent_close(root,&p); errno=e; return rc;
}
static int gp_mkdirat(int root, const char *path, mode_t mode) {
    struct gp_parent p; if (gp_parent_at(root,path,&p)<0) return -1;
    int rc=mkdirat(p.fd,p.name,mode); int e=errno; gp_parent_close(root,&p); errno=e; return rc;
}
// Guest-created hardlinks and FIFOs are deliberately unsupported in this
// prototype. Git's local-copy lane uses --no-hardlinks. Do not silently follow
// a FIFO via an unsafe process-global fchdir/mkfifo implementation.
#define openat gp_openat
#define fstatat gp_statat
#define readlinkat gp_readlinkat
#define unlinkat gp_unlinkat
#define renameat gp_renameat
#define symlinkat gp_symlinkat
#define mkdirat gp_mkdirat
#define linkat(a,b,c,d,e) (errno=EPERM, -1)
