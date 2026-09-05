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

`scripts/build_and_run.sh` builds and launches the unsigned development app.
Production releases are signed, notarized Apple Silicon builds from an exact
accepted commit. Release, installation, deployment, and publication require an
explicit request; they are separate from deterministic validation.

Use `.agents/skills/cut-release-wovenmatter/SKILL.md` for the release procedure.
A supplied or confirmed version authorizes completion through publication unless
the request explicitly limits the work to a private draft. A tag push only
stages a draft. For version `X.Y.Z`, the identities are:

- Tag: `vX.Y.Z`
- Title: `Woven Matter vX.Y.Z`
- Disk image: `WovenMatter_X.Y.Z_arm64.dmg`

The draft contains the disk image, its checksum file, and `latest-mac.json`.
`scripts/publish-release.sh` independently verifies the exact commit, workflow,
asset set, checksums, manifest, signature, notarization, and Gatekeeper before
publishing. Use its `--verify-only` mode for an explicitly requested draft.
GitHub Releases is the canonical binary distribution channel.

The production app uses `latest-mac.json` to discover updates and can install a
verified update. The installer checks the download digest, release identity,
code signature, notarization, and Gatekeeper before replacing the installed app.
