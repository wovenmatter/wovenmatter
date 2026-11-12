"""Releases start only from source that passed Linux and desktop validation."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gate', ROOT / 'scripts/check-release-validation.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def run(scope, tree='tree-a', conclusion='success', event='workflow_dispatch',
        path='.github/workflows/validation.yml'):
    return {'display_title': f'Manual validation ({scope})', 'conclusion': conclusion, 'event': event,
            'path': path, 'head_commit': {'tree_id': tree}, 'head_sha': 'f' * 40}


assert set(module.covered([run('all')], 'tree-a')) == {'linux', 'desktop'}
assert set(module.covered([run('linux'), run('desktop')], 'tree-a')) == {'linux', 'desktop'}
assert set(module.covered([run('linux')], 'tree-a')) == {'linux'}
# Other scopes, other source trees, failures and other events prove nothing.
assert module.covered([run('mobile'), run('images')], 'tree-a') == {}
assert module.covered([run('all', tree='tree-b')], 'tree-a') == {}
assert module.covered([run('all', conclusion='failure')], 'tree-a') == {}
assert module.covered([run('all', event='push')], 'tree-a') == {}
assert module.covered([run('all', path='.github/workflows/ci.yml')], 'tree-a') == {}
# Runs from before validation runs were titled by scope don't say what they covered.
assert module.covered([{**run('all'), 'display_title': 'Manual validation'}], 'tree-a') == {}

assert module.waiver('v1.2.3\n\nValidation-waiver: desktop runner outage, Trey approved\n') == \
    'desktop runner outage, Trey approved'
assert module.waiver('v1.2.3\n') is None
assert module.waiver('Validation-waiver:   \n') is None

# validation.yml titles each run by scope, which is what the gate reads.
workflow = (ROOT / '.github/workflows/validation.yml').read_text()
assert 'run-name: Manual validation (${{ inputs.scope }})' in workflow
# The tag-triggered release refuses to start before the gate passes.
release = (ROOT / '.github/workflows/release.yml').read_text()
assert 'scripts/check-release-validation.py' in release
assert 'needs: preflight' in release
print('Release validation gate tests passed.')
