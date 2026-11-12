# Desktop updates

The production Mac app uses the Sparkle release recorded in
`app/Updater/sparkle-version.json`, which also records the exact commit the
Xcode project requires and the SHA-256 of the signing tools archive; see
[the dependency policy](DEPENDENCIES.md).
Settings > General opens its update UI,
including download progress and cancellation. Update checks remain manual.

Releases are full-only: every client downloads the complete signed update. The
feed offers no binary deltas, so Sparkle uses its standard full-update path for
every installed build. Downloaded updates are retained when installation is
postponed. Delta generation was removed after it stalled on a Chromium (CEF)
upgrade, where diffing two large, different framework binaries per published
base exceeded the release runner's practical limits; a full update costs only
download size, not security.

The release pipeline signs the full archive and the feed with a dedicated
Ed25519 key. The public
key is pinned in Info.plist; the private key is the `SPARKLE_PRIVATE_KEY` secret in
the existing `release` environment. Keep a secure offline backup of this key.
Never rotate it casually: installed clients trust the original public key.

Full disk images remain available for manual installation. Runtime source maps
are omitted from production packaging; executable code, licenses, and vendor
signatures remain intact. Releases target the current Sparkle update path and
are not capped by the retired updater's 512 MiB download limit. Installations
predating Sparkle can be replaced manually from the release DMG. The bounded runtime
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

Immutable build DMGs are uploaded first. The legacy DMG alias and
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

Already-installed 0.2.8 and original 0.3.0 apps cannot gain build-aware updates
without installing the refreshed app once. The original 0.3.0 updater compares only the
visible version, so it cannot detect a newer 0.3.0 build. Use the full DMG from the
0.3.0 release page for this one installation. Older clients can still discover
0.3.0 in-app, but a slow connection can exceed their already-shipped five-minute
deadline; downloading the DMG in a browser avoids that old deadline. Replace the
app normally; keep the existing workspace data. Subsequent updates use the new
build-aware, signed full-update path.

## Focused checks

- `scripts/test-release.sh`: offline release/authentication/signing gates, real
  nested Sparkle signing with a temporary ad-hoc test identity, actual-framework
  delegate checks, and refresh authorization across real Git merge histories.
  Also release phase ordering and source binding, independent component cache
  keys, and reuse of verified local draft bytes, including replacement detection.
- `python3 scripts/test-support/test_update_refresh.py`: private verification,
  promotion ordering, immutable history, durable rollback after runner loss,
  original-byte reuse, and idempotent retries.
- `python3 scripts/test-full-updates.py`: actual signed DMGs, a same-version build
  update generated with the production full-only flags, full reconstruction, and
  rejection of delta assets and modified archives/source provenance. Also exercises retained-artifact validation
  and rejects a modified signed feed, using a temporary test key and substituted
  Apple notarization/Gatekeeper checks.
- `scripts/test-app-termination.sh`: actual AppKit quit with deferred cleanup,
  including stopping a background backend on ordinary quit after extraction.
- `scripts/test-changes.sh --cross-device-desktop`: shared protocol and macOS
  cross-device integration for desktop package changes, without iOS simulator tests.
- `scripts/test-changes.sh --desktop`: desktop source checks without simulators.

Reference: [publishing](https://sparkle-project.org/documentation/publishing/).

## Release performance and cache trust

Releases build on the owned runners ([CI runners](CI_RUNNERS.md)). Their caches
persist on those machines, apart from validation caches and from the user's own
dev builds (`scripts/ci-runner/cache-env.sh`). Only release builds of accepted
main source, and rehearsals, write the release caches. Validation of any branch
never writes a cache a release reads. No app bundle, signing identity,
notarization key or updater key enters a cache, and a miss builds normally.

| Cache | Checked on every use |
| --- | --- |
| Download archives (CEF, Node, Sparkle, Cua) | Each archive's pinned digest |
| Browser products, keyed by sources, CEF, architecture, compiler, SDK, CMake and flags | Complete content manifest |
| SwiftPM repositories | Checkouts at `Package.resolved` revisions |
| npm store | Lockfile integrity, scripts disabled |
| Xcode compilation cache | Xcode's per-compilation input keys |
| Linux library inputs (Static Linux SDK, SQLite) | Pinned SHA-256 in `remote/library/build-version.json` |

The compilation cache starts over when it exceeds 6 GB. A release reuses compiler
results, not an old app: it compiles from fresh DerivedData in the job's
temporary directory, links, stamps version/source metadata, and signs anew. A
failed cached compilation retries once with fresh intermediates and caching
disabled. After a toolchain or browser-source change, the next release compiles
those parts in full. No release duration is guaranteed.

The signed workflow runs six visible phases: compile; seal and validate; notarize
the app; create and sign the disk image; notarize the disk image; and generate the
manifest, checksums, signed feed, and reconstruction check. Each step shows live
status and duration, and receives only the secrets it uses. Every phase repeats the
source, tag, and clean-tree checks. It accepts only the work of the immediately
preceding phase for the same version, build, commit, resolved output directory,
and signing identity, and rejects any other or extra phase argument. A failed phase
invalidates the work directory; a new attempt reuses a complete private draft or
rebuilds from compilation. `build-release.sh VERSION` still runs all phases
locally. The compile log includes Xcode's build timing summary; browser preparation also
reports archive, product preparation, and bundle/signing durations. Each phase's
elapsed time appears in the step summary, as a
`release-timing` JSON log line, and in the job's final timings step.

`scripts/publish-release.sh` keeps downloaded draft bytes in a private local
store, `~/Library/Caches/WovenMatter/ReleaseArtifacts/OWNER/REPO/RELEASE_ID-COMMIT`,
so `--verify-only` followed by `--approved-notes` downloads each file once. The
two identical DMG names are fetched once when GitHub reports the same SHA-256
and size for both. Only bytes are stored, never a verification result. Every
run reads fresh GitHub asset metadata, rehashes each copy, and discards
corrupt, partial, or replaced bytes. A release that is not a private draft is
refused before any download. The script then repeats every checksum,
provenance, update-signature, Developer ID, notarization and Gatekeeper check.
After those checks, in both modes and directly before publication, the release
ID, draft state, and every asset ID, size, digest, and upload time must still
match the verified snapshot. Afterward the published description must match the
approved file exactly; only CRLF line endings are normalized. The store for that
release is then removed. A store for an abandoned draft can be deleted at any time.

Ordinary private tagged releases can restore a complete, digest-verified uploaded
artifact set after a failed workflow attempt. Source, version, build, inventory,
Developer ID, notarization, Gatekeeper and updater signatures must still pass;
public releases and mismatched provenance are rejected. Partial uploads rebuild.

Every newly generated full update is mounted, its app verified, then copied as
an installer would and compared with the original, including file contents,
executable modes, symlinks, and bundled ticket files. Signatures, app stapling,
and Gatekeeper checks remain required. A delta enclosure in the feed, a `.delta`
asset, or a non-empty `delta_assets` record fails the release rather than being
skipped. The offline fixture covers a signed same-version round trip. It does
not substitute for offline first-launch acceptance.

Both notarization submissions remain. Apple can notarize nested code through
one outermost-DMG submission, but the full update must carry the app's own
stapled ticket, which offline installs rely on. Stapling that ticket into the app
inside an already notarized, read-only image would change the image's bytes.
Dropping the app submission therefore needs a separate signed experiment showing
offline ticket parity first. No source, notes, assets or tags belonging to an
already-running release are changed by these optimizations.

Release packaging follows the sequential flow: finish signing, notarizing, and
stapling the DMG, then invoke Sparkle's feed generator once with only that DMG
in its input folder and `--maximum-deltas 0`. No published build is downloaded
as a delta base. The generator's start and elapsed time are logged, and a
failure stops the release with its exit status; the release job's own timeout
remains the backstop for a hang.
Full DMGs retain ordinary zlib level 6 compression without a legacy size cap or
maximum-compression retry. Signing, notarization, checksums, and full
reconstruction verification remain required.

### Rehearsing a release

A rehearsal runs every signed phase above on the owned runners, notarization
included, from a `v-rehearsal-*` tag on any commit. It builds version 0.0.1,
creates no draft, publishes nothing, and deletes its signed output. See
[Rehearsing a release](CI_RUNNERS.md#rehearsing-a-release).
