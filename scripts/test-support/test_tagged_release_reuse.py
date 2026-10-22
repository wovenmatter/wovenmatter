"""Tagged retry recovery rejects wrong source, public releases and corrupt assets."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage', ROOT / 'scripts/stage-update.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
SHA = 'a' * 40
record = dict(version='1.2.3', build=42, source_revision=SHA)
files = {'release-build.json': json.dumps(record).encode(), 'payload.dmg': b'signed payload'}
files['SHA256SUMS.txt'] = ''.join(f'{hashlib.sha256(value).hexdigest()}  {name}\n' for name, value in files.items()).encode()
uploaded = {name: dict(name=name, state='uploaded', size=len(value),
                      digest='sha256:' + hashlib.sha256(value).hexdigest())
            for name, value in files.items()}
private = dict(isDraft=True, assets=list(uploaded.values()))

def download(tag, name, destination):
    assert uploaded[name]['state'] == 'uploaded', 'Downloaded an incomplete upload'
    destination.write_bytes(files[name])

def invalid(action):
    try:
        action()
    except (AssertionError, ValueError):
        return
    raise AssertionError('Unsafe recovery accepted')

with tempfile.TemporaryDirectory() as temp:
    output = Path(temp) / 'output'
    with patch.object(stage, 'optional_release', return_value=private) as release, patch.object(stage, 'download', side_effect=download), patch.object(stage, 'uploaded_assets', return_value=uploaded), patch.object(stage, 'validate_reused') as validate:
        assert stage.restore_tagged(output, '1.2.3', SHA, 42)
        validate.assert_called_once_with(output, '1.2.3', SHA, 42)
        assert (output / 'payload.dmg').read_bytes() == b'signed payload'
        # Cover the metadata and payload branches of interrupted-upload recovery.
        for name in ('SHA256SUMS.txt', 'payload.dmg'):
            original = uploaded[name]
            uploaded[name] = dict(name=name, state='starter', size=0, digest=None)
            assert not stage.restore_tagged(output, '1.2.3', SHA, 42)
            uploaded[name] = original
        invalid(lambda: stage.restore_tagged(output, '1.2.3', 'b' * 40, 42))
        private['isDraft'] = False
        invalid(lambda: stage.restore_tagged(output, '1.2.3', SHA, 42))
        private['isDraft'] = True
        payload = uploaded.pop('payload.dmg')
        assert not stage.restore_tagged(output, '1.2.3', SHA, 42)
        uploaded['payload.dmg'] = payload
        files['payload.dmg'] = b'corrupt'
        invalid(lambda: stage.restore_tagged(output, '1.2.3', SHA, 42))
        files['payload.dmg'] = b'signed payload'
        validate.side_effect = ValueError('Invalid signature')
        invalid(lambda: stage.restore_tagged(output, '1.2.3', SHA, 42))
        release.return_value = None
        assert not stage.restore_tagged(output, '1.2.3', SHA, 42)
print('Tagged recovery: verified reuse; incomplete uploads rebuild; corruption, source, public-state and signature failures stop recovery.')
