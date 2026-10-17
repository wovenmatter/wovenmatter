"""Exercise actual refresh ordering/rollback against an in-memory GitHub service."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage', ROOT / 'scripts/stage-update.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

for failure in (None, 'draft-digest', 'latest-mac.json'):
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        names = ['WovenMatter_0.3.0_2_arm64.dmg', 'WovenMatter_0.3.0_arm64.dmg',
                 'SHA256SUMS.txt', 'release-build.json', 'latest-mac.json', 'appcast.xml']
        for name in names:
            (folder / name).write_text('new ' + name)
        old = dict(version='0.3.0', build=1, sha256=hashlib.sha256(b'old app').hexdigest())
        remote = {'v0.3.0': {'WovenMatter_0.3.0_arm64.dmg': b'old app',
                             'latest-mac.json': json.dumps(old).encode(), 'SHA256SUMS.txt': b'old sums'}}
        calls = []
        failed = False
        def release(tag):
            return dict(isDraft=tag != 'v0.3.0', isPrerelease=False, body='Approved notes',
                        assets=[dict(name=n) for n in remote[tag]])
        def run(*args):
            if args[:3] == ('git', 'rev-parse', 'HEAD'): return 'a' * 40
            if args[:3] == ('git', 'branch', '--show-current'): return 'main'
            if args[:2] == ('git', 'rev-parse'): return 'a' * 40
            if args[:2] == ('git', 'merge-base'): return ''
            if args[:2] == ('gh', 'api'):
                if args[2].endswith('/latest'): return json.dumps(dict(tag_name='v0.3.0'))
                tag = args[2].split('/')[-1]
                data = [dict(name=n, size=len(b), digest='sha256:' + hashlib.sha256(b).hexdigest()) for n,b in remote[tag].items()]
                if failure == 'draft-digest' and tag != 'v0.3.0':
                    data[0]['digest'] = 'sha256:' + '0' * 64
                return json.dumps(dict(assets=data))
            raise AssertionError(args)
        def gh(*args):
            if args[:2] == ('release', 'create'):
                remote[args[2]] = {}
                return ''
            if args[:2] == ('release', 'download'):
                name = args[args.index('--pattern') + 1]
                if '--dir' in args:
                    dest = Path(args[args.index('--dir') + 1]) / name
                else:
                    dest = Path(args[args.index('--output') + 1])
                dest.write_bytes(remote[args[2]][name])
                return ''
            if args[:2] == ('release', 'delete-asset'):
                del remote[args[2]][args[3]]
                return ''
            raise AssertionError(args)
        def upload(tag, files, clobber=False):
            global failed
            for p in files:
                calls.append((tag, p.name, clobber))
                if failure == p.name and tag == 'v0.3.0' and not failed:
                    failed = True
                    raise subprocess.CalledProcessError(1, ['gh', 'release', 'upload'])
                assert clobber or p.name not in remote[tag]
                remote[tag][p.name] = p.read_bytes()
        def get_release(tag):
            if tag not in remote:
                raise subprocess.CalledProcessError(1, ['gh', 'release', 'view'])
            return release(tag)
        with patch.object(stage.assets, 'verify', return_value=dict(build=2, source_revision='a' * 40)), \
             patch.object(stage, 'run', side_effect=run), patch.object(stage, 'gh', side_effect=gh), \
             patch.object(stage, 'release', side_effect=get_release), patch.object(stage, 'upload', side_effect=upload):
            try:
                stage.main(folder, '0.3.0', True)
                assert failure is None
            except (AssertionError, subprocess.CalledProcessError):
                assert failure is not None
        public = [(name, clobber) for tag, name, clobber in calls if tag == 'v0.3.0']
        if failure == 'draft-digest':
            assert not public, 'Public assets changed before private verification'
        elif failure:
            assert remote['v0.3.0']['WovenMatter_0.3.0_arm64.dmg'] == b'old app'
            assert remote['v0.3.0']['latest-mac.json'] == json.dumps(old).encode()
            assert 'appcast.xml' not in remote['v0.3.0']
        else:
            assert public[-1] == ('appcast.xml', True), 'Signed feed was not promoted last'
            assert public.index(('WovenMatter_0.3.0_2_arm64.dmg', False)) < public.index(('WovenMatter_0.3.0_arm64.dmg', True))
            assert remote['v0.3.0']['WovenMatter_0.3.0_1_arm64.dmg'] == b'old app'
print('Update refresh checks passed: private verification gate, immutable history, feed-last delivery, rollback on failed promotion.')
