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
  delegate checks, release phase ordering (including the ad-hoc compile and the
  imported app) and source binding.
- `python3 scripts/test-full-updates.py`: actual signed DMGs, a same-version build
  update generated with the production full-only flags, full reconstruction, and
  rejection of delta assets and modified archives/source provenance.
- `scripts/test-app-termination.sh`: actual AppKit quit with deferred cleanup,
  including stopping a background backend on ordinary quit after extraction.
- `scripts/test-changes.sh --cross-device-desktop`: shared protocol and macOS
  cross-device integration for desktop package changes, without iOS simulator tests.
- `scripts/test-changes.sh --desktop`: desktop source checks without simulators.

Reference: [publishing](https://sparkle-project.org/documentation/publishing/).

## Release pipeline

`scripts/release-check.py` reports outdated dependencies and known
vulnerabilities first. `scripts/cut-release.sh build X.Y.Z` then makes a fresh
worktree of current `origin/main` on a maintainer Mac, builds the Linux library
binaries in Docker on the workstation (or another host in
`WOVENMATTER_LINUX_BUILD_HOST`, or `local`), compiles the production Release app
with an ad-hoc signature and the release version, build number and source
revision, and runs the native app checks. `scripts/cut-release.sh ship X.Y.Z`
uploads that zipped app and a small manifest (version, build, commit, SHA-256) to
the private draft, then pushes the `vX.Y.Z` tag.

The tag starts `.github/workflows/release.yml`. It compiles nothing: it downloads
the app, checks the manifest against the tag, and runs six visible phases:
import; re-sign with Developer ID and validate; notarize the app; create and sign
the disk image; notarize the disk image; and generate the manifest, checksums,
signed feed and reconstruction check. Re-signing replaces every ad-hoc
signature, innermost code first, keeping each item's identifier and
entitlements; vendor Developer ID signatures are left as they are, and Sparkle is
signed as before. The signed app's entitlements must match their source files
before anything reaches Apple. Each step receives only the secrets it uses and
repeats the source, tag and clean-tree checks, and each phase accepts only the
work of the one before it. A failed run is fixed and run again; nothing resumes
a failed phase. Finally the unsigned input is removed from the draft and the
signed artifacts are uploaded.

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
