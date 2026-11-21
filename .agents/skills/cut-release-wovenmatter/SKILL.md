---
name: cut-release-wovenmatter
description: Cut, prepare, verify, and publish a WovenMatter macOS release.
---

A release runs in four steps, all on this Mac; GitHub only signs and notarizes.

1. **Check and update.** A release is a desktop (Mac) release. Never touch
   anything under `ios/`: no iPhone lockfiles, no regenerating the iPhone's
   embedded Pi runtime (`scripts/build-ios-pi-runtime.mjs`), no iPhone tests.
   iPhone releases are separate.

   Run `scripts/release-check.py`. It reports which top-level packages are behind
   their current upstream release, and known vulnerabilities in shipped code.
   The top-level set is everything the repo itself declares or records:
   - the direct npm dependencies in `default-agent`, `bots` and
     `harnesses/npm-runtime` (the Pi family and Chord on one release, the Claude
     Agent SDK, Playwright, ws, undici and so on);
   - the direct Swift packages (swift-nio, swift-crypto, Sparkle);
   - the runtime records: Node, the bundled npm, CEF/Chromium, Cua Driver, Docker
     Engine, the bot images' Ubuntu base and their Node and Playwright copies, the
     Mac VM guest, the Swift toolchain, Static Linux SDK and SQLite for the Linux
     server (`server/linux-build.json`), Lucide, and the exact-pinned GitHub
     Actions.

   Coding CLIs and ACP connectors already install latest at run time and have no
   recorded selection, so there is nothing to bump for them.

   Update top-level packages only, as we use them, and do not go inside them.
   Take each package as upstream ships it, with the versions it pins itself (Pi's
   own exact pins of openai, @anthropic-ai/sdk, undici and minimatch, for
   example). Do not add or keep overrides that raise a package's internal
   dependencies, and do not bump transitive packages individually; they change
   only as a consequence of updating a top-level package.

   If anything is outdated, update all of it to current upstream releases, majors
   included, following `docs/DEPENDENCIES.md` (lockfiles, records, checksums,
   notices and generated resources together), validate it with
   `scripts/test-changes.sh`, and open one PR. Give Trey the PR link and a short
   report on each known vulnerability: severity, whether it ships, and what you
   recommend (update, hold a version, replace, or accept). A vulnerability inside
   a top-level package's own pins is reported this way, not patched inside the
   package. If nothing is outdated, there is no PR; give the report alone.
2. **Go-ahead.** Wait for Trey. He merges the PR and says go, or you work through
   the findings together first.
3. **Build and describe, in parallel.** Run `scripts/cut-release.sh build X.Y.Z`
   in the background. It makes a fresh worktree of current `origin/main` and
   compiles the production Release app here (ad-hoc signed; a Debug app is never
   a distribution artifact). That compile also builds everything the app
   carries: the Linux `woven-server` for x86_64 and aarch64, Pi Durable, the
   bots runtime, the VM helper, the power helper, Cua and the browser. It then
   checks the app and uploads nothing. Meanwhile draft the release description
   and go over it with Trey. Ship the moment both the build and the approval are
   done.
4. **Ship.** Once the build passed and Trey approved the exact description, run
   `scripts/cut-release.sh ship X.Y.Z`. It uploads that build to the private
   draft and pushes the annotated `vX.Y.Z` tag. The tag starts
   `.github/workflows/release.yml`, which compiles nothing: it re-signs the app
   with Developer ID, notarizes it, builds and notarizes the DMG, generates the
   signed feed, and uploads the signed artifacts to the private draft. After it
   succeeds, verify and publish with the commands below.

Use a supplied version as given. If none is supplied, choose it from the change
range since the previous public release: the next unused patch version for a
maintenance-only release, otherwise the unused semantic version that the new
capabilities call for. State it; ask first only when it is genuinely ambiguous.
A release request, a stated version, or approval of a previous release is not
description approval. Release preparation runs no test suites beyond the
dependency PR's validation, and does not trigger, wait for, or rerun CI. The
signed build never resolves newer versions: it uses the lockfiles and runtime
records committed on the release commit.

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

If the signing workflow fails, find the cause, fix it on main, delete the
unpublished tag, and build and ship again with the same version; only a published
version is final. Never publish two releases with the same version. Its six named
phase steps show live progress and record per-phase timings; the failing step and
its `release-timing` lines show where it stopped. A new attempt builds and ships
again; it never resumes a failed phase. Diagnose before retrying; do not
substitute repeated builds for diagnosis.

After a successful run, verify with
`scripts/publish-release.sh --verify-only vX.Y.Z EXPECTED_COMMIT_SHA`. It checks
source, workflow, assets, checksums, signing, notarization and Gatekeeper, and
keeps downloaded bytes, never results, in a private local store; the later
`--approved-notes` run rehashes them, repeats every check, and refuses a draft or
asset changed since verification. Do not clear that store between the two runs.

Approval of the exact description persists for the same release; do not request it
again merely because the build finished. Publication still requires a successful
workflow and standard artifact verification.

## The description

Write it from the material changes since the previous public release. Inspect the
complete commit/PR range and underlying changes; do not simply repeat commit
titles. Use this structure:

1. A short opening explanation led by major user-facing capabilities. It
   begins "Woven Matter vX.Y.Z", with the `v`, matching the release title. Put
   individual bug fixes in **Improvements and fixes**, rather than the headline.
2. The README-style download badge directly below the opening paragraph.
3. **New capabilities** — bullet points describing major new features.
4. **Improvements and fixes** — bullet points describing noticeable improvements
   and meaningful fixes.
5. A **Full changelog** link comparing the previous release tag with the new tag.
6. **How to update** — the final section, using this exact copy:
   "Go to Settings > Updates to check for and install the update."

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
bullet. Distinguish agent tools from conversation permissions instead of
referring to both with an ambiguous phrase such as "Full access."

Save the description in a UTF-8 Markdown file and update the private draft with
`gh release edit vX.Y.Z --notes-file /absolute/path/to/notes.md`. Present the full
description to Trey along with the exact commit, validation result, and draft
URL. If that exact description has not already been approved, stop and wait for
his explicit approval; leave the release private. Apply requested edits and show
the revised description for approval. Any later change to the description or
release commit requires fresh approval.

Only after approval, publish with
`scripts/publish-release.sh --approved-notes /absolute/path/to/notes.md vX.Y.Z EXPECTED_COMMIT_SHA`.
This option attests that Trey approved that exact description for this release;
never supply it preemptively. The script publishes the supplied text and repeats
artifact verification. Its default invocation only verifies and leaves the draft
private. Never bypass this gate with direct GitHub publication commands.

A running build or background waiter is not proof of publication. After
publication, read back public state (`isDraft=false`), source provenance, and the
exact release body against the approved UTF-8 file, and verify the download badge
targets an existing release asset. Report the exact commit, validation result, and
release URL with its verified public state only after these checks.

## Packaging rules

See [desktop updates](../../../docs/DESKTOP_UPDATES.md).

- Keep Chromium/CEF and other dependencies current. Do not downgrade to reduce
  packaging cost.
- Ship full signed Sparkle updates only: generate the feed once from the final
  notarized DMG, alone in its input folder, with `--maximum-deltas 0`. Never
  download older DMGs as delta bases.
- Ordinary zlib level 6 DMG compression; no size cap or compression retries.
- Keep both notarization submissions: the app's own stapled ticket is required
  inside the DMG.
- Keep feed and archive signatures, provenance, the exact asset inventory,
  checksums, notarization, Gatekeeper and full-update reconstruction checks.
