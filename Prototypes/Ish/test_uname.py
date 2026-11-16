"""Exercise the actual patched upstream uname with long Darwin hostnames."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import build_policy
import prepare


class UnameBoundaryTests(unittest.TestCase):
    def test_pinned_uname_truncates_host_and_override_without_corrupting_fields(self):
        source = subprocess.check_output([
            'git', '-C', str(prepare.kernel_source_path()), 'show', 'HEAD:kernel/uname.c'
        ], text=True)
        patched = build_policy.patch_uname(source)
        function = patched[patched.index('void do_uname('):patched.index('dword_t sys_uname(')]
        # Use the pinned Linux ABI layout, not a test-specific larger buffer.
        calls = (prepare.kernel_source_path() / 'kernel/calls.h').read_text()
        layout = calls[calls.index('#define UNAME_LENGTH'):calls.index('void do_uname(')]
        unit = '#include <stdio.h>\n#include <string.h>\n#include <sys/utsname.h>\n' + layout
        unit += 'const char *uname_version = "test";\nconst char *uname_hostname_override;\n' + function
        with tempfile.TemporaryDirectory(dir=prepare.CACHE) as temporary:
            root = Path(temporary)
            (root / 'uname.c').write_text(unit)
            subprocess.run([
                '/usr/bin/clang', '-std=gnu11', '-O2', '-U_FORTIFY_SOURCE', '-D_FORTIFY_SOURCE=2', '-DGUEST_ARM64=1',
                '-fsanitize=address,undefined', str(root / 'uname.c'),
                str(prepare.ROOT / 'Prototypes/Ish/test_uname.c'), '-o', str(root / 'check')
            ], check=True)
            subprocess.run([str(root / 'check')], check=True)
