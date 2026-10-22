"""Exercise real Release plist processing, including the shipped missing-key bug."""
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile

if sys.platform != 'darwin':
    print('Skipping Xcode release-metadata regression outside macOS.')
    raise SystemExit(0)
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'scripts/validate-release-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
revision = 'a' * 40
metadata.preflight(ROOT, '0.3.0', 547, revision)
source = plistlib.loads((ROOT / 'app/App/Info.plist').read_bytes())
with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary) / 'Info.plist'
    for value in (None, '$(UNSET_RELEASE_REVISION)'):
        broken = dict(source)
        if value is None:
            del broken['WovenMatterSourceRevision']
        else:
            broken['WovenMatterSourceRevision'] = value
        path.write_bytes(plistlib.dumps(broken))
        try:
            metadata.preflight(ROOT, '0.3.0', 547, revision, source_plist=path)
            raise AssertionError('Missing/empty packaged source revision was accepted')
        except ValueError as error:
            assert 'WovenMatterSourceRevision' in str(error), error
print('Release metadata passed: actual Xcode expansion; missing key and unset revision rejected before full compilation.')
