# Desktop updates

The Mac app updates itself with the Sparkle release recorded in
`app/Updater/sparkle-version.json`, which also records the exact commit the
Xcode project requires and the SHA-256 of the signing tools archive; see
[the dependency policy](DEPENDENCIES.md). Settings > Updates checks for and
installs updates; checks are manual.

Every update is a full signed download: the feed offers no binary deltas.
Downloaded updates are kept when installation is postponed. The release
pipeline signs the archive and the feed with a dedicated Ed25519 key. The
public key is in Info.plist; the private key is the `SPARKLE_PRIVATE_KEY`
secret in the `release` environment. Keep a secure offline backup of it and
never rotate it casually: installed apps trust that public key.

The disk image on each release page installs the app by hand. Source maps are
left out of packaging; executable code, licenses and vendor signatures stay
intact.

`python3 scripts/test-full-updates.py` checks the update path offline: a real
signed disk image, a feed generated with the production full-only flags, full
reconstruction, and rejection of a delta asset, a modified archive and a wrong
source revision.

Reference: [publishing](https://sparkle-project.org/documentation/publishing/).

## Release pipeline

`scripts/release-check.py` reports outdated dependencies and known
vulnerabilities first. `scripts/cut-release.sh build X.Y.Z` then makes a fresh
worktree of current `origin/main` on this Mac and compiles the production
Release app with an ad-hoc signature and the release version, build number and
source revision. The compile builds everything the app carries, including the
Linux `woven-server` and its resources for x86_64 and aarch64
(`scripts/prepare-linux-server.sh`, into `Contents/Resources/linux-server`),
which the Mac installs on Linux machines over SSH. The script then runs the
native app checks. `scripts/cut-release.sh ship X.Y.Z` uploads that zipped app
and a small record (version, build, commit, SHA-256) to the private draft, then
pushes the `vX.Y.Z` tag.

The tag starts `.github/workflows/release.yml`. It compiles nothing: it
downloads the app, checks the record against the tag, and runs six visible
phases: import; re-sign with Developer ID and validate; notarize the app;
create and sign the disk image; notarize the disk image; and generate the
signed feed, the provenance record (`release-build.json`), checksums and the
reconstruction check. Re-signing replaces every ad-hoc signature, innermost
code first, keeping each item's identifier and entitlements; vendor Developer
ID signatures are left as they are, and Sparkle is signed by
`scripts/sign-release-updater.sh`. The signed app's entitlements must match
their source files before anything reaches Apple. Each step receives only the
secrets it uses and repeats the source, tag and clean-tree checks, and each
phase accepts only the work of the one before it. A failed run is fixed and
run again; nothing resumes a failed phase. Finally the unsigned input is
removed from the draft and the signed artifacts are uploaded.

Both notarization submissions remain: the full update must carry the app's own
stapled ticket, which offline installs rely on, and stapling it inside an
already notarized image would change the image's bytes.

The feed is generated once, after the disk image is signed, notarized and
stapled, with only that image in the generator's input folder and
`--maximum-deltas 0`. Its start and elapsed time are logged, and a failure
stops the release. The disk image uses ordinary zlib level 6 compression. The
exact asset inventory is the two names of the disk image (one with the build
number for the feed, one without for the download link), `appcast.xml`,
`release-build.json` and `SHA256SUMS.txt`; anything else, such as a delta,
fails the release. The update is mounted, its app verified, then copied as an
installer would and compared with the original, including contents, modes,
symlinks and ticket files.

`scripts/publish-release.sh` keeps downloaded draft bytes in a private local
store, `~/Library/Caches/WovenMatter/ReleaseArtifacts/OWNER/REPO/RELEASE_ID-COMMIT`,
so `--verify-only` followed by `--approved-notes` downloads each file once.
Only bytes are stored, never a verification result. Every run reads fresh
GitHub asset metadata, rehashes each copy, and discards corrupt, partial, or
replaced bytes. A release that is not a private draft is refused before any
download. The script then repeats every checksum, provenance, update-signature,
Developer ID, notarization and Gatekeeper check. Directly before publication
the release ID, draft state, and every asset ID, size, digest, and upload time
must still match the verified snapshot. Afterward the published description
must match the approved file exactly; only CRLF line endings are normalized.
The store for that release is then removed. A store for an abandoned draft can
be deleted at any time.
