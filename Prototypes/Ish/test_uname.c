// Linked with the patched, pinned do_uname implementation by test_uname.py.
#include <assert.h>
#include <string.h>
#include <sys/utsname.h>

struct uname {
    char system[65], hostname[65], release[65], version[65], arch[65], domain[65];
};
extern void do_uname(struct uname *);
extern const char *uname_hostname_override;
static char host[sizeof(((struct utsname *)0)->nodename)];
static int unavailable;

int uname(struct utsname *value) {
    if (unavailable) return -1;
    memset(value, 0, sizeof(*value));
    memcpy(value->nodename, host, sizeof(host));
    return 0;
}

static void check(const char *expected) {
    struct { unsigned char before[16]; struct uname value; unsigned char after[16]; } box;
    memset(&box, 0xa5, sizeof(box));
    do_uname(&box.value);
    size_t length = strlen(expected);
    if (length > 64) length = 64;
    assert(strlen(box.value.hostname) == length);
    assert(memcmp(box.value.hostname, expected, length) == 0);
    assert(box.value.hostname[length] == '\0');
    assert(strcmp(box.value.system, "Linux") == 0);
    assert(strcmp(box.value.release, "4.20.69-ish") == 0);
    assert(strcmp(box.value.arch, "aarch64") == 0);
    assert(strcmp(box.value.domain, "(none)") == 0);
    for (size_t i = 0; i < 16; i++) assert(box.before[i] == 0xa5 && box.after[i] == 0xa5);
}

int main(void) {
    size_t lengths[] = {0, 1, 63, 64, 65, sizeof(host) - 1};
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        memset(host, 'h', sizeof(host)); host[lengths[i]] = '\0';
        check(host);
    }
    char override[1024]; memset(override, 'o', sizeof(override)); override[1023] = '\0';
    uname_hostname_override = override; check(override);
    uname_hostname_override = "explicit-name"; check("explicit-name");
    uname_hostname_override = NULL; unavailable = 1; check("gitling");
    uname_hostname_override = "still-explicit"; check("still-explicit");
    return 0;
}
