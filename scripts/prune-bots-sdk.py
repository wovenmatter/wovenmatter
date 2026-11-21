#!/usr/bin/env python3
"""Removes the bots runtime's own copy of Pi Durable's SDK from an installed bots/node_modules.

Bots load the SDK copy the machine's Pi Durable runs (`bots/src/pi-durable-sdk.ts`), so the
packages Pi Durable's SDK update installs, and whatever only they depend on, are never loaded
from bots/node_modules. This keeps every package that bots' other dependencies reach, by the
committed lockfile's graph and Node's resolution, and deletes the rest. Usage:
prune-bots-sdk.py <bots directory>
"""
import json, shutil, sys
from pathlib import Path

# The packages Pi Durable's SDK update (`default-agent/src/sdk.mjs`) installs (bots use all but pi-coding-agent).
SDK = {'@earendil-works/pi-durable', '@earendil-works/pi-ai', '@earendil-works/pi-coding-agent',
       '@earendil-works/chord', '@anthropic-ai/claude-agent-sdk'}


def is_sdk(name):
    return name in SDK or name.startswith('@anthropic-ai/claude-agent-sdk-')


def resolve(packages, parent, name):
    """The lockfile key Node would load `name` from, imported by the package at `parent`."""
    base = parent
    while True:
        key = (base + '/' if base else '') + 'node_modules/' + name
        if key in packages:
            return key
        if not base:
            return None
        cut = base.rfind('/node_modules/')
        base = base[:cut] if cut >= 0 else ''


def kept(lock):
    packages = lock['packages']
    root = packages.get('', {})
    pending = [(None, name) for name in {**root.get('dependencies', {}), **root.get('optionalDependencies', {})} if not is_sdk(name)]
    reached = set()
    while pending:
        parent, name = pending.pop()
        key = resolve(packages, parent or '', name)
        if key is None or key in reached:
            continue
        reached.add(key)
        entry = packages[key]
        for field in ('dependencies', 'optionalDependencies', 'peerDependencies'):
            pending.extend((key, child) for child in entry.get(field, {}))
    return reached


def prune(bots):
    bots = Path(bots)
    lock = json.loads((bots / 'package-lock.json').read_text())
    keep = kept(lock)
    removed = []
    # Deepest first, so a removed package's nested node_modules goes with it.
    for key in sorted((k for k in lock['packages'] if k.startswith('node_modules/')), key=len, reverse=True):
        if key in keep:
            continue
        path = bots / key
        if path.is_symlink() or not path.exists():
            continue
        shutil.rmtree(path)
        removed.append(key)
    modules = bots / 'node_modules'
    for scope in modules.glob('@*'):
        if scope.is_dir() and not scope.is_symlink() and not any(scope.iterdir()):
            scope.rmdir()
    bin_dir = modules / '.bin'
    if bin_dir.is_dir():
        for link in bin_dir.iterdir():
            if link.is_symlink() and not link.exists():
                link.unlink()
    for name in SDK:
        if (modules / name).exists():
            raise SystemExit('The bots runtime still carries ' + name + '.')
    return removed


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: prune-bots-sdk.py <bots directory>')
    prune(sys.argv[1])
