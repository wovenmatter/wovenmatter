# Maintainer workflow

WovenMatter keeps validation behavior in repository-owned scripts so the same
checks can run locally and in continuous integration.

## Validation

Run the complete deterministic suite with:

```sh
scripts/test-changes.sh --all
```

When container lifecycle behavior changes and Docker is available, also run:

```sh
scripts/test-container.sh
```

Tests must not receive provider credentials, make model calls, publish an app,
deploy a remote workspace, or modify repository contents outside their
documented temporary build and test locations.

## Continuous integration

Keep hosted validation small, path-aware, and on standard GitHub-hosted
runners. The initial `CI` workflow contains only:

1. **Change detection:** scan the public tree and decide which focused jobs are
   relevant.
2. **macOS:** run static checks, Swift package tests, and an unsigned native
   application build on `macos-26` when app, harness, or macOS validation files
   change.
3. **Remote workspace:** run deterministic remote tests and build the workspace
   image on `ubuntu-24.04` with Node.js 24 and Docker when remote, harness, or
   lifecycle files change.
4. **CI gate:** report one stable required result after relevant jobs pass or
   are skipped.

Run focused checks when a pull request targeting `main` is opened or updated
and again when a change reaches `main`. Documentation-only changes run the
lightweight public-tree scan and gate without consuming a macOS runner. Cancel
superseded pull-request runs, but do not cancel or reorder validation for a
commit that has reached `main`.

Use read-only `contents` permission, short reasonable timeouts, native path
checks, and no ambient credentials. Do not provide CI with provider
credentials, signing materials, SSH access, Keychain contents, deployment
tokens, or development or staging host access. Code from forks is untrusted;
run it only on disposable, whole-job-isolated GitHub-hosted workers with clean
checkouts and no persistent host state. A container alone is not a sufficient
trust boundary for a macOS worker.

Run `scripts/scan-public-tree.sh` manually before a source publication or other
high-risk provenance review. Public-repository secret scanning provides the
routine credential-leak baseline. Dependency updates remain deliberate
maintainer changes; review the container base-image digest and harness catalog
sources when updating them.

The `pull_request_target` classification workflows may inspect metadata or
fetch a pull-request commit as inert Git data. They must never check out or
execute contributor-controlled code.

Do not add paid runners, preview deployments, staging automation, or another CI
provider without a separate maintainer decision. The protected release workflow
is limited to exact version tags and the dedicated `release` environment.

## Branch model

- `main` is the stable branch.
- Contributors work in short-lived branches or forks and open pull requests
  directly against `main`.
- Focused checks run on the pull request and again after the accepted change
  reaches `main`.
- Approval from the repository code owner is the merge gate.
- Do not create a permanent `dev` integration branch for v0.1.

The vouch workflow classifies pull requests for review. Add a contributor to
`.github/VOUCHED.td` as `github:username` after establishing trust. Prefix the
entry with `-` to mark a contributor as denounced. Updating the list on `main`
reclassifies open pull requests, and `/recheck-vouch` in a pull-request comment
rechecks one pull request. Vouch status never grants write access.

## Environments

- **Development** uses the unsigned app produced by
  `scripts/build_and_run.sh`, local test data, and disposable remote workspaces.
- **Staging** uses an isolated app build and dedicated Linux workspace host with
  separate credentials, data, workspace IDs, ports, and Keychain entries. It is
  the place for container lifecycle and real harness-account acceptance after
  deterministic validation passes. Staging runs only from an explicitly
  approved commit in the primary repository; forked pull requests never receive
  staging access.
- **Release** is a signed, notarized build from an exact accepted commit. The
  code-owner approval and merge accepts the source. Pushing its version tag
  builds the release and stages a private draft, but cannot publish it. Only
  `trey131` can run the separate Publish Release workflow, which requires the
  exact tag and the matching `publish vX.Y.Z` confirmation. Development or
  staging credentials and data must never be copied into it.

No script in this repository automatically promotes between environments.
Deployment, signing, notarization, and release publication remain explicit
maintainer actions.

## Release artifact contract

Public macOS production releases support Apple Silicon only. For marketing
version `X.Y.Z`, use all of the following exact release identities:

- Git tag: `vX.Y.Z`
- GitHub release title: `Woven Matter vX.Y.Z`
- macOS release asset: `WovenMatter_X.Y.Z_arm64.dmg`

Do not publish Intel (`x64`) or universal macOS artifacts without a separate
maintainer decision and validation on the added architecture. GitHub Releases
is the canonical binary distribution channel, and the website download action
must resolve to the corresponding versioned GitHub Release asset.

Before publication, the application and disk image must be built from the
release tag's exact commit, signed with the Woven Matter Developer ID
Application identity, notarized by Apple, stapled where supported, and accepted
by the repository's release validation and macOS Gatekeeper checks.

Pushing `vX.Y.Z` runs the signed release workflow and leaves the verified asset
set in a private GitHub draft. A tag push never makes that draft public. After
reviewing the draft, `trey131` publishes it by manually running the Publish
Release workflow with `tag` set to `vX.Y.Z` and `confirmation` set to
`publish vX.Y.Z`. That workflow refuses non-drafts, unexpected asset sets,
other actors, malformed tags, and mismatched confirmation text.

The release also publishes `latest-mac.json`, a bounded update manifest for the
production app. It identifies the versioned DMG, exact SHA-256 digest, release
page, Apple Silicon architecture, and minimum macOS version. The app may open
the official GitHub asset for an available update; it must not execute a
downloaded installer or bypass Gatekeeper.

Preview or staging automation, if added later, must be opt-in, scoped to trusted
same-repository commits, and separated from read-only validation. Release
automation must identify one exact accepted commit and must never reuse
development or staging credentials.
