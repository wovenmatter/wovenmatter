"""Reject misleading or incomplete cache performance claims."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('compare', Path(__file__).resolve().parents[1] / 'compare-release-cache.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cold = dict(label='cold', seconds=900, status=0, revision='same', replay_hits=0, replay_misses=100, browser_reused=False)
warm = [dict(cold, label=label, seconds=300, replay_hits=80, browser_reused=True) for label in ('warm-1', 'warm-2')]
assert '66.7% faster' in module.compare([cold, *warm])
def rejects(records):
    try:
        module.compare(records)
    except (ValueError, IndexError):
        return
    raise AssertionError('Invalid measurements accepted')
rejects([cold, warm[0]])
rejects([dict(cold, browser_reused=True), *warm])
for change in (dict(seconds=850), dict(status=1), dict(revision='other'), dict(browser_reused=False), dict(replay_hits=0)):
    rejects([cold, warm[0], dict(warm[1], **change)])
print('Cache measurement gates reject a slow warm build, missing reuse, failed/mismatched builds and incomplete evidence.')
