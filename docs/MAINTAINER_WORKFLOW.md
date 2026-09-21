# Maintainer workflow

## Validation

`scripts/test-changes.sh --all` runs deterministic checks and an unsigned macOS
build. Use `--macos` or `--remote` for focused validation.
Container lifecycle changes also use `scripts/test-container.sh` when Docker is
available. Tests use temporary data and must not consume provider services.

CI selects macOS and remote jobs by changed paths. Documentation-only changes
run the public-tree scan and stable CI gate. Remote image builds run on Linux.
Validation uses disposable GitHub-hosted runners without provider, signing, or
deployment credentials. The `pull_request_target` classification workflows
inspect metadata or inert Git data; they do not execute contributor code.

## Contributions

Pull requests target `main`; code-owner approval is the merge gate. The vouch
workflow classifies contributors for review without granting write access.
`.github/VOUCHED.td` entries use `github:username`, prefixed with `-` to denounce a
contributor. Changes on `main` reclassify open pull requests; `/recheck-vouch`
rechecks one pull request.

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

After the build and verification, the release agent writes a short, user-facing
explanation of the material changes since the previous public release: major new
capabilities, noticeable improvements, meaningful fixes, and any required upgrade
actions, followed by a full changelog comparison link. Omit implementation details
unless they materially affect users. Save the exact text in a Markdown file,
update the private draft, and present the complete description to Trey. Pause for
edits or explicit approval; changed descriptions or release commits need new approval.

Only after that approval, run
`scripts/publish-release.sh --approved-notes /absolute/path/to/notes.md vX.Y.Z EXPECTED_COMMIT_SHA`.
The flag attests to manual approval and publishes that file's text after repeating
verification. The script cannot establish conversational consent; the release
operator must enforce it and must not bypass it with direct publication commands.
GitHub Releases is the canonical binary distribution channel.

The production app uses `latest-mac.json` to discover updates and can install a
verified update. The installer checks the download digest, release identity,
code signature, notarization, and Gatekeeper before replacing the installed app.
