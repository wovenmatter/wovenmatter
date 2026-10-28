"""Actual delivery orchestration against in-memory GitHub, including runner loss.

Artifact authenticity is exercised separately by the real signed full-update fixture;
these fixtures prove transaction/retry behavior without credentials or network.
"""
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
SHA = 'a' * 40
TARGET = 'v0.3.0'
PRIVATE = 'v0.3.0-build2'
LEGACY = 'WovenMatter_0.3.0_arm64.dmg'
FULL = 'WovenMatter_0.3.0_2_arm64.dmg'
PRIOR = 'WovenMatter_0.3.0_1_arm64.dmg'

def candidate(folder, payload=b'new app'):
    folder.mkdir()
    data = {LEGACY: payload, FULL: payload, 'SHA256SUMS.txt': b'fixture sums',
            'release-build.json': json.dumps(dict(version='0.3.0', build=2, source_revision=SHA)).encode(),
            'latest-mac.json': json.dumps(dict(version='0.3.0', build=2, sha256=hashlib.sha256(payload).hexdigest())).encode(),
            'appcast.xml': b'new signed feed' + payload}
    for name, content in data.items():
        (folder / name).write_bytes(content)
    return data

class GitHub:
    def __init__(self, failure):
        self.failure, self.failed, self.unavailable = failure, False, False
        old = dict(version='0.3.0', build=1, sha256=hashlib.sha256(b'old app').hexdigest())
        self.original = {LEGACY: b'old app', 'latest-mac.json': json.dumps(old).encode(), 'SHA256SUMS.txt': b'old sums'}
        self.remote = {TARGET: dict(self.original)}
        self.calls, self.validations, self.starters = [], [], set()

    def release(self, tag):
        if tag not in self.remote:
            raise subprocess.CalledProcessError(1, ['gh', 'release', 'view'], stderr='release not found\n')
        return dict(databaseId=1 if tag == TARGET else 2, isDraft=tag != TARGET, isPrerelease=False,
                    body='Approved notes', assets=[dict(name=n) for n in self.remote[tag]])

    def run(self, *args):
        if args[:3] == ('git', 'rev-parse', 'HEAD'): return SHA
        if args[:3] == ('git', 'branch', '--show-current'): return ''
        if args[:2] == ('git', 'rev-parse'): return SHA
        if args[:2] == ('git', 'merge-base'): return ''
        if args[:2] == ('gh', 'api'):
            if args[2].endswith('/latest'): return json.dumps(dict(tag_name=TARGET))
            # A tags endpoint cannot return our private draft. Require database ID.
            assert '/releases/tags/' not in args[2]
            tag = TARGET if args[2].endswith('/1') else PRIVATE
            data = [dict(name=n, size=len(b), state='starter' if (tag,n) in self.starters else 'uploaded', digest=None if (tag,n) in self.starters else 'sha256:' + hashlib.sha256(b).hexdigest()) for n,b in self.remote[tag].items()]
            if self.failure == 'draft-digest' and tag == PRIVATE:
                data[0]['digest'] = 'sha256:' + '0' * 64
            return json.dumps(dict(assets=data))
        raise AssertionError(args)

    def gh(self, *args):
        if args[:2] == ('release', 'create'):
            self.remote[args[2]] = {}
            return ''
        if args[:2] == ('release', 'download'):
            name = args[args.index('--pattern') + 1]
            dest = args[args.index('--output') + 1]
            if dest == '-': return self.remote[args[2]][name].decode()
            Path(dest).write_bytes(self.remote[args[2]][name])
            return ''
        if args[:2] == ('release', 'delete-asset'):
            if self.unavailable: raise subprocess.CalledProcessError(1, ['gh', 'delete'])
            self.starters.discard((args[2], args[3]))
            del self.remote[args[2]][args[3]]
            return ''
        raise AssertionError(args)

    def upload(self, tag, files, clobber=False):
        for p in files:
            self.calls.append((tag, p.name, clobber))
            if self.unavailable: raise subprocess.CalledProcessError(1, ['gh', 'upload'])
            if tag == TARGET and not self.failed and self.failure in ('latest-mac.json', 'runner-loss'):
                if self.failure == p.name or (self.failure == 'runner-loss' and p.name == 'appcast.xml'):
                    self.failed = True
                    self.unavailable = self.failure == 'runner-loss'
                    raise subprocess.CalledProcessError(1, ['gh', 'upload'])
            if not self.failed and self.failure in (FULL, PRIOR, stage.READY, stage.ROLLBACK) and p.name == self.failure and tag == (TARGET if self.failure in (FULL, PRIOR) else PRIVATE):
                self.failed = True
                self.remote[tag][p.name] = b''
                self.starters.add((tag,p.name))
                raise subprocess.CalledProcessError(1, ['gh', 'upload'])
            assert clobber or p.name not in self.remote[tag], p.name
            self.remote[tag][p.name] = p.read_bytes()

    def validate(self, folder, version, revision, build):
        assert version == '0.3.0' and revision == SHA and build == 2
        self.validations.append((folder / FULL).read_bytes())

    def execute(self, folder):
        with patch.object(stage.assets, 'verify', return_value=dict(build=2, source_revision=SHA)), \
             patch.object(stage, 'run', side_effect=self.run), patch.object(stage, 'gh', side_effect=self.gh), \
             patch.object(stage, 'release', side_effect=self.release), patch.object(stage, 'upload', side_effect=self.upload), \
             patch.object(stage, 'validate_reused', side_effect=self.validate):
            stage.main(folder, '0.3.0', True)

for failure in (None, 'draft-digest', 'latest-mac.json', 'runner-loss', FULL, PRIOR, stage.READY, stage.ROLLBACK):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        original_new = candidate(root / 'original')
        service = GitHub(failure)
        try:
            service.execute(root / 'original')
            assert failure is None
        except (AssertionError, subprocess.CalledProcessError, RuntimeError):
            assert failure is not None
        public = [(name, overwrite) for tag, name, overwrite in service.calls if tag == TARGET]
        if failure == 'draft-digest':
            assert not public, 'Public mutation before private verification'
            continue
        assert stage.READY in service.remote[PRIVATE]
        if failure not in (stage.READY, PRIOR):
            assert stage.ROLLBACK in service.remote[PRIVATE], 'Recovery backup not durable'
        if failure == 'latest-mac.json':
            assert all(service.remote[TARGET][n] == b for n,b in service.original.items())
            assert 'appcast.xml' not in service.remote[TARGET]
        if failure == 'runner-loss':
            # New metadata is visible but the signed feed is absent. This is not complete.
            assert service.remote[TARGET]['release-build.json'] == original_new['release-build.json']
            assert 'appcast.xml' not in service.remote[TARGET]
        if failure is None:
            assert public[-1] == ('appcast.xml', True)
            assert public.index((FULL, False)) < public.index((LEGACY, True))
        # A fresh signed rebuild has different bytes under the same source/build.
        # Never replace the original private/public immutable artifact with it.
        retry_payload = b'new app' if failure == stage.READY else b'nondeterministic rebuilt app'
        candidate(root / 'rebuilt', retry_payload)
        service.failure, service.unavailable = None, False
        service.calls.clear()
        service.execute(root / 'rebuilt')
        assert service.validations == ([] if failure == stage.READY else [b'new app']), service.validations
        assert all(service.remote[TARGET][n] == b for n,b in original_new.items())
        assert all(service.remote[PRIVATE][n] == b for n,b in original_new.items())
        assert service.remote[TARGET]['WovenMatter_0.3.0_1_arm64.dmg'] == b'old app'
        if failure is None:
            assert not service.calls, 'Completed retry performed writes'
        else:
            assert [(n,c) for t,n,c in service.calls if t == TARGET][-1] == ('appcast.xml', True)
# A transient access failure must never turn into a new draft.
for message in ('error connecting to api.github.com', 'HTTP 403: API rate limit exceeded'):
    error = subprocess.CalledProcessError(1, ['gh'], stderr=message)
    with patch.object(stage, 'release', side_effect=error):
        try:
            stage.optional_release(PRIVATE)
            raise AssertionError('Transient release lookup treated as absence')
        except subprocess.CalledProcessError as result:
            assert result is error
print('Update refresh passed: private ID/digest gate, durable rollback, runner-loss recovery, original-byte reuse, feed-last promotion, idempotent completed retry.')
