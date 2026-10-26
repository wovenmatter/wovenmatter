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
3. **Installed apps** update SDKs independently of app releases through explicit
   Settings actions, accepting stable releases at or above the bundled minimum,
   including new majors, after staged API verification. Agent CLIs follow the
   documented API requirements below.

## What each record means

| Record | Kind | Updated by |
| --- | --- | --- |
| `package.json` minimum-only ranges (`>=version`) | Declaration. The floor is the current tested release; there is no upper cap on stable releases. | Maintenance PRs raise floors, including majors |
| `default-agent/package-lock.json`, `ios/EmbeddedRuntime/package-lock.json` | Exact tested snapshot with integrity hashes, installed with `npm ci` | The same PRs |
| `app/Package.resolved` | Shared SwiftPM/Xcode graph: Peekaboo, Sparkle, and their transitive packages | Native package-manager tooling during maintenance |
| `default-agent/.node-version` and the Node checksums in `scripts/prepare-default-agent.sh` and `LocalACPManagedRuntime.swift` | One current stable Node release and its official archive SHA-256 values | Maintenance PR, all copies together |
| `app/Browser/cef-version.json` | Exact CEF build and archive SHA-1 values per architecture | Maintenance PR |
| `app/Updater/sparkle-version.json` and the Xcode Sparkle revision | Release, exact commit, and tools archive SHA-256 for the updater | Maintenance PR, both together |
| Generated iOS bundles and `provenance.json` | Output of the locked packages, verified by `--check` in CI | Regenerated from the updated lockfiles during maintenance |

## Build selections and compatibility boundaries

Security-critical runtimes retain verified exact selections. Ordinary libraries
use minimum-only ranges with their resolved versions recorded in lockfiles.
Maintenance checks both for newer releases; recorded does not mean frozen.

- **Node** runs the signed Built-in agent and managed adapter tools.
  Launch reuses the recorded installed runtime without a metadata lookup; a
  first installation may download its checksummed archive. Select the newest
  stable release, including Current; do not restrict selection to LTS. Exclude
  nightlies and prereleases. CI and release builds use the same release
  (`node-version-file: default-agent/.node-version`). Linux images follow the
  same stable major (`node:<major>-trixie-slim`); `--pull --no-cache` picks up its
  newest patch and Debian security updates on every image build. The workspace
  image also raises npm to its tested current stable minimum (`>=12.2.1`), since
  Node's bundled npm may lag. Dependency maintenance reviews that Dockerfile
  floor; locked installs and the container smoke test validate CLI compatibility.
  Unused bundled Yarn is removed from the workspace image.
- **Remote workspace tools** take curl/libcurl from signed Debian stable
  backports (tested 8.21.0) to avoid the affected stable-distribution version.
  The image uses the current official Python 3.15 slim runtime, with tested
  minimums of pip 26.2.2 and setuptools 84.2.1, instead of Debian's older
  interpreter and vulnerable bundled venv wheel. The SQLite, TLS, and isolated
  execution paths are exercised against that runtime in the container tests.
  Archive::Tar 3.14 replaces Debian's affected module in both remote images
  after its upstream test suite passes. The standalone Executor image applies
  the same curl and base-package refresh before installing its exact resolved
  V2 package.
  They use GitHub CLI's official signed stable APT
  repository (tested minimum 2.103.2), with the published keyring SHA-256 checked
  before trusting it. Debian's older CLI retains CVE-2026-48501. Maintenance
  reviews both the floor and signing-key record against upstream.
  OpenSSH clients are built from the current 10.6p1 source in a separate image
  stage: the Dockerfile records the exact release/SHA-256 and verifies its
  detached signature against the upstream release-key fingerprint. This
  security exception replaces Debian's client, which retains CVE-2026-60002
  even in current backports. Maintenance must refresh the source record with
  every new upstream stable release; image construction runs OpenSSH's unit
  tests, and container validation checks the installed clients. Build tools
  and the SSH server are not included in the final image.
  Debian stable source packages without timely fixes are rebuilt against the
  stable ABI from authenticated APT source indexes. `remote/security/backports.json`
  records exact source versions, reviewed patch origins, and patch SHA-256 values.
  The current fixed Debian sources are used for tiff 4.7.2 and acl 2.4.0.
  Util-linux retains Debian stable 2.41.5 with the missing 2.41.6 security fixes
  and the later stable-branch symlink-guard correction. Stable libxml2, ncurses, libsndfile, libX11, libXrender,
  and libXtst retain their stable SONAMEs with reviewed Ubuntu or upstream
  security patches. Package builds run their normal Debian checks and symbol
  validation; the libxml2 critical fix also has an AddressSanitizer negative
  control that reproduces CVE-2026-6653 before patching and passes after it.
  Build provenance is retained in the image. Maintenance must remove each local
  rebuild when Debian stable ships an equal or newer fix, refresh exact sources
  and patch checksums together, and validate both amd64 and arm64 images.
  npm 12.2.1 still bundles affected undici 6.29.0. The workspace image replaces
  that vendored module with the current, independently locked security selection
  in `remote/npm-runtime` (tested undici 8.12.3 and ip-address 10.7.5), addressing CVE-2026-111997,
  GHSA-xjj6-f33q-929c and the
  related denial-of-service advisories. npm ignores overrides for its bundled
  dependencies, so this replacement is explicit in the image definition.
  Maintenance reviews npm's vendored selections on every refresh and removes
  the replacement once npm ships a secure version. Image construction tests
  actual npm registry installation and `npm ci`; container validation checks
  that npm resolves the intended module. Audit both lockfiles separately.
  The Executor image consumes the same npm runtime lock, plus
  `remote/executor-runtime/package-lock.json` for sharp 0.35.5 and its native
  libvips packages. This exact overlay is required because the newest supported
  Executor V2 package embeds affected sharp 0.35.4. The image verifies the
  replacement loads, then runs the unchanged provider-free V2 behavior suite.
  Executor also selects only the ncurses, acl, and util-linux source repairs it
  needs; do not install the workspace browser-library repairs into that smaller
  image without a runtime dependency.
- **CEF** is compiled and signed into the app. The newest stable build is
  always proposed: Chromium ships security fixes only on its current major.
- **Sparkle** delivers every later fix, so the Xcode project requires the exact
  release commit, and its signing tools come from the same release record.
  Major lines are proposed with the other majors and need careful review.
- **Peekaboo** accepts compatible releases from the tested release floor. Its
  exact build selection lives in the shared native lockfile; maintenance validates
  automation API compatibility before changing that snapshot.
  Peekaboo 4.9.7 requires exactly AXorcist 0.2.2, so its resolved graph cannot
  accept AXorcist 0.2.3 independently. Retain that upstream constraint until a
  stable Peekaboo release lifts it; check both releases during each maintenance
  scan. Local automation tests and native compilation validate this graph;
  Accessibility permission and real desktop input still need manual acceptance.
- **MCP TypeScript SDK** uses the current v2 client and server packages. The
  automation stdio server and Executor Streamable HTTP client migrate together;
  validate cancellation across both real transports with provider-free fixtures.
  Executor forms without a declared schema dialect retain their prior draft-07
  validation semantics; explicit newer dialects remain supported and tested.
- **Pi family and Chord** must resolve to one release, because the desktop
  and mobile bridges share their data contracts. A partially published release
  is skipped.
  A scoped npm override raises Pi Coding Agent's pinned `undici` to the tested
  `>=8.12.3` security floor, addressing GHSA-4qv8-2p9j-2685,
  GHSA-f72v-6w45-q472, and GHSA-xjj6-f33q-929c. Review this override on every
  Pi refresh and remove it once Pi's own requirement excludes the affected
  releases. Provider-free HTTP security fixtures and the coding-agent suites
  validate the overridden Node dependency; it is not part of the mobile bundle.
- **Pyodide and esbuild** produce the offline iOS resources and their
  provenance. They refresh together with the generated files.

## Minimum versions on installed apps

The Settings SDK updater (`default-agent/src/sdk-management.mjs`) reads the
**bundled** `package.json` minimum (`>=version`). This means that version or any
newer stable release, including a new major. It selects the newest nondeprecated
publication; an older npm `latest` tag does not hide a newer stable release.
It installs into a new generation, verifies the APIs it uses, and activates it
atomically. Running sessions keep their generation, and unrelated packages stay
at their installed versions. A failed or cancelled candidate is discarded.
These checks catch missing APIs, but cannot guarantee that every future upstream
behavior remains compatible; integration fixes and release validation remain
part of maintenance.

Every app release carries the refreshed SDK snapshot. When the bundled source
or dependency graph changes, its fingerprint supersedes SDK generations from
the previous app, so new launches use the release's bundled SDKs without
requiring a separate Settings update.
The fingerprint includes JavaScript helpers in nested source directories, so
broker-only fixes also supersede stale generations without deleting them.

Agent CLIs update the same way from Settings: ACP adapters take the latest
release at or above their catalog minimum. OpenCode and Executor stay on v2,
because v2 is the API Woven Matter implements. Maintenance must identify a
new upstream API major and the integration work needed to support it.
Claude ACP 0.95 serves both stable ACP v1 and an experimental v2 wire protocol;
Woven Matter offers v1 explicitly for its implemented session API. Check the
adapter's router on each refresh and migrate when ACP v2 becomes stable.

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

Every proposal reviews breaking changes, including majors and 0.x minors, and
updates affected integration code before acceptance.

## GitHub Actions

Read-only CI and analytics helpers follow their upstream default branch
(`@main`). Workflows holding write tokens or signing material pin the exact
current release commit, with a comment naming the reason: `release.yml`,
`refresh-release.yml`, and `pr-author.yml`. The maintenance agent reviews those
SHAs against current released versions. There is no blanket SHA requirement.
Linux jobs use `ubuntu-latest`. macOS jobs use `macos-26`, because the app needs
that SDK.

## Before every new release

Refresh dependencies in development before selecting the release commit, even
when separately scheduled maintenance normally keeps them current. Compare
upstream stable releases with the declared packages and Node/native runtime
records; update stale selections, lockfiles, checksums, notices, and generated
resources together. Validate the changes in development CI and merge them before
tagging. Document any concrete upstream blocker instead of silently retaining
an older selection.

The lockfile is the exact snapshot selected for that release. For example,
`>=1.3.0` permits 2.0.0; after maintenance selects and validates 2.0.0, the updated
lockfile makes both CI and the release build install 2.0.0. `npm ci` does not
contact the registry to select newer versions during packaging. This keeps the
shipped graph identical to the tested graph. Reusing an old lockfile without
refreshing it before releases would fail the currency policy.

## Delivery

Merging source changes updates nothing that is already installed. Node, CEF,
Sparkle, Peekaboo, and the bundled SDK snapshot reach installed Mac apps only
in a signed app or refresh build (`.github/release-refresh.json`). iOS bundled
JavaScript, Python, and their provenance require an App Store build. Remote
workspaces and Executor pick up a new image definition when the user explicitly
updates or reinstalls them. Release, publication, and deployment keep their
explicit-approval requirements.
