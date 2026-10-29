"""Reject misleading or incomplete cache performance claims."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('compare', Path(__file__).resolve().parents[1] / 'compare-release-cache.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cold = dict(label='cold', seconds=900, status=0, revision='same', replay_hits=0, replay_misses=100, browser_reused=False)
warm = [dict(cold, label=label, seconds=300, replay_hits=80, browser_reused=True) for label in ('warm-1', 'warm-2', 'warm-edit')]
warm[2]['source_edited'] = True
assert '66.7% faster' in module.compare([cold, *warm])
def rejects(records):
    try:
        module.compare(records)
    except (ValueError, IndexError):
        return
    raise AssertionError('Invalid measurements accepted')
rejects([cold, warm[0]])
rejects([cold, *warm, warm[0]])
rejects([cold, warm[0], warm[1], dict(warm[2], source_edited=False)])
rejects([dict(cold, browser_reused=True), *warm])
for change in (dict(seconds=850), dict(status=1), dict(revision='other'), dict(browser_reused=False), dict(replay_hits=0)):
    rejects([cold, warm[0], dict(warm[1], **change), warm[2]])
rejects([dict(cold, runner_seconds=950), dict(warm[0], runner_seconds=900), dict(warm[1], runner_seconds=400), dict(warm[2], runner_seconds=400)])
print('Cache measurement gates reject a slow warm build, missing reuse, failed/mismatched builds and incomplete evidence.')

workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/release.yml').read_text()
benchmark = workflow.split('\n  cache-benchmark:', 1)[1]
assert 'contents: read' in benchmark and 'cache/save@' not in benchmark
assert 'notarytool' not in benchmark and 'SPARKLE_PRIVATE_KEY' not in benchmark
assert 'gh release' not in benchmark and 'stage-update.py' not in benchmark
assert 'scripts/build-release.sh 0.0.1 compile' in benchmark
assert '.conclusion == "success" and .head_branch == "main"' in benchmark

assert "git merge-base --is-ancestor HEAD origin/main" in benchmark
assert "refs/tags/v-cache-benchmark-" in benchmark
