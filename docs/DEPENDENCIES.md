# Dependency policy

Woven Matter stays on current upstream releases without forcing app releases
for every package update. Three separate mechanisms do that:

1. **Source maintenance** is run manually or by a separately configured agent
   on an owned machine. It proposes current stable releases, majors included,
   as pull requests. CI and review gate acceptance. Nothing merges, releases,
   publishes, or deploys automatically. This repository installs no dependency
   scheduler or GitHub-hosted proposal automation.
2. **Builds and tests** install the committed npm lockfiles with `npm ci`
   and consume the recorded native selections. Dependency refresh belongs in
   maintenance. Linux base-image security patches remain deliberately floating,
   as described below.
3. **Installed apps** update SDKs and agent CLIs independently of app releases
   through explicit Settings actions, within the compatibility the installed app
   was tested against.

## What each record means

| Record | Kind | Updated by |
| --- | --- | --- |
| `package.json` caret ranges | Declaration. The floor is the current tested release; the range is the compatibility line. | Maintenance PRs raise floors, across majors when upstream moves |
| `default-agent/package-lock.json`, `ios/EmbeddedRuntime/package-lock.json` | Exact tested snapshot with integrity hashes, installed with `npm ci` | The same PRs |
| `app/Package.resolved` | Shared SwiftPM/Xcode graph: Peekaboo, Sparkle, and their transitive packages | Native package-manager tooling during maintenance |
| `default-agent/.node-version` and the Node checksums in `scripts/prepare-default-agent.sh` and `LocalACPManagedRuntime.swift` | One Node LTS release and its official archive SHA-256 values | Maintenance PR, all copies together |
| `app/Browser/cef-version.json` | Exact CEF build and archive SHA-1 values per architecture | Maintenance PR |
| `app/Updater/sparkle-version.json` and the Xcode Sparkle revision | Release, exact commit, and tools archive SHA-256 for the updater | Maintenance PR, both together |
| Generated iOS bundles and `provenance.json` | Output of the locked packages, verified by `--check` in CI | Regenerated from the updated lockfiles during maintenance |

## Build selections and compatibility boundaries

Security-critical runtimes retain verified exact selections. Ordinary libraries
use compatibility ranges with their resolved versions recorded in lockfiles.
Maintenance checks both for newer releases; recorded does not mean frozen.

- **Node LTS** runs the signed Built-in agent and managed adapter tools.
  Launch reuses the recorded installed runtime without a metadata lookup; a
  first installation may download its checksummed archive. Only LTS lines are
  selected, never Current. CI and release builds use the same release
  (`node-version-file: default-agent/.node-version`). Linux images follow the
  same LTS line (`node:<major>-trixie-slim`); `--pull --no-cache` picks up its
  newest patch and Debian security updates on every image build.
- **CEF** is compiled and signed into the app. The newest stable build is
  always proposed: Chromium ships security fixes only on its current major.
- **Sparkle** delivers every later fix, so the Xcode project requires the exact
  release commit, and its signing tools come from the same release record.
  Major lines are proposed with the other majors and need careful review.
- **Peekaboo** accepts compatible releases from the tested release floor. Its
  exact build selection lives in the shared native lockfile; maintenance validates
  automation API compatibility before changing that snapshot.
- **Pi family and Chord** must resolve to one release, because the desktop
  and mobile bridges share their data contracts. A partially published release
  is skipped.
- **Pyodide and esbuild** produce the offline iOS resources and their
  provenance. They refresh together with the generated files.

## Compatibility ranges on installed apps

The Settings SDK updater (`default-agent/src/sdk-management.mjs`) reads the
**bundled** `package.json` range as its only compatibility policy. It installs
the newest stable release inside that range into a new generation, verifies the
imports it uses, and activates it atomically. Running sessions keep their
generation, and unrelated packages stay at their installed versions. A failed
or cancelled candidate is discarded. A newer release outside the range is
reported as needing a Woven Matter update rather than hidden. The next app
build carries the wider range that the accepted maintenance PR introduced.

Agent CLIs update the same way from Settings: ACP adapters take the latest
release at or above their catalog minimum. OpenCode and Executor stay on v2,
because v2 is the API Woven Matter implements. Maintenance must identify a
new upstream API major and the integration work needed to support it.

Updates start only from Settings or explicit workspace actions; there is no
background updater.

## Source maintenance

Maintenance belongs in an owner-run agent task or a manual session. Do not add
Dependabot or GitHub-hosted dependency proposal schedules. The former monolithic
refresh script has been removed. External maintenance jobs are configured separately; this PR does not create
or alter them.

- Scan the complete dependency declarations and runtime records against current
  upstream releases, including ordinary npm packages, coordinated SDK families,
  native components, and GitHub Actions. A scan does not install packages or
  build the apps. If there are no updates, finish without changing the tree.
- Prepare actual updates in an isolated worktree based on current `main`.
  Keep declarations, lockfiles, runtime checksums, notices, and generated
  resources coherent. Use package-manager tooling to regenerate lockfiles;
  never hand-edit the shared native graph. Keep Pi packages and Chord on one
  fully published release.
- Regenerate affected mobile resources with
  `node scripts/build-ios-pi-runtime.mjs` and
  `node scripts/build-ios-embedded-runtime.mjs` after updating their locked
  inputs. These generate offline resources, not native app builds.
- Review breaking changes and fix affected integration code. Run focused checks
  for the changes and use existing PR CI for native validation. Report any
  platform-specific resolution or validation still pending; version metadata
  alone does not establish native compatibility.
- Open or update one focused PR with the changes, compatibility notes, and
  actual validation results. Never auto-merge, release, or deploy.

`app/Package.resolved` remains the canonical combined SwiftPM/Xcode graph.
Normal package tests use `--force-resolved-versions`, and native builds use
`-onlyUsePackageVersionsFromResolvedFile`, so both consume that one snapshot
without pruning each other's records or selecting new versions. The companion
integration package references the same file through a symlink, and its test
command also freezes resolution; it has no independently selected graph.

Every proposal flags updates outside the current caret line (majors, and 0.x
minors) for review of upstream release notes.

## GitHub Actions

Read-only CI and analytics helpers follow their upstream default branch
(`@main`). Workflows holding write tokens or signing material pin the exact
current release commit, with a comment naming the reason: `release.yml`,
`refresh-release.yml`, and `pr-author.yml`. The maintenance agent reviews those
SHAs against current released versions. There is no blanket SHA requirement.
Linux jobs use `ubuntu-latest`. macOS jobs use `macos-26`, because the app needs
that SDK.

## Delivery

Merging source changes updates nothing that is already installed. Node, CEF,
Sparkle, Peekaboo, and the bundled SDK snapshot reach installed Mac apps only
in a signed app or refresh build (`.github/release-refresh.json`). iOS bundled
JavaScript, Python, and their provenance require an App Store build. Remote
workspaces and Executor pick up a new image definition when the user explicitly
updates or reinstalls them. Release, publication, and deployment keep their
explicit-approval requirements.
