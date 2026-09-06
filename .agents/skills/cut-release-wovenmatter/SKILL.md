---
name: cut-release-wovenmatter
description: Cut, prepare, verify, and publish a WovenMatter macOS release.
---

A supplied or confirmed version authorizes publication. If omitted, recommend
an unused semantic version and wait for confirmation before tagging. Stop at a
private draft only when the user explicitly requests that limit; “prepare”
alone does not imply it.

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
