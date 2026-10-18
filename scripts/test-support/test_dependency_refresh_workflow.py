"""Exercise the actual publisher with local Git and a fixture-only GitHub CLI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap

REPO = Path(__file__).resolve().parents[2]
workflow = (REPO / '.github/workflows/dependency-refresh.yml').read_text()
section = workflow.split('      - name: Publish the candidate branch and pull request\n', 1)[1]
publisher = textwrap.dedent(section.split('        run: |\n', 1)[1])


def run(args, cwd=None, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result


with tempfile.TemporaryDirectory(prefix='woven-dependency-workflow-') as temporary:
    root = Path(temporary)
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
               GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
               GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
    origin, base = root / 'origin.git', root / 'base'
    run(['git', 'init', '--quiet', '--bare', '--initial-branch=main', str(origin)], env=env)
    run(['git', 'init', '--quiet', '--initial-branch=main', str(base)], env=env)
    (base / 'record.txt').write_text('before\n')
    run(['git', 'add', '.'], cwd=base, env=env)
    run(['git', 'commit', '--quiet', '-m', 'Baseline'], cwd=base, env=env)
    run(['git', 'remote', 'add', 'origin', str(origin)], cwd=base, env=env)
    run(['git', 'push', '--quiet', 'origin', 'main'], cwd=base, env=env)
    (base / 'record.txt').write_text('after\n')
    patch = run(['git', 'diff', '--binary'], cwd=base, env=env).stdout

    state_path = root / 'state.json'
    state_path.write_text(json.dumps(dict(open_pr=False, dispatch_failures=1, dispatches=0,
                                         ci_shas=[], queries=[], query_failure=False)))
    binary = root / 'bin'
    binary.mkdir()
    fake_gh = binary / 'gh'
    fake_gh.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
path=Path(os.environ['TEST_GH_STATE']); state=json.loads(path.read_text()); args=sys.argv[1:]
code=0; output=''
if args[:2]==['pr','list']: output='1' if state['open_pr'] else ''
elif args[:2]==['pr','create']: state['open_pr']=True
elif args[:2]==['pr','edit']: pass
elif args[:2]==['run','list']:
    sha=args[args.index('--commit')+1]; state['queries'].append(sha)
    if state['query_failure']: code=73
    else: output=str(sum(value==sha for value in state['ci_shas']))
elif args[:2]==['workflow','run']:
    state['dispatches']+=1
    if state['dispatch_failures']:
        state['dispatch_failures']-=1; code=1
    else:
        sha=subprocess.check_output(['git','--git-dir',os.environ['TEST_ORIGIN'],'rev-parse','refs/heads/codex/dependency-refresh'],text=True).strip()
        state['ci_shas'].append(sha)
else: raise SystemExit('Unexpected fixture gh command: '+repr(args))
path.write_text(json.dumps(state)); print(output); raise SystemExit(code)
''')
    fake_gh.chmod(0o755)
    script = root / 'publisher.sh'
    script.write_text(publisher)
    env.update(PATH=str(binary) + os.pathsep + env['PATH'], TEST_GH_STATE=str(state_path),
               TEST_ORIGIN=str(origin), BRANCH='codex/dependency-refresh', BASE='main', GH_TOKEN='fixture-only')

    def attempt(number, proposal=patch):
        checkout, runner = root / ('checkout-' + str(number)), root / ('runner-' + str(number))
        run(['git', 'clone', '--quiet', '--branch', 'main', str(origin), str(checkout)], env=env)
        (runner / 'proposal').mkdir(parents=True)
        (runner / 'proposal/dependency.patch').write_text(proposal)
        (runner / 'proposal/dependency-report.md').write_text('Fixture dependency proposal.\n')
        attempt_env = dict(env, RUNNER_TEMP=str(runner), GITHUB_STEP_SUMMARY=str(runner / 'summary'), GITHUB_RUN_ID=str(number))
        return run(['bash', str(script)], cwd=checkout, env=attempt_env, check=False)

    def candidate():
        return run(['git', '--git-dir', str(origin), 'rev-parse', 'refs/heads/codex/dependency-refresh'], env=env).stdout.strip()

    first = attempt(1)
    assert first.returncode != 0, 'the failed CI dispatch must fail the workflow'
    original_candidate = candidate()
    assert json.loads(state_path.read_text())['open_pr'], 'the candidate PR exists before dispatch'
    second = attempt(2)
    assert second.returncode == 0, (second.stdout, second.stderr)
    state = json.loads(state_path.read_text())
    assert candidate() == original_candidate, 'a retry must reuse the actual published commit'
    assert state['dispatches'] == 2 and state['ci_shas'] == [original_candidate], state
    assert all(sha == original_candidate for sha in state['queries']), state
    third = attempt(3)
    assert third.returncode == 0, (third.stdout, third.stderr)
    assert json.loads(state_path.read_text())['dispatches'] == 2, 'an existing CI run must not be rerun daily'

    state = json.loads(state_path.read_text())
    state['query_failure'] = True
    state_path.write_text(json.dumps(state))
    failed_query = attempt(4)
    assert failed_query.returncode == 73, 'GitHub query errors must stop the workflow'
    assert json.loads(state_path.read_text())['dispatches'] == 2

    before = state_path.read_text()
    forbidden = '''diff --git a/.github/workflows/forbidden.yml b/.github/workflows/forbidden.yml
new file mode 100644
--- /dev/null
+++ b/.github/workflows/forbidden.yml
@@ -0,0 +1 @@
+forbidden
'''
    rejected = attempt(5, forbidden)
    assert rejected.returncode != 0 and 'must not edit workflows' in rejected.stderr, (rejected.stdout, rejected.stderr)
    assert state_path.read_text() == before and candidate() == original_candidate, 'forbidden paths must be rejected before any publication'

print('Dependency proposal workflow passed: failed-dispatch retry, exact commit reuse, no duplicate CI, query failures, and forbidden workflow paths.')
