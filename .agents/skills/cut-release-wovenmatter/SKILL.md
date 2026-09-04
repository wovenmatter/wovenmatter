---
name: cut-release-wovenmatter
description: Cut, verify, and publish a WovenMatter macOS release from exact main when Trey asks to cut, prepare, tag, or release a version. Suggest and confirm an unused semantic version when none is supplied; stop at a private draft only when explicitly requested.
---

# Cut Release WovenMatter

Use this workflow only in the WovenMatter repository. A supplied or confirmed
version authorizes the complete release: exact source, validation, immutable
tag, signed private draft, artifact verification, and public publication. Do
not ask Trey to operate a browser or GitHub Actions form.

## Authorization and immutable state

- Treat an explicit version in a release request as confirmation to tag and
  publish. If no version is supplied, inspect the changes, propose the next
  semantic version, and wait for confirmation before creating a tag.
- If Trey explicitly says `stage`, `prepare`, `draft`, or `do not publish`, stop
  after verifying the private draft.
- Never reuse, move, force-push, or delete a tag or replace a published release.
- A matching existing private draft may be resumed after an interrupted release
  only when its immutable tag, exact commit, successful Release workflow, and
  artifacts all pass the same checks as a newly staged draft. Do not recreate or
  re-upload it.
- Report validation, tagging, draft staging, artifact verification, and public
  publication as distinct states.

## 1. Establish exact release source

1. Require a clean working tree. Do not stash, discard, commit, or overwrite
   unrelated work.
2. Switch to `main`, fetch `origin` and tags, and fast-forward only from
   `origin/main`.
3. Prove `main...origin/main` is `0 0` and record the full release commit SHA.
4. Confirm both remote URLs use the repository-configured GitHub SSH identity.
   Verify GitHub CLI access outside the sandbox and ensure its authenticated
   account matches the account encoded in that SSH host alias before treating
   an authentication check as failed. Never use or suggest the GitHub connector
   or browser.
5. Read `docs/MAINTAINER_WORKFLOW.md`, `.github/workflows/release.yml`, and
   `scripts/publish-release.sh`. Stop if tagging can publish directly or if the
   guarded script no longer verifies before publication.

For a resumed private draft, record the tag's existing commit instead of moving
it. Prove that commit is on `origin/main` and use it as the expected release SHA.

## 2. Select and confirm the version

Inspect the newest published semantic version, all local and remote tags, any
existing draft, and the commits since the newest release. Do not infer the next
version from tags alone.

When the user omitted the version, recommend one using the change's public
compatibility impact:

- Patch (`X.Y.Z+1`) for small compatible fixes and refinements.
- Minor (`X.Y+1.0`) for meaningful backward-compatible capabilities.
- Major (`X+1.0.0`) for intentionally incompatible public behavior.

Explain the recommendation briefly and wait for the exact version. Do not
introduce prerelease identifiers unless the user asks for one. For a new
release, prove the tag and GitHub Release are unused. For a resumed draft, prove
there is exactly one matching private draft and no published release.

## 3. Validate and stage

For a new release:

1. Run `scripts/test-changes.sh --all`. Run `scripts/test-container.sh` only when
   container lifecycle coverage is in scope and Docker is available.
2. Prepare concise release notes from the user-visible changes since the last
   published release.
3. Recheck that `HEAD` is the recorded clean exact-main SHA. Create annotated
   tag `vX.Y.Z` at that SHA and push only that tag to `origin`.
4. Wait for the exact tag-triggered `Release` workflow. It must build, sign,
   notarize, validate, and stage a private draft; it must not publish.

For a new or resumed draft, verify it remains private and contains exactly:

- `WovenMatter_X.Y.Z_arm64.dmg`
- `SHA256SUMS.txt`
- `latest-mac.json`

Verify the manifest version, build, architecture, minimum macOS, URLs, and
SHA-256; check the DMG and manifest against `SHA256SUMS.txt`; and independently
verify the downloaded DMG's Developer ID signature, notarization ticket, and
Gatekeeper acceptance. Confirm the successful Release run belongs to the exact
tag commit. Update the private draft with the prepared notes when needed.

## 4. Publish and prove the result

Unless Trey explicitly requested a private draft only, run:

```sh
scripts/publish-release.sh vX.Y.Z EXPECTED_COMMIT_SHA
```

Run it with authenticated host access so `gh` and the configured SSH identity
use the same account; do not interpret a sandbox credential failure as invalid
auth. The script repeats the immutable-source, workflow, draft, asset,
manifest, checksum, signature, notarization, and Gatekeeper checks before
changing the draft state.

After it succeeds, verify the release is public, its canonical URL is
`https://github.com/wovenmatter/wovenmatter/releases/tag/vX.Y.Z`, and the three
public assets resolve. Return the tag, exact commit, validation and artifact
proof, Release workflow URL, and public release URL. Publication completes the
skill; do not hand a final action back to Trey.
