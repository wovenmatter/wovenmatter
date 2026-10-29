#!/usr/bin/env python3
"""Gate cache performance on two independent fresh-runner measurements."""
import json
from pathlib import Path
import sys


def compare(records):
    cold, *warm = sorted(records, key=lambda r: r['label'])
    if cold['label'] != 'cold' or {r['label'] for r in warm} != {'warm-1', 'warm-2'}:
        raise ValueError('One cold and two fresh-runner warm measurements are required')
    if any(r['status'] != 0 or r['revision'] != cold['revision'] or r['seconds'] <= 0 for r in records):
        raise ValueError('Builds must succeed at the same source revision')
    if cold['browser_reused']:
        raise ValueError('The baseline must have no browser product cache')
    for r in warm:
        if not r['browser_reused'] or r['replay_hits'] < 1:
            raise ValueError('Warm builds must demonstrate browser reuse and compiler replay hits')
        if r['seconds'] > cold['seconds'] * 0.8:
            raise ValueError('Each warm build must be at least 20% faster than cold')
    return '\n'.join(f"{r['label']}: {r['seconds']:.1f}s ({(1-r['seconds']/cold['seconds'])*100:.1f}% faster)"
                     for r in warm)


if __name__ == '__main__':
    records = [json.loads(p.read_text()) for p in Path(sys.argv[1]).rglob('measurement.json')]
    print(compare(records))
