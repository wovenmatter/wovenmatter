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
private = dict(isDraft=True, assets=[dict(name=name) for name in files])

def download(tag, name, destination):
    destination.write_bytes(files[name])

def invalid(action):
    try:
        action()
    except (AssertionError, ValueError):
        return
    raise AssertionError('Unsafe recovery accepted')

with tempfile.TemporaryDirectory() as temp:
    output = Path(temp) / 'output'
    with patch.object(stage, 'optional_release', return_value=private) as release, patch.object(stage, 'download', side_effect=download), patch.object(stage, 'verify_uploaded') as uploaded, patch.object(stage, 'validate_reused') as validate:
        assert stage.restore_tagged(output, '1.2.3', SHA, 42)
        validate.assert_called_once_with(output, '1.2.3', SHA, 42)
        assert (output / 'payload.dmg').read_bytes() == b'signed payload'
        invalid(lambda: stage.restore_tagged(output, '1.2.3', 'b' * 40, 42))
        private['isDraft'] = False
        invalid(lambda: stage.restore_tagged(output, '1.2.3', SHA, 42))
        private['isDraft'] = True
        private['assets'] = [a for a in private['assets'] if a['name'] != 'payload.dmg']
        assert not stage.restore_tagged(output, '1.2.3', SHA, 42)
        private['assets'].append(dict(name='payload.dmg'))
        validate.side_effect = ValueError('Invalid signature')
        invalid(lambda: stage.restore_tagged(output, '1.2.3', SHA, 42))
        release.return_value = None
        assert not stage.restore_tagged(output, '1.2.3', SHA, 42)
print('Tagged recovery: original bytes reused; partial upload rebuild allowed; source, public-state and signature failures stop recovery.')
