---
name: cut-release-wovenmatter
description: Cut and stage a WovenMatter macOS release from exact main when Trey asks to cut, prepare, tag, or release a version. Suggest and confirm an unused semantic version when none is supplied, verify the signed draft, and always leave final publication to Trey.
---

# Cut Release WovenMatter

Use this workflow only in the WovenMatter repository. Its completed agent
outcome is a verified private GitHub Release draft plus a precise publication
handoff to Trey. A public release is never an agent-completed action.

## Non-negotiable boundary

- Treat an explicit unused version in the user's release request as version
  confirmation. If the request does not include a version, inspect the changes,
  propose the next semantic version, and wait for explicit confirmation before
  creating or pushing a tag.
- Never run the `Publish Release` workflow, click GitHub's publish control, call
  `gh release edit --draft=false`, or otherwise make a release public. This
  remains true even when the user says "release" rather than "stage."
- Never reuse, move, force-push, or delete an existing tag or release. If the
  requested version exists locally or remotely as a tag, draft, or published
  release, stop and report the collision.
- Keep source acceptance, validation, tagging, draft creation, artifact
  verification, and public publication as separate reported states.

## 1. Establish exact release source

1. Require a clean working tree. Do not stash, discard, commit, or overwrite
   unrelated work.
2. Switch to `main`, fetch `origin` and tags, and fast-forward only from
   `origin/main`.
3. Prove `main...origin/main` is `0 0` and record the full release commit SHA.
4. Confirm the remote uses the repository-configured SSH identity. Never use or
   suggest the GitHub connector.
5. Read `docs/MAINTAINER_WORKFLOW.md` and the current release workflows before
   acting. Stop if they no longer preserve the private-draft and Trey-only
   publication boundary.

## 2. Select and confirm the version

Inspect the newest published semantic version, all local and remote tags, any
existing draft, and the commits since the newest release. Do not infer the next
version from tags alone.

When the user omitted the version, recommend one using the change's public
compatibility impact:

- Patch (`X.Y.Z+1`) for small compatible fixes and refinements.
- Minor (`X.Y+1.0`) for meaningful backward-compatible capabilities.
- Major (`X+1.0.0`) for intentionally incompatible public behavior.

Explain the recommendation briefly and wait for the user to confirm the exact
version. Do not introduce prerelease identifiers unless the user asks for one.
After confirmation, prove both `vX.Y.Z` and its GitHub Release are unused.

## 3. Validate and stage

1. Run `scripts/test-changes.sh --all`. Run `scripts/test-container.sh` only
   when container lifecycle coverage is in scope and Docker is available.
2. Summarize the user-visible changes since the previous published release and
   prepare concise release notes.
3. Recheck that `HEAD` is the recorded clean exact-main SHA, then create
   `vX.Y.Z` at that SHA and push only that tag to `origin`.
4. The tag-triggered `Release` workflow must build, sign, notarize, validate,
   and stage a private draft. Wait for it to finish. A successful workflow is
   not itself publication.
5. Verify the draft remains private and contains exactly:
   - `WovenMatter_X.Y.Z_arm64.dmg`
   - `SHA256SUMS.txt`
   - `latest-mac.json`
6. Verify the manifest's version, build, architecture, minimum macOS, URLs, and
   SHA-256; verify the DMG checksum and the workflow's signing, notarization,
   stapling, and Gatekeeper evidence. Do not substitute a Dev or unsigned local
   build. If authenticated draft inspection is unavailable, report that as a
   blocker rather than claiming the draft is ready.

## 4. Hand publication to Trey

Return the draft URL, tag, exact commit, validation result, and artifact proof.
Then provide this Actions page:

`https://github.com/wovenmatter/wovenmatter/actions/workflows/publish-release.yml`

Tell Trey to run `Publish Release` as `trey131` with:

- `tag`: `vX.Y.Z`
- `confirmation`: `publish vX.Y.Z`

Stop there. Do not dispatch, approve, or monitor the publication workflow unless
the user later asks only for read-only status verification.
