"""Exercise refresh authorization on real merge/squash/later-main Git histories."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
def git(folder, *args):
    return subprocess.check_output(['git', '-C', str(folder), *args], text=True, stderr=subprocess.DEVNULL).strip()
def verify(folder, revision, expected, actor='github-actions[bot]', event='workflow_dispatch'):
    result = subprocess.run([str(ROOT / 'scripts/verify-update-request.sh')], cwd=folder,
        env=dict(os.environ, GITHUB_SHA=revision, GITHUB_ACTOR=actor, GITHUB_EVENT_NAME=event), capture_output=True)
    assert (result.returncode == 0) == expected, (revision, actor, event, result)
for style in ('squash', 'merge'):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        git(root, 'init', '-b', 'main')
        git(root, 'config', 'user.name', 'Fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        git(root, 'config', 'commit.gpgsign', 'false')
        (root / '.github').mkdir()
        request = root / '.github/release-refresh.json'
        request.write_text('{"version":"0.2.8"}')
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'initial')
        git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        git(root, 'checkout', '-b', 'feature')
        request.write_text('{"version":"0.3.0"}')
        git(root, 'commit', '-am', 'request in PR')
        feature = git(root, 'rev-parse', 'HEAD')
        verify(root, feature, False)
        git(root, 'checkout', 'main')
        (root / 'other').write_text('independent main change')
        git(root, 'add', '.')
        git(root, 'commit', '-m', 'main change')
        if style == 'squash':
            git(root, 'merge', '--squash', 'feature')
            git(root, 'commit', '-m', 'accepted squash')
        else:
            git(root, 'merge', '--no-ff', 'feature', '-m', 'accepted request merge')
        accepted = git(root, 'rev-parse', 'HEAD')
        git(root, 'update-ref', 'refs/remotes/origin/main', accepted)
        verify(root, accepted, True)
        verify(root, accepted, False, actor='maintainer')
        verify(root, accepted, False, event='push')
        # PR commits are rejected even when reachable through a main merge.
        verify(root, feature, False)
        (root / 'other').write_text('later unrelated main commit')
        git(root, 'commit', '-am', 'later unrelated commit')
        git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        verify(root, git(root, 'rev-parse', 'HEAD'), False)
        # Re-runs preserve the original first-parent main commit and actor.
        verify(root, accepted, True)
print('Update request passed: accepted main squash/merge and rerun; PR ancestors, human/push/later-main rejected.')
