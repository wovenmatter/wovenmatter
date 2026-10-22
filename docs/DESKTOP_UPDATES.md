# Desktop updates

The production Mac app uses Sparkle 2.10.0. `app/Updater/sparkle-version.json`
records that release, the exact commit the Xcode project requires, and the
SHA-256 of the signing tools archive; see [the dependency policy](DEPENDENCIES.md).
Settings > General opens its update UI,
including download progress and cancellation. Update checks remain manual.

The installed app is the local base for a binary delta: unchanged files and data
are reused, and only the patch is downloaded. Sparkle verifies the patch and the
resulting signed app, and falls back to a full download if the installed app does
not match a supported base. Downloaded updates are retained when installation is
postponed. Neither behavior requires more frequent releases.

The release pipeline generates signed deltas from up to five previous published
release builds. Both archives and the feed use a dedicated Ed25519 key. The public
key is pinned in Info.plist; the private key is the `SPARKLE_PRIVATE_KEY` secret in
the existing `release` environment. Keep a secure offline backup of this key.
Never rotate it casually: installed clients trust the original public key.

Full disk images remain available for first installs and legacy updaters. Runtime
source maps are omitted from production packaging; executable code, licenses, and
vendor signatures remain intact. A build fails before publication if its full
compatibility DMG exceeds the old updater's 512 MiB limit. The bounded runtime
downloader retains its 60-second idle timeout and permits a healthy transfer to
run for up to 24 hours, rather than stopping after five minutes. Sparkle's archive
downloads use its own downloader and do not use that old five-minute deadline.

## Refreshing an existing release

Only use this path when Trey explicitly requests a refresh of an existing public
release. Change `.github/release-refresh.json` in the approved PR. Its merge to
main starts **Refresh desktop update**, which creates an immutable `v*` build tag
and dispatches the same signed Mac build workflow used for ordinary releases. It
runs no mobile builds, test suites, or extra source CI. PR/main validation is independent.
A bot dispatch is accepted only at the main merge/squash commit that changed the
refresh request, on main’s first-parent history. A PR ancestor, later unrelated
main commit, or human dispatch is rejected.
Re-running that same authorized build remains supported.

The visible version stays the same; the internal build number increases. The
workflow verifies accepted-main source, signs and notarizes the app and DMG, checks
source provenance, enforces archive signatures and an exact checksum inventory,
and stages a private verification draft at `vVERSION-buildBUILD` before
changing any existing downloads. Sparkle’s nested helpers are signed individually
from the inside out before the containing framework and app are resealed and
notarized. Private verification resolves the draft’s release ID and checks
GitHub’s uploaded asset digests. Its immutable source tag points to the actual
build commit. `release-build.json` records that source commit and build number.
The original `vVERSION` tag and approved description are preserved. The existing
release environment remains restricted to `v*` tags; main does not gain direct
access to its signing secrets.

Immutable build DMGs and delta assets are uploaded first. The legacy DMG alias and
JSON manifest are refreshed next; the signed Sparkle feed is published last.
The prior full build is retained under an immutable build name. Failed promotion
attempts restore the previous aliases/feeds; the private draft remains available
for verification and recovery. A verified `staging-ready.json` record retains the
original signed artifacts, so retries reuse those exact bytes instead of rebuilding
nonreproducible signed disk images. Before promotion, `rollback-index.json`
retains the previous small manifests privately and references the prior immutable
full DMG. Recovery therefore survives a lost runner; a partial promotion resumes
even if its build metadata was already uploaded. A retry of a fully delivered build
only verifies its files. Transient lookup failures stop rather than creating a
duplicate draft. Empty failed GitHub uploads may be removed and retried; completed
immutable artifacts are always preserved. Never overwrite an immutable build
asset or move a version tag. GitHub cannot atomically replace multiple legacy aliases, so an old
client racing a refresh may need to retry its checksum-verified download.
New clients use immutable archive URLs.

Normal tagged releases still stay private until the exact release description is
approved and `scripts/publish-release.sh --approved-notes ...` publishes them.

## One-time compatibility step

Already-installed 0.2.8 and original 0.3.0 apps cannot gain delta support without
installing the refreshed app once. The original 0.3.0 updater compares only the
visible version, so it cannot detect a newer 0.3.0 build. Use the full DMG from the
0.3.0 release page for this one installation. Older clients can still discover
0.3.0 in-app, but a slow connection can exceed their already-shipped five-minute
deadline; downloading the DMG in a browser avoids that old deadline. Replace the
app normally; keep the existing workspace data. Subsequent updates use the new
build-aware, signed delta path.

## Focused checks

- `scripts/test-release.sh`: offline release/authentication/signing gates, real
  nested Sparkle signing with a temporary ad-hoc test identity, actual-framework
  delegate checks, and refresh authorization across real Git merge histories.
- `python3 scripts/test-support/test_update_refresh.py`: private verification,
  promotion ordering, immutable history, durable rollback after runner loss,
  original-byte reuse, and idempotent retries.
- `python3 scripts/test-delta-updates.py`: actual signed DMGs, a same-version build
  update, a binary-delta reconstruction, unchanged runtime reuse, and rejection of
  modified archives/source provenance. Also exercises retained-artifact validation
  and rejects a modified signed feed, using a temporary test key and substituted
  Apple notarization/Gatekeeper checks.
- `scripts/test-app-termination.sh`: actual AppKit quit with deferred cleanup,
  including stopping a background backend on ordinary quit after extraction.
- `scripts/test-changes.sh --companion-desktop`: shared protocol and macOS companion
  integration for desktop package changes, without iOS simulator tests.
- `scripts/test-changes.sh --desktop`: desktop source checks without simulators.

References: [Sparkle delta updates](https://sparkle-project.org/documentation/delta-updates/)
and [publishing](https://sparkle-project.org/documentation/publishing/).
