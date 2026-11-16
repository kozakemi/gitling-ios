"""Checks the actual ordinary IPA, including omission/tampering regressions."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_terminal', ROOT / 'scripts/verify-terminal-runtime.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class TerminalBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        artifact = ROOT / 'build/Gitling.ipa'
        if not artifact.exists():
            raise unittest.SkipTest('Run scripts/build-ipa.sh to verify the ordinary IPA')
        cls.archive = zipfile.ZipFile(artifact)
        cls.names = cls.archive.namelist()
        cls.app = next(n.rsplit('/', 1)[0] for n in cls.names if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2)

    @classmethod
    def tearDownClass(cls):
        cls.archive.close()

    def test_ordinary_ipa_contains_production_pty_and_offline_git(self):
        with contextlib.redirect_stdout(io.StringIO()):
            verifier.verify(self.archive.read, self.names, self.app)

    def test_missing_dependency_rejected(self):
        names = [n for n in self.names if not n.endswith('/git-2.43.7-r0.apk')]
        with self.assertRaisesRegex(ValueError, 'Missing or unexpected'):
            verifier.verify(self.archive.read, names, self.app)

    def test_corrupted_dependency_rejected(self):
        def read(name):
            data = self.archive.read(name)
            return data + b'corrupt' if name.endswith('/git-2.43.7-r0.apk') else data
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            verifier.verify(read, self.names, self.app)

    def test_resources_without_production_bridge_rejected(self):
        def read(name):
            data = self.archive.read(name)
            return data.replace(b'GIT_CONFIG_VALUE_0=/shared', b'X' * 26) if name == self.app + '/Gitling' else data
        with self.assertRaisesRegex(ValueError, 'PTY bridge missing'):
            verifier.verify(read, self.names, self.app)
