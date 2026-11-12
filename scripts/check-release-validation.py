#!/usr/bin/env python3
"""Require passing Linux and desktop validation for a release's exact source.

Automatic PR CI never compiles the Linux library or the macOS app, so a release
must not start signing until manual validation (`validation.yml`) has passed
for the same source tree with scope `linux` and `desktop` (or `all`). A run on
a PR branch counts when its commit has the identical tree as the release
commit, so a validated, up-to-date PR does not need validating again after merge.

Trey can waive the requirement for one release: the annotated tag message then
carries a `Validation-waiver: <reason>` line.

usage: scripts/check-release-validation.py [--repo OWNER/NAME] [--tag vX.Y.Z] COMMIT_SHA
Read-only; it uses the existing GitHub CLI credentials.
"""
import argparse
import json
import re
import subprocess
import sys

REQUIRED = ('linux', 'desktop')
WORKFLOW = '.github/workflows/validation.yml'
TITLE = re.compile(r'^Manual validation \((all|desktop|mobile|images|linux)\)$')
WAIVER = re.compile(r'^Validation-waiver:\s*(\S.*)$', re.MULTILINE)


def covered(runs, tree):
    """Scopes that passed for `tree`, mapped to the run that proved each."""
    proof = {}
    for run in runs:
        title = TITLE.match(run.get('display_title') or '')
        if not title or run.get('conclusion') != 'success' or run.get('event') != 'workflow_dispatch':
            continue
        if run.get('path') != WORKFLOW or (run.get('head_commit') or {}).get('tree_id') != tree:
            continue
        scope = title.group(1)
        for required in REQUIRED:
            if scope in (required, 'all'):
                proof.setdefault(required, run)
    return proof


def waiver(message):
    found = WAIVER.search(message or '')
    return found.group(1).strip() if found else None


def gh(*arguments):
    return json.loads(subprocess.run(['gh', 'api', *arguments], check=True,
                                     capture_output=True, text=True).stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', default='wovenmatter/wovenmatter')
    parser.add_argument('--tag')
    parser.add_argument('commit')
    arguments = parser.parse_args(argv)
    repo, commit = arguments.repo, arguments.commit
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        parser.error('COMMIT_SHA must be a full 40-character SHA')

    tree = gh(f'repos/{repo}/git/commits/{commit}')['tree']['sha']
    runs = []
    for page in range(1, 4):
        listing = gh(f'repos/{repo}/actions/workflows/validation.yml/runs'
                     f'?event=workflow_dispatch&status=success&per_page=100&page={page}')
        runs.extend(listing.get('workflow_runs', []))
        if len(listing.get('workflow_runs', [])) < 100:
            break
    proof = covered(runs, tree)
    for scope in REQUIRED:
        if scope in proof:
            run = proof[scope]
            print(f'{scope}: passed in {run["html_url"]} ({run["head_branch"]} @ {run["head_sha"][:12]})')
    missing = [scope for scope in REQUIRED if scope not in proof]
    if not missing:
        print(f'Validation passed for {commit[:12]} (tree {tree[:12]}).')
        return 0

    if arguments.tag:
        ref = gh(f'repos/{repo}/git/ref/tags/{arguments.tag}')['object']
        if ref['type'] == 'tag':
            reason = waiver(gh(f'repos/{repo}/git/tags/{ref["sha"]}').get('message'))
            if reason:
                print(f'::warning::Validation waived for {arguments.tag}: {reason} (missing: {", ".join(missing)})')
                return 0
    print(f'::error::No passing manual validation for {", ".join(missing)} on {commit[:12]} '
          f'(tree {tree[:12]}). While main is at that commit, run:', file=sys.stderr)
    for scope in missing:
        print(f'  gh workflow run validation.yml --ref main -f scope={scope}', file=sys.stderr)
    print('then re-run this check. Only Trey can waive it, with a Validation-waiver: line '
          'in the annotated tag message.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
