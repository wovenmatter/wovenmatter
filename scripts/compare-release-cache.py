#!/usr/bin/env python3
"""Gate cache performance on two independent fresh-runner measurements."""
import datetime
import json
from pathlib import Path
import sys


def compare(records):
    if len(records) != 4:
        raise ValueError('Exactly four measurements are required')
    cold, *warm = sorted(records, key=lambda r: r['label'])
    if cold['label'] != 'cold' or {r['label'] for r in warm} != {'warm-1', 'warm-2', 'warm-edit'}:
        raise ValueError('One cold and three fresh-runner warm measurements are required')
    if any(r['status'] != 0 or r['revision'] != cold['revision'] or r['seconds'] <= 0 for r in records):
        raise ValueError('Builds must succeed at the same source revision')
    if not next(r for r in warm if r['label'] == 'warm-edit').get('source_edited'):
        raise ValueError('A controlled app-source edit must be measured')
    if cold['browser_reused']:
        raise ValueError('The baseline must have no browser product cache')
    for r in warm:
        if not r['browser_reused'] or r['replay_hits'] < 1:
            raise ValueError('Warm builds must demonstrate browser reuse and compiler replay hits')
        if r['seconds'] > cold['seconds'] * 0.8:
            raise ValueError('Each warm build must be at least 20% faster than cold')
    if all('runner_seconds' in r for r in records):
        for r in warm:
            if r['runner_seconds'] > cold['runner_seconds'] * 0.8:
                raise ValueError('Cache transfer/setup erased the required 20% practical speedup')
    return '\n'.join(f"{r['label']}: {r['seconds']:.1f}s ({(1-r['seconds']/cold['seconds'])*100:.1f}% faster)"
                     for r in warm)


if __name__ == '__main__':
    records = [json.loads(p.read_text()) for p in Path(sys.argv[1]).rglob('measurement.json')]
    if len(sys.argv) > 2:
        jobs = json.loads(Path(sys.argv[2]).read_text())['jobs']
        def timestamp(s):
            return datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
        for r in records:
            matches = [j for j in jobs if (j['name'].endswith('/ cold') if r['label'] == 'cold'
                       else j['name'].endswith('(' + r['label'] + ')'))]
            if len(matches) != 1:
                raise ValueError('Missing or ambiguous fresh-runner job timing')
            job = matches[0]
            step = next(s for s in job['steps'] if 'production-configuration compile' in s['name'])
            r['runner_seconds'] = (timestamp(step['completed_at']) - timestamp(job['started_at'])).total_seconds()
            print(f"{r['label']} runner setup + restore + build: {r['runner_seconds']:.0f}s")
    print(compare(records))
