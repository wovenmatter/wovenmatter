"""Tagged recovery rebuilds incomplete uploads and rejects corrupt completed assets."""
from contextlib import contextmanager
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage', ROOT / 'scripts/stage-update.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
SHA = 'a' * 40

@contextmanager
def fixture():
    record = dict(version='1.2.3', build=42, source_revision=SHA)
    files = {'release-build.json': json.dumps(record).encode(), 'payload.dmg': b'signed payload'}
    files['SHA256SUMS.txt'] = ''.join(f'{hashlib.sha256(value).hexdigest()}  {name}\n' for name, value in files.items()).encode()
    uploaded = {name: dict(name=name, state='uploaded', size=len(value),
                          digest='sha256:' + hashlib.sha256(value).hexdigest())
                for name, value in files.items()}
    private = dict(isDraft=True, assets=list(uploaded.values()))

    def download(tag, name, destination):
        assert uploaded[name]['state'] == 'uploaded', 'Attempted to download an incomplete upload'
        destination.write_bytes(files[name])

    with tempfile.TemporaryDirectory() as temp:
        output = Path(temp) / 'output'
        # Keep real inventory/digest verification; substitute only network and
        # platform signature/notarization checks in this offline fixture.
        with patch.object(stage, 'optional_release', return_value=private) as release, \
             patch.object(stage, 'uploaded_assets', return_value=uploaded), \
             patch.object(stage, 'download', side_effect=download) as downloads, \
             patch.object(stage, 'validate_reused') as validate:
            yield SimpleNamespace(output=output, private=private, uploaded=uploaded,
                                  files=files, release=release, downloads=downloads, validate=validate)


def restore(case, revision=SHA):
    return stage.restore_tagged(case.output, '1.2.3', revision, 42)

def invalid(action):
    try:
        action()
    except (AssertionError, ValueError):
        return
    raise AssertionError('Unsafe recovery accepted')

with fixture() as case:
    assert restore(case)
    case.validate.assert_called_once_with(case.output, '1.2.3', SHA, 42)
    assert (case.output / 'payload.dmg').read_bytes() == b'signed payload'

# Never download placeholders. Complete metadata still verifies provenance before
# deciding that a missing payload permits rebuilding.
for name in ('SHA256SUMS.txt', 'release-build.json', 'payload.dmg'):
    with fixture() as case:
        case.uploaded[name].update(state='starter', size=0, digest=None)
        assert not restore(case), name
        if name == 'payload.dmg':
            assert [call.args[1] for call in case.downloads.call_args_list] == ['SHA256SUMS.txt', 'release-build.json']
        else:
            case.downloads.assert_not_called()
        case.validate.assert_not_called()
        assert not case.output.exists()

for name in ('SHA256SUMS.txt', 'release-build.json', 'payload.dmg'):
    with fixture() as case:
        del case.uploaded[name]
        case.private['assets'] = list(case.uploaded.values())
        assert not restore(case), name
        case.validate.assert_not_called()

# Empty or changed completed uploads are corruption, never rebuild permission.
for name in ('SHA256SUMS.txt', 'release-build.json', 'payload.dmg'):
    for content in (b'', b'corrupt completed upload'):
        with fixture() as case:
            case.files[name] = content
            invalid(lambda: restore(case))

with fixture() as case:
    invalid(lambda: restore(case, 'b' * 40))
with fixture() as case:
    case.uploaded['payload.dmg'].update(state='starter', size=0, digest=None)
    invalid(lambda: restore(case, 'b' * 40))
with fixture() as case:
    case.uploaded['payload.dmg'].update(state='starter', size=0, digest=None)
    case.files['release-build.json'] = b'corrupt completed metadata'
    invalid(lambda: restore(case))
# A starter with content or a digest is not a recognized failed-upload marker.
for changes in (dict(size=1, digest=None), dict(size=0, digest='sha256:' + '0' * 64)):
    with fixture() as case:
        case.uploaded['payload.dmg'].update(state='starter', **changes)
        invalid(lambda: restore(case))
        case.downloads.assert_not_called()
with fixture() as case:
    case.private['isDraft'] = False
    case.uploaded['payload.dmg'].update(state='starter', size=0, digest=None)
    invalid(lambda: restore(case))
    case.downloads.assert_not_called()
with fixture() as case:
    case.uploaded['unexpected.txt'] = dict(name='unexpected.txt', state='uploaded', size=1, digest='sha256:' + '0' * 64)
    invalid(lambda: restore(case))
with fixture() as case:
    case.validate.side_effect = ValueError('Invalid signature')
    invalid(lambda: restore(case))
with fixture() as case:
    case.release.return_value = None
    assert not restore(case)
    case.downloads.assert_not_called()

print('Tagged recovery: verified reuse; missing/starter metadata and payloads rebuild; completed corruption, source, public-state, inventory and signature failures stop recovery.')
