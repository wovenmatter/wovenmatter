#!/usr/bin/env python3
"""Content-addressed downloads; every cache hit is verified against a source pin."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


def download(url, algorithm, expected, cache):
    if algorithm not in ('sha1', 'sha256') or len(expected) != hashlib.new(algorithm).digest_size * 2:
        raise ValueError('Invalid archive digest')
    if any(c not in '0123456789abcdef' for c in expected):
        raise ValueError('Invalid archive digest')
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / f'{algorithm}-{expected}'
    def valid(path):
        if not path.is_file() or path.is_symlink():
            return False
        h = hashlib.new(algorithm)
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
        return h.hexdigest() == expected
    if valid(destination):
        os.utime(destination)  # Marks a current pin for the cache producer's pruning.
        return destination
    destination.unlink(missing_ok=True)
    fd, name = tempfile.mkstemp(prefix='.download-', dir=cache)
    os.close(fd)
    temporary = Path(name)
    try:
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--silent', '--show-error', url, '-o', name], check=True)
        if not valid(temporary):
            raise ValueError('Downloaded archive checksum mismatch')
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('algorithm')
    parser.add_argument('digest')
    args = parser.parse_args()
    root = Path(os.environ.get('WOVENMATTER_DOWNLOAD_CACHE', str(Path.home() / 'Library/Caches/WovenMatter/Downloads')))
    print(download(args.url, args.algorithm, args.digest, root))
