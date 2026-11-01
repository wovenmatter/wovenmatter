"""A real, throwaway git repository standing in for the release source.

Release verification reads the app capability from the supplied source
revision with `git show`. Tests point release-assets.py's SOURCE here, so
they use genuine commits instead of a placeholder SHA and never depend on
the developer's checkout.
"""
import plistlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
GIT = ['git', '-c', 'user.name=Release fixture', '-c', 'user.email=release-fixture@example.invalid',
       '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main']


def make(directory, capabilities, uncommitted=None):
    """Commits app/App/Info.plist once per capability; returns their SHAs in order.
    `uncommitted` leaves a different value in the working tree."""
    directory = Path(directory)
    plist = directory / 'app/App/Info.plist'
    plist.parent.mkdir(parents=True)
    base = plistlib.loads((ROOT / 'app/App/Info.plist').read_bytes())
    subprocess.run(GIT + ['init', '-q', str(directory)], check=True)
    revisions = []
    for value in capabilities:
        plist.write_bytes(plistlib.dumps(dict(base, WovenMatterDeviceSetupVersion=value)))
        subprocess.run(GIT + ['-C', str(directory), 'add', 'app/App/Info.plist'], check=True)
        subprocess.run(GIT + ['-C', str(directory), 'commit', '-q', '-m', f'capability {value}'], check=True)
        revisions.append(subprocess.run(GIT + ['-C', str(directory), 'rev-parse', 'HEAD'], check=True,
                                        capture_output=True, text=True).stdout.strip())
    if uncommitted is not None:
        plist.write_bytes(plistlib.dumps(dict(base, WovenMatterDeviceSetupVersion=uncommitted)))
    return revisions
