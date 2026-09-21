---
name: cut-release-wovenmatter
description: Cut, prepare, verify, and publish a WovenMatter macOS release.
---

A supplied or confirmed version authorizes building and verifying a private draft,
not publication. If omitted, recommend an unused semantic version and wait for
confirmation before tagging. Always pause for Trey's explicit manual approval
of the exact release description before publishing. A release request, version
confirmation, or approval of a previous release is not description approval.

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
Apple Silicon app and stages a private draft. After its successful run, verify
through `scripts/publish-release.sh --verify-only vX.Y.Z EXPECTED_COMMIT_SHA`.
The script checks source, workflow, assets, checksums, signing, notarization,
and Gatekeeper. GitHub CLI authentication must match the repository's SSH account.

Then write the release description from the material changes since the previous
public release. Inspect the complete commit/PR range and underlying changes;
do not simply repeat commit titles. Use this structure for every release:

1. A short opening explanation of the release and its biggest changes.
2. The README-style download badge directly below the opening paragraph.
3. **New capabilities** — bullet points describing major new features.
4. **Improvements and fixes** — bullet points describing noticeable improvements
   and meaningful fixes.
5. A **Full changelog** link comparing the previous release tag with the new tag.
6. **How to update** — the final section, using this exact copy:
   "Go to Settings > General to check for and install the update."

Use the same badge image, label, and Apple logo as the README, but link directly
to this release's DMG, never `/releases/latest`. For version `X.Y.Z`:

```markdown
[![Download Woven Matter for Apple silicon](https://img.shields.io/badge/Download-Woven_Matter_for_Apple_silicon-000000?logo=apple&logoColor=white)](https://github.com/wovenmatter/wovenmatter/releases/download/vX.Y.Z/WovenMatter_X.Y.Z_arm64.dmg)
```

Verify the link matches an asset on the release. Include the badge in the full
description presented for approval. An explicitly requested description edit to
an already-published release can use `gh release edit --notes-file`; it does not
require rebuilding or changing the tag or assets.

Write in plain, natural language and say concretely what users can now do or
what works better. Keep implementation details out unless they materially affect
users. Do not claim unverified functionality or pad the notes with internal
maintenance. If a change requires an upgrade action, explain it in the relevant
feature or improvement bullet; keep the final update instructions consistent.
Distinguish agent tools from conversation permissions instead of referring to
both with an ambiguous phrase such as "Full access."

Save the description in a UTF-8 Markdown file and update the private draft with
`gh release edit vX.Y.Z --notes-file /absolute/path/to/notes.md`. Present the full
description to Trey along with the exact commit, validation result, and draft
URL. Stop and wait for his explicit approval; leave the release private. Apply
requested edits and show the revised description for approval. Any later change
to the description or release commit requires fresh approval.

Only after approval, publish with
`scripts/publish-release.sh --approved-notes /absolute/path/to/notes.md vX.Y.Z EXPECTED_COMMIT_SHA`.
This option attests that Trey approved that exact description for this release;
never supply it preemptively. The script publishes the supplied text and repeats
artifact verification. Its default invocation only verifies and leaves the draft
private. Never bypass this gate with direct GitHub publication commands.

Report the exact commit, validation result, and release URL with its verified
public state after publication.
