#!/usr/bin/env python3
"""Stage the recorded, upstream-signed Cua executable; never run an installer."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def extract_driver(archive, destination, record):
    if archive.stat().st_size != record['archiveBytes']:
        raise ValueError('Cua archive size mismatch')
    digest = sha256(archive)
    if digest != record['archiveSHA256']:
        raise ValueError('Cua archive checksum mismatch')
    with tarfile.open(archive, 'r:gz') as bundle:
        candidates = [member for member in bundle.getmembers() if member.name == 'cua-driver']
        if len(candidates) != 1 or not candidates[0].isfile() or candidates[0].size > 512 * 1024 * 1024:
            raise ValueError('Cua archive must contain one regular cua-driver executable')
        # Never extract paths, symlinks, SDK libraries, or authoring tools.
        with bundle.extractfile(candidates[0]) as source, destination.open('wb') as target:
            shutil.copyfileobj(source, target)
    if sha256(destination) != record['binarySHA256']:
        raise ValueError('Cua executable checksum mismatch')
    destination.chmod(0o755)


def main(output):
    record = json.loads((ROOT / 'app/Automation/cua-version.json').read_text())
    spec = importlib.util.spec_from_file_location('cached_download', ROOT / 'scripts/cached-download.py')
    downloads = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(downloads)
    cache = Path(os.environ.get('WOVENMATTER_DOWNLOAD_CACHE', str(Path.home() / 'Library/Caches/WovenMatter/Downloads')))
    archive = downloads.download(record['url'], 'sha256', record['archiveSHA256'], cache)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cua-stage-', dir=output.parent) as temporary:
        binary = Path(temporary) / 'cua-driver'
        extract_driver(archive, binary, record)
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
        signature = subprocess.run(['codesign', '-dvv', str(binary)], check=True, capture_output=True, text=True).stderr
        if 'TeamIdentifier=' + record['teamIdentifier'] not in signature:
            raise ValueError('Unexpected Cua signing team')
        architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        if set(architectures) != {'arm64', 'x86_64'}:
            raise ValueError('Cua must support both Mac architectures')
        os.replace(binary, output / 'cua-driver')
    shutil.copy2(ROOT / 'app/Automation/cua-version.json', output / 'cua-version.json')
    shutil.copy2(ROOT / 'app/Automation/CUA-LICENSE.txt', output / 'LICENSE.txt')
    shutil.copy2(ROOT / 'app/Automation/CUA-THIRD-PARTY-NOTICES.md', output / 'THIRD-PARTY-NOTICES.md')


if __name__ == '__main__':
    main(Path(sys.argv[1]))
