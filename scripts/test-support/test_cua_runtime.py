#!/usr/bin/env python3
"""Provider-free integrity checks for the native Cua artifact staging boundary."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare_cua', ROOT / 'scripts/prepare-cua.py')
cua = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cua)


class CuaRuntimeTests(unittest.TestCase):
    def archive(self, directory, *, link=False):
        path = directory / 'driver.tar.gz'
        with tarfile.open(path, 'w:gz') as bundle:
            member = tarfile.TarInfo('cua-driver')
            if link:
                member.type = tarfile.SYMTYPE
                member.linkname = '/outside'
                bundle.addfile(member)
            else:
                member.size = len(b'fixture executable')
                bundle.addfile(member, io.BytesIO(b'fixture executable'))
            # Unselected paths are never extracted, even in a valid archive.
            other = tarfile.TarInfo('../../outside'); other.size = 1
            bundle.addfile(other, io.BytesIO(b'x'))
        return path, {'archiveBytes': path.stat().st_size, 'archiveSHA256': cua.sha256(path),
                      'binarySHA256': hashlib.sha256(b'fixture executable').hexdigest()}

    def test_extracts_only_the_pinned_regular_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, record = self.archive(root)
            target = root / 'executable'
            cua.extract_driver(archive, target, record)
            self.assertEqual(target.read_bytes(), b'fixture executable')
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            self.assertEqual({p.name for p in root.iterdir()}, {'driver.tar.gz', 'executable'})

    def test_corrupt_or_replaced_artifacts_and_symlinks_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, record = self.archive(root)
            for field, value in [('archiveBytes', 0), ('archiveSHA256', '0' * 64), ('binarySHA256', '0' * 64)]:
                with self.assertRaises(ValueError):
                    cua.extract_driver(archive, root / 'executable', dict(record, **{field: value}))
            archive, record = self.archive(root, link=True)
            with self.assertRaises(ValueError):
                cua.extract_driver(archive, root / 'executable', record)

    def test_record_uses_upstream_release_and_integrity(self):
        record = json.loads((ROOT / 'app/Automation/cua-version.json').read_text())
        self.assertEqual(record['tag'], 'cua-driver-rs-v' + record['version'])
        self.assertTrue(record['url'].startswith('https://github.com/trycua/cua/releases/download/' + record['tag'] + '/'))
        self.assertNotIn('nightly', record['url'])
        for key in ['archiveSHA256', 'binarySHA256']:
            self.assertRegex(record[key], r'^[a-f0-9]{64}$')
        self.assertRegex(record['sourceRevision'], r'^[a-f0-9]{40}$')


if __name__ == '__main__':
    unittest.main()
