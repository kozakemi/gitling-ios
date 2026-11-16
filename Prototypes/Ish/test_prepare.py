import contextlib
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
from unittest.mock import patch

import prepare
import run


class PrototypePreparationTests(unittest.TestCase):
    def test_descriptor_boundary_with_actual_symlink_race(self):
        root = Path(__file__).resolve().parents[2]
        cache = root / 'build/ish-prototype'
        binary = cache / 'test-hostfs'
        for variant in ['atomic', 'component-walk']:
            flags = ['-DGP_FORCE_COMPONENT_WALK=1'] if variant == 'component-walk' else []
            subprocess.run(['/usr/bin/clang', '-std=gnu11', '-O2', *flags, '-I'+str(root/'Prototypes/Ish'),
                            str(root/'Prototypes/Ish/test_hostfs.c'), '-o', str(binary)], check=True)
            with tempfile.TemporaryDirectory(dir=cache) as temporary:
                base=Path(temporary); (base/'shared').mkdir(); (base/'outside').mkdir()
                (base/'outside/value').write_text('unchanged')
                subprocess.run([str(binary),str(base/'shared')], check=True)
                self.assertEqual((base/'outside/value').read_text(),'unchanged')

    def test_archive_traversal_and_absolute_paths_rejected(self):
        root = Path(__file__).resolve().parents[2] / 'build/ish-prototype/extraction-test'
        for name in ['../outside', '/tmp/outside', 'fs/../../outside']:
            with self.assertRaises(ValueError):
                prepare.safe_path(root, name)
        self.assertEqual(prepare.safe_path(root, 'fs/data/bin/sh'), root / 'fs/data/bin/sh')

    def test_terminfo_entry_is_extracted_without_the_hardlink(self):
        source = Path(__file__).resolve().parents[2] / 'build/ish-prototype/terminfo-source.apk'
        entry = prepare.terminfo_entry(source.read_bytes(), 'etc/terminfo/x/xterm-256color')
        self.assertEqual(hashlib.sha256(entry).hexdigest(),
                         '375da81b08a91cbbe97b1316f567346e7f31b3ec1cd4fb5be048908e920d4a3e')

    def test_cached_artifact_tampering_rejected_without_network(self):
        base = Path(__file__).resolve().parents[2] / 'build/ish-prototype'
        with tempfile.TemporaryDirectory(dir=base) as directory:
            path = Path(directory) / 'artifact'
            path.write_bytes(b'corrupt')
            row = {'url': 'https://example.invalid/never-fetch', 'sha256': hashlib.sha256(b'expected').hexdigest()}
            with patch('urllib.request.urlopen') as network:
                with self.assertRaises(ValueError):
                    prepare.download(row, path)
                network.assert_not_called()

    def test_protected_or_unknown_simulator_rejected_before_any_command(self):
        for uid in ['28474273-D7E2-4599-9D76-43642D39CB22', 'unknown']:
            with patch.object(sys, 'argv', ['run.py', '--device', uid]), patch.object(run, 'call') as command:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                    run.main()
                self.assertEqual(stopped.exception.code, 2)
                command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
