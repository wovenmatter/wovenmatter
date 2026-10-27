# Maintainer workflow

## Validation

`scripts/test-changes.sh --all` runs deterministic checks and an unsigned macOS
build. Use `--macos` or `--remote` for focused validation.
Container lifecycle changes also use `scripts/test-container.sh` when Docker is
available. Tests use temporary data and must not consume provider services.

Every PR runs one Linux **CI** check: public-tree and syntax checks, then portable
fixtures, agent/service tests and generated-resource verification selected by
changed paths. JavaScript tests run once on Linux. Use
`scripts/test-changes.sh --ci` for the same selection locally, or
`scripts/test-ci.sh --all` for all portable suites.

New PR commits cancel obsolete CI runs. Merges to main do not repeat CI, and
there is no separate detector or aggregate gate job. Swift-only changes receive
repository scans and infrastructure checks; automatic CI does not establish native
compilation, simulator acceptance, container isolation or image security results.

Run **Manual validation** (`validation.yml`) explicitly on the desired branch:

| Scope | Validation |
| --- | --- |
| `desktop` | Native macOS fixtures, package tests, unsigned app build, embedded WebKit smoke, companion integration and signed delta round trip |
| `mobile` | iPhone and iPad package/app/UI tests on disposable simulators |
| `images` | amd64/arm64 workspace and Executor images, isolation, native helpers, permissions/cancellation and vulnerability inventory |
| `all` (default) | All portable suites plus every platform check above |

For example, `gh workflow run validation.yml --ref BRANCH -f scope=desktop`
requests desktop validation. Platform validation runs without provider or
signing credentials; it does not install, release or publish an app. Build
intermediates use toolchain/dependency-specific caches. Release dependency/compiler
warming is also manual through **Prepare release dependencies** on main; releases
can build from a cache miss.

The embedded Python smoke uses the production WebKit executor with no visible
web view. Its inactive scheduling policy must keep the worker running until
teardown; a detached view can otherwise suspend before initialization and hit
the 90-second watchdog. Linux credential-storage tests inject filesystem probes
for rejection cases, then exercise real tmpfs storage separately. Never assume
`/tmp` is disk-backed; Ubuntu runners may mount it as tmpfs.

`scripts/test-ios.sh` creates and boots disposable simulators and waits for first
boot before XCTest runs. When the selected Xcode includes standalone Simulator,
it launches an owned display process and terminates it after testing. Xcode 27's
Device Hub toolchain leaves display management to XCTest. Cleanup deletes only
devices created by the runner; existing Simulator instances remain untouched. An explicit
`WOVENMATTER_IOS_SIMULATOR_DESTINATION` remains caller-owned. Each invocation
writes a unique `results.*/TestResults.xcresult` and `xcodebuild.log` under
`WOVENMATTER_IOS_TEST_CACHE_DIR`. CI retains these results for seven days, plus
desktop logs and the embedded-runtime report on desktop failure. Log pipelines
must preserve failure status (`shell: bash` in Actions or `set -o pipefail`).
Validation uses disposable GitHub-hosted runners without provider, signing, or
deployment credentials. The explicitly requested author-label workflow inspects
only GitHub metadata; it does not check out or execute contributor code.

## Contributions

Pull requests target `main`; code-owner approval is the merge gate. The PR Author
workflow runs only when someone comments exactly `/recheck-author` on a PR; it
does not add an automatic check on open, reopen or pushed commits. Use that
command to request classification, including after organization membership changes. The
recheck fetches the PR author's current metadata rather than classifying the
commenter. Existing PRs can be rechecked individually after this workflow lands.

`author:organization` means GitHub reports the PR author's association as `MEMBER`
or `OWNER` in this organization-owned repository, or the public organization
membership endpoint positively verifies membership. This includes owners and
agent accounts when their membership is verified. Collaborator permissions, bot
status, and usernames are never sufficient on their own.

`author:external-or-unverified` flags outside contributors and any author whose
membership cannot be established for heavier review. The repository-scoped
`GITHUB_TOKEN` cannot request the organization-level Members permission needed
for authoritative private membership API checks. The public endpoint's `404`
does not rule out private membership; lookup errors also keep the heavier-review
flag. Private membership reported by GitHub as `MEMBER` is accepted; otherwise it
remains unverified. No additional credentials or token scopes are required.
See GitHub's [author association values](https://docs.github.com/en/graphql/reference/issues#commentauthorassociation)
and [organization membership API](https://docs.github.com/en/rest/orgs/members#check-organization-membership-for-a-user).

Author labels do not grant access or bypass code-owner review, branch protections,
or required checks. The vouch action and trust list and the PR Size workflow are
removed. On classification or recheck, obsolete vouch and size labels are removed
from that PR; historical repository labels are not globally deleted.

## Builds and releases

`scripts/build_and_run.sh` builds and launches the development app, using an
existing Apple Development identity when available. See [credential access](KEYCHAIN_ACCESS.md#development-builds)
for identity selection and the ad-hoc fallback. Deterministic validation builds
remain unsigned. Production releases are signed, notarized Apple Silicon builds from an exact
accepted commit. Release, installation, deployment, and publication require an
explicit request; they are separate from deterministic validation.

Use `.agents/skills/cut-release-wovenmatter/SKILL.md` for the release procedure.
Before tagging, run `scripts/check-release-access.sh` to verify existing GitHub
API access matching the configured SSH account. SSH and GitHub CLI API
credentials are separate. A sandbox can make a valid macOS Keychain credential
appear unavailable or invalid; retry this read-only check through the approved
execution permission path before diagnosing an authentication failure. Use the
working permission path for subsequent authorized release commands. If access
still fails, stop and report it. Never initiate login, device authorization,
browser authentication, account switching, or credential recovery. Publication
authorization does not authorize those actions.

Release from clean, current `origin/main`. PR CI and explicit platform runs validate source;
release preparation never runs local suites, an unsigned Debug build, or another
CI cycle. The release workflow builds and verifies a fresh production Release app
without dispatching source validation or looking for removed main CI runs.
Immutable tags, signing, notarization,
artifact verification, and exact approved release-copy gates still apply.

A supplied or confirmed version authorizes building and verifying a private
draft. Publication requires Trey's explicit manual approval of the exact release
description for that release. A tag push only stages a draft. For version `X.Y.Z`, the identities are:

- Tag: `vX.Y.Z`
- Title: `Woven Matter vX.Y.Z`
- Disk image: `WovenMatter_X.Y.Z_arm64.dmg`

The draft contains the disk image, its checksum file, and `latest-mac.json`.
`scripts/publish-release.sh` independently verifies the exact commit, workflow,
asset set, checksums, manifest, signature, notarization, and Gatekeeper before
publishing. The default invocation and `--verify-only` both leave the draft private.

After the build and verification, the release agent writes a user-facing
description of the material changes since the previous public release. Use this
structure for every release:

1. A short opening explanation of the release and its biggest changes.
2. The README-style download badge directly below the opening paragraph.
3. **New capabilities**, with bullet points for major new features.
4. **Improvements and fixes**, with bullet points for noticeable improvements
   and meaningful fixes.
5. A **Full changelog** comparison link.
6. **How to update** as the final section, with the exact text:
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

Use plain, natural language that explains what users can now do or what works
better. Omit implementation details unless they materially affect users. Put any
required upgrade action in the relevant feature or improvement bullet, keeping
the final update instructions consistent. Describe agent tools and conversation
permissions separately; do not blur them with an ambiguous "Full access" label.
Save the exact text in a Markdown file, update the private draft, and present the
complete description to Trey. Pause for edits or explicit approval; changed
descriptions or release commits need new approval.

Only after that approval, run
`scripts/publish-release.sh --approved-notes /absolute/path/to/notes.md vX.Y.Z EXPECTED_COMMIT_SHA`.
The flag attests to manual approval and publishes that file's text after repeating
verification. The script cannot establish conversational consent; the release
operator must enforce it and must not bypass it with direct publication commands.
GitHub Releases is the canonical binary distribution channel.

The production app uses `latest-mac.json` to discover updates and can install a
verified update. The installer checks the download digest, release identity,
code signature, notarization, and Gatekeeper before replacing the installed app.
