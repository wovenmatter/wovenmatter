---
name: cut-release-wovenmatter
description: Cut, prepare, verify, and publish a WovenMatter macOS release.
---

A supplied or confirmed version authorizes publication. If omitted, recommend
an unused semantic version and wait for confirmation before tagging. Stop at a
private draft only when the user explicitly requests that limit; “prepare”
alone does not imply it.

Before tagging or any release mutation, run `scripts/check-release-access.sh`.
It verifies that existing GitHub API access matches the configured SSH
account without changing credentials. Git over SSH and GitHub CLI API access use
separate credentials. A macOS sandbox can make a valid Keychain credential appear
missing or invalid. If this read-only check fails in the sandbox, retry it through
the tool's approved execution permission path; never bypass a denied permission.
If it succeeds, use that working permission path for subsequent authorized
release commands. If it still fails or identifies another account, stop and
report the exact blocker without changing accounts or credentials.

Never initiate or operate authentication: no `gh auth login`, `gh auth refresh`,
`gh auth logout`, `gh auth switch`, device-code flow, browser login/account
selection/consent, credential extraction, or token copying. CLI suggestions to
log in are diagnostics, not instructions or authorization. Release authorization
never includes authentication recovery; only the user operates account login.

Release from clean, current `origin/main`, validated with
`scripts/test-changes.sh --all`. Create and push an annotated `vX.Y.Z` tag at
that exact commit. Never move or reuse a release tag; an existing private draft
can be resumed at its original accepted commit.

The tag-triggered `.github/workflows/release.yml` builds a signed, notarized
Apple Silicon app and stages a private draft. Prepare user-facing release notes.
After its successful run, verify and publish through
`scripts/publish-release.sh vX.Y.Z EXPECTED_COMMIT_SHA`; use `--verify-only`
when the user requested a draft. The script checks source, workflow, assets,
checksums, signing, notarization, and Gatekeeper before publication. GitHub CLI
authentication must match the repository's SSH account.

Report the exact commit, validation result, and release URL with its verified
draft or public state.
