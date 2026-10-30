---
name: cut-release-wovenmatter
description: Cut, prepare, verify, and publish a WovenMatter macOS release.
---

An explicit request to cut a release authorizes building and verifying a private
draft, not publication. Use a supplied version as given. If none is supplied,
choose it from the change range since the previous public release: the next
unused patch version for a maintenance-only release, otherwise the unused
semantic version that the new capabilities or compatibility changes call for.
State it and start the private build after the access, dependency, and source
checks below; do not stop to confirm it. Ask first only when a material
version-policy or compatibility question makes the version genuinely ambiguous. Always pause for Trey's explicit manual approval of
the exact release description, which shows the version and download badge, before
publishing. A release request, a stated version, or approval of a previous release
is not description approval.

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

Before selecting the release commit, verify dependency currency against upstream
stable releases using `docs/DEPENDENCIES.md`, including Node Current and SDK
majors. If updates are available, complete them as development PRs with refreshed
lockfiles, generated resources, and normal development CI; merge them before
continuing release preparation. Every new release must carry this refreshed
snapshot. Report any concrete upstream blocker explicitly. Do not resolve or
install newer versions inside the signed release build: it must use the accepted
lockfiles. A previously verified private draft retains its original snapshot.

Release from clean, current `origin/main`. PR CI and explicitly requested platform
validation own source validation. Do not run `scripts/test-changes.sh --all`, any
test suite, or an unsigned Debug build as a release prerequisite. Do not trigger,
wait for, or rerun CI during release preparation. Create and push an annotated `vX.Y.Z`
tag at that exact accepted commit to start the release workflow. Never move or
reuse a release tag; an existing private draft can be resumed at its original
accepted commit.

Automatic CI runs on PRs only; native/mobile/image validation is manual. Release
preparation does not recreate a main CI run or dispatch platform validation.
Lightweight tag/main source checks remain before importing signing secrets.
Always build a new production Release app; a Debug app is never a distribution
artifact.

The tag-triggered `.github/workflows/release.yml` builds a signed, notarized
Apple Silicon app and stages a private draft. Its six named phase steps show live
progress and record per-phase timings. It restores component caches produced on
main by `Prepare release dependencies`. That workflow bootstraps changes to its
own definition and refreshes after a successful release; it can also run manually.
Release preparation does not dispatch it.

The release and cache producer both use the billed `macos-26-xlarge` runner.
Report its observed build timings and job durations; include the later cache
preparation job when estimating runner cost. After a runner-class change, wait
for the automatic main cache preparation to finish before cutting the next tag;
its first run must populate entries for the new compiler thread count.

Report observed cache hits and timings, rather than assuming that
configured caches made a release faster. A miss, for example after a
toolchain or browser-source change, compiles those parts in full; no release
duration is guaranteed. After its successful run, verify
through `scripts/publish-release.sh --verify-only vX.Y.Z EXPECTED_COMMIT_SHA`.
The script checks source, workflow, assets, checksums, signing, notarization,
and Gatekeeper. GitHub CLI authentication must match the repository's SSH account.
It keeps downloaded bytes, never results, in a private local store; the later
`--approved-notes` run rehashes them, repeats every check, and refuses a draft or
asset changed since verification. Do not clear that store between the two runs.

Once the tag starts the hosted build, list the PRs merged since the previous public
release and draft the release description while the build runs, so Trey can review
it without waiting for packaging. Approval of that exact text persists for the same
release; do not request it again merely because the build finished. Stage the
approved file on the private draft when it exists. Publication still requires a
successful workflow and standard artifact verification.

Write the release description from the material changes since the previous
public release. Inspect the complete commit/PR range and underlying changes;
do not simply repeat commit titles. Use this structure for every release:

1. A short opening explanation led by major user-facing capabilities. Put
   individual bug fixes in **Improvements and fixes**, rather than the headline.
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
URL. If that exact description has not already been approved, stop and wait for
his explicit approval; leave the release private. Apply
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


## Full-update packaging that shipped successfully

Use the current scripts and [desktop update documentation](../../../docs/DESKTOP_UPDATES.md).
Release 0.3.2 from `fb415bf38ae575adfd46fdac1295aca363e75dfe` shipped
through this path; Trey confirmed the installed 0.3.1 → 0.3.2 update worked.

- Keep Chromium/CEF and other dependencies current. Do not downgrade the browser
  to reduce packaging cost.
- Ship full signed Sparkle updates. After signing, notarizing, and stapling the
  app and DMG, generate the feed once from the final archive. Its input directory
  contains only the new DMG; `generate_appcast` uses `--maximum-deltas 0`.
  Do not download older DMGs as delta bases or restore background preparation
  and feed regeneration. Feed, inventory, and update-path checks reject deltas.
- Use ordinary zlib level 6 DMG compression. The retired 512 MiB compatibility
  cap and compression retries are gone; do not reintroduce them.
- Keep both notarization submissions: the app's own stapled ticket is required
  inside the DMG. Dropping one needs a separate signed experiment first.
- Retain feed/payload signatures, provenance, exact asset inventory, checksums,
  notarization, Gatekeeper, and full-update reconstruction verification.
- Keep generator start/elapsed-time logging. Do not add an arbitrary ten-minute
  cutoff; the hosted job currently has a 120-minute timeout.

Failed attempts spent a long time generating deltas across a Chromium upgrade
against two older releases. Memory pressure was suspected, not measured. Do not
claim a proven Sparkle runtime defect or assume compression fixes binary-diff
cost. Keep deltas out of ordinary release preparation.

## Background execution and completion

Start the hosted build promptly after source selection; record its run URL and
exact source SHA. Draft and review the description while the build runs.
If publication is already explicitly approved, continue after workflow success
with the standard verification and approved-notes publication commands above.
A running build or background waiter is not proof of publication.

On failure, collect diagnostics and report the actual blocker before restarting
or changing the pipeline. Do not substitute repeated builds for diagnosis. The
failing phase step and its `release-timing` lines identify where it stopped.
Once the cause is understood, a new attempt reuses a complete verified private
draft or rebuilds from compilation; it never resumes a failed phase.
After publication, read back public state (`isDraft=false`), source provenance,
and the exact release body against the approved UTF-8 file. Verify the download
badge targets an existing release asset. Report success only after these checks.


## Explicitly requested same-version update repair

When Trey explicitly asks for an updater repair PR that refreshes an existing
release on merge, follow `docs/DESKTOP_UPDATES.md`. Put the existing version in
`.github/release-refresh.json`; its merge starts the desktop-only signed workflow.
That request authorizes the asset refresh after private artifact verification;
it does not authorize editing the approved description or moving its version tag.
The actual source has a separate immutable update-build tag and provenance asset.
Keep normal new-version release publication behind the description approval gate.
Explain the one-time full-install limitation for clients predating the new updater.
