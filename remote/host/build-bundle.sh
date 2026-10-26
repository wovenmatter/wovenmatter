#!/usr/bin/env bash
set -euo pipefail
# Source-only bundle: install the locked dependency graph on the Linux target so
# optional native SDK packages match its OS, CPU and libc rather than the Mac.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
exec python3 - "$root" "${1:-}" "${2:--}" <<'PY'
import gzip, hashlib, io, json, os, re, sys, tarfile
from pathlib import Path
root, fingerprint, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if not re.fullmatch(r'[a-f0-9]{64}', fingerprint):
    raise SystemExit('A SHA-256 deployment fingerprint is required.')
versions = json.loads((root/'remote/host/runtime-versions.json').read_text())
lock = json.loads((root/'default-agent/package-lock.json').read_text())
if versions['nodeVersion'] != (root/'default-agent/.node-version').read_text().strip():
    raise SystemExit('Host Node selection differs from the bundled runtime.')
if versions['playwrightVersion'] != lock['packages']['node_modules/playwright-core']['version']:
    raise SystemExit('Host Playwright selection differs from the lockfile.')
files = {}
for source, target in [('remote/src','src'), ('remote/package.json','package.json'),
    ('default-agent/src','default-agent/src'), ('default-agent/package.json','default-agent/package.json'),
    ('default-agent/package-lock.json','default-agent/package-lock.json'), ('harnesses','harnesses'),
    ('remote/host','host'), ('default-agent/.node-version','default-agent/.node-version'),
    ('scripts/remote-host.sh','host/remote-host.sh')]:
    path = root/source
    for item in sorted(path.rglob('*')) if path.is_dir() else [path]:
        if item.name == '.DS_Store':
            continue
        if item.is_symlink():
            raise SystemExit('Host bundle source must not contain symbolic links: '+str(item))
        if item.is_file():
            relative = item.relative_to(path).as_posix() if path.is_dir() else ''
            name = target + ('/'+relative if relative else '')
            if name == 'host/bin/wm-exec': name = 'bin/wm-exec'
            files[name] = (item.read_bytes(), 0o700 if item.stat().st_mode & 0o111 else 0o600, item.relative_to(root).as_posix(), item.stat().st_mode & 0o111)
manifest = {'fingerprint':fingerprint, 'nodeVersion':versions['nodeVersion'],
    'playwrightVersion':versions['playwrightVersion'], 'dependencyInstallation':'target-npm-ci',
    'files':{name:{'sha256':hashlib.sha256(data).hexdigest(),'mode':mode,'sourcePath':source,'sourceMode':source_mode} for name,(data,mode,source,source_mode) in sorted(files.items())}}
digest=hashlib.sha256()
for data,mode,source,source_mode in sorted(files.values(),key=lambda item:item[2]):
    digest.update((source+'\0false\0'+str(source_mode)+'\0').encode()); digest.update(hashlib.sha256(data).digest())
if digest.hexdigest() != fingerprint:
    raise SystemExit('The requested fingerprint does not match the host source inputs.')
files['manifest.json'] = (json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()+b'\n',0o600,'',0)
stream = sys.stdout.buffer if output == '-' else open(output,'wb')
with gzip.GzipFile(filename='',mode='wb',fileobj=stream,mtime=0) as compressed:
    with tarfile.open(fileobj=compressed,mode='w',format=tarfile.USTAR_FORMAT) as archive:
        for name,(data,mode,source,source_mode) in sorted(files.items()):
            info=tarfile.TarInfo(name); info.size=len(data); info.mode=mode; info.mtime=0
            info.uid=info.gid=0; info.uname=info.gname=''
            archive.addfile(info,io.BytesIO(data))
if output != '-':
    stream.close()
PY
