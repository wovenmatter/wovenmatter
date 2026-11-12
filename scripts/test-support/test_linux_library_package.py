#!/usr/bin/env python3
"""The packed Linux library binaries: verify-linux-library.sh accepts exactly what
build-linux-library.sh writes and refuses a missing, corrupt or mismatched one."""
import gzip
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / 'scripts/verify-linux-library.sh'


class LinuxLibraryPackage(unittest.TestCase):
    def pack(self, directory, arch, binary, recorded=None):
        target = directory / ('linux-' + arch)
        target.mkdir(parents=True, exist_ok=True)
        # As build-linux-library.sh: `sha256sum` of the binary, then `gzip -9 -n`.
        (target / 'wovenmatter-library.sha256').write_text((recorded or hashlib.sha256(binary).hexdigest()) + '  wovenmatter-library\n')
        (target / 'wovenmatter-library.gz').write_bytes(gzip.compress(binary, 9, mtime=0))

    def verify(self, directory):
        return subprocess.run([str(VERIFY), str(directory)], capture_output=True, text=True)

    def test_accepts_both_architectures_and_refuses_anything_else(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.pack(directory, 'x86_64', b'amd64 binary' * 1000)
            self.assertNotEqual(self.verify(directory).returncode, 0, 'both architectures are required')
            self.pack(directory, 'aarch64', b'arm64 binary' * 1000)
            result = self.verify(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('linux-aarch64/wovenmatter-library.gz', result.stdout)
            self.pack(directory, 'aarch64', b'arm64 binary', recorded='0' * 64)
            self.assertIn('does not match', self.verify(directory).stderr)
            (directory / 'linux-aarch64/wovenmatter-library.gz').write_bytes(b'not gzip')
            self.assertNotEqual(self.verify(directory).returncode, 0)

    def test_the_build_script_packs_what_the_installer_and_verifier_read(self):
        script = (ROOT / 'scripts/build-linux-library.sh').read_text()
        self.assertIn('gzip -9 -n -c', script)
        self.assertIn('wovenmatter-library.sha256', script)
        installer = (ROOT / 'scripts/remote-host.sh').read_text()
        self.assertIn("'wovenmatter-library.gz'", installer)
        self.assertIn("'wovenmatter-library.sha256'", installer)
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        build = workflow.index('scripts/build-linux-library.sh --docker')
        download = workflow.index('actions/download-artifact@')
        self.assertLess(build, download)
        self.assertLess(download, workflow.index('scripts/build-release.sh "$VERSION" compile'))
        self.assertIn('needs: linux-library', workflow)


if __name__ == '__main__':
    unittest.main()
