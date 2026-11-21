# Dependency policy

Woven Matter stays on current upstream releases without forcing app releases
for every package update. Three separate mechanisms do that:

1. **Source maintenance** is run manually or by a separately configured agent
   on an owned machine. It proposes current stable releases, majors included,
   as pull requests. CI and review gate acceptance. Nothing merges, releases,
   publishes, or deploys automatically. This repository installs no dependency
   scheduler or GitHub-hosted proposal automation.
2. **Builds and tests** install the committed npm lockfiles with `npm ci`,
   resolve Swift packages only from the committed `Package.resolved` files, and
   consume the recorded native selections. Dependency refresh belongs in
   maintenance.
3. **Installed apps** update the Pi Durable SDK packages through an explicit
   Settings action, independently of app releases. Agent CLIs and ACP connectors
   follow the rules below.

## What each record means

| Record | Kind | Updated by |
| --- | --- | --- |
| `package.json` minimum-only ranges (`>=version`) | Declaration. The floor is the current tested release; there is no upper cap on stable releases. | Maintenance PRs raise floors, including majors |
| `default-agent/package-lock.json`, `bots/package-lock.json`, `harnesses/npm-runtime/package-lock.json` | Exact tested snapshot with integrity hashes, installed with `npm ci` | The same PRs |
| `server/Package.resolved` | The server's Swift graph: swift-nio, swift-crypto and their transitive packages (swift-asn1, swift-atomics, swift-collections, swift-system) | `swift package resolve` during maintenance |
| `app/Package.resolved` (and its copy in the Xcode workspace) | The app's combined SwiftPM/Xcode graph: Sparkle plus the server's graph, which the app links at its server entry | `xcodebuild -resolvePackageDependencies` during maintenance, after `server/Package.resolved` |
| `default-agent/.node-version` and the Node checksums in `scripts/prepare-default-agent.sh` | One current stable Node release and its official macOS archive SHA-256 values | Maintenance PR, all copies together |
| `harnesses/npm-version.json` | The private Mac npm archive and its registry integrity | Maintenance PR |
| `server/linux-build.json` | The swift.org macOS toolchain package (SHA-256 and signer), the Static Linux SDK archive SHA-256, the SQLite amalgamation SHA-256, and the Linux Node archives' SHA-256 (the release in `default-agent/.node-version`) for the Linux `woven-server` release the Mac app carries | Maintenance PR, all together; the toolchain and SDK must be the same Swift release |
| `DOCKER_VERSION` and `DOCKER_SHA256` in `bots/engine/bots-engine.py` | The Docker Engine static release that Linux bot engines install, with its x86_64 and aarch64 archive SHA-256 values | Maintenance PR; both checksums together |
| `bots/image/toolchain/Dockerfile` (`NODE_VERSION`, `PLAYWRIGHT_VERSION`) | The bot toolchain's copy of the Node and Playwright selections. Bots get it through the runtime's shared volume, so a change updates them in place | The same maintenance PR, kept equal to `default-agent/.node-version` and the lockfile's Playwright |
| `bots/image/Dockerfile` and `bots/image/chromium-packages.txt` | The bot base image: the Ubuntu release, its packages (they float and are upgraded at build and by every bots Update), and Chromium's system libraries from Playwright's Ubuntu list | Refresh `chromium-packages.txt` from `playwright-core`'s native dependency table when Ubuntu or Chromium's libraries change |
| `app/VMHelper/guest-version.json` and `app/VMHelper/Guest/docker-archive-keyring.asc` | The Mac VM guest for the bots engine: Ubuntu cloud image serial, URL, size and SHA-256; Docker apt repository, signing-key fingerprint and file SHA-256, exact `docker-ce` and `containerd.io` versions | Maintenance PR, record and key together |
| `app/Automation/cua-version.json` | Exact Cua Driver archive/executable digests, source and signing identity | Maintenance PR with desktop acceptance |
| `app/Browser/cef-version.json` | Exact CEF build and archive SHA-1 values per architecture | Maintenance PR |
| `app/Updater/sparkle-version.json` and the Xcode Sparkle revision | Release, exact commit, and tools archive SHA-256 for the updater | Maintenance PR, both together |

## Build selections and compatibility boundaries

Security-critical runtimes keep verified exact selections. Ordinary libraries
use minimum-only ranges with their resolved versions recorded in lockfiles.
Maintenance checks both for newer releases; recorded does not mean frozen.

- **Swift packages.** The server uses `apple/swift-nio` for its WebSocket
  server and client on macOS and Linux alike, and `apple/swift-crypto`
  only on Linux, as the replacement for CryptoKit (every use is
  `#if canImport(CryptoKit) … #else import Crypto`, and the product is
  conditioned on `.linux`, so Apple builds never compile it). Both are
  minimum-only ranges (`"x.y.z"..<"1000.0.0"`). `protocol/` has no
  dependencies. Never hand-edit a `Package.resolved`: run
  `swift package resolve --package-path server`, then
  `xcodebuild -resolvePackageDependencies` for the app, so the two graphs
  agree. Tests use `--force-resolved-versions` and app builds use
  `-onlyUsePackageVersionsFromResolvedFile`, so nothing selects new versions
  during a build. On Linux, `CSQLite` links the distribution's SQLite for tests
  (`libsqlite3-dev`, FTS5 and JSON required).
- **The Linux server** (`woven-server`). `scripts/prepare-linux-server.sh`
  cross-compiles it on the Mac, statically linked against musl, for x86_64
  and aarch64, with the swift.org toolchain (unpacked from its signed package,
  never installed; swift.org publishes no checksum for it, so its SHA-256 and
  the Developer ID signer are recorded) and the Static Linux SDK (checksum
  from swift.org's release list, verified again by `swift sdk install`). Xcode's
  compiler cannot use that SDK. SQLite is the recorded amalgamation, compiled
  with FTS5 and math functions. This is an exact selection because the binary
  is fully static. Its child processes get the official Linux Node of
  `default-agent/.node-version` and Pi Durable's packages installed for Linux
  with `npm ci`, all shipped in the release, so a target downloads nothing at
  install. Release builds always build it; Debug builds copy one already built.
  Maintenance moves the toolchain and SDK together. A Linux machine receives a
  new binary only from an updated Mac app.
- **Node** runs the two child processes, Pi Durable and the bots runtime, and
  the managed adapter tools. Select the newest stable release, including
  Current; do not restrict selection to LTS. Exclude nightlies and
  prereleases. CI and release builds use the same release
  (`node-version-file: default-agent/.node-version`); `scripts/test-changes.sh`
  runs the Node suites through `scripts/with-pinned-node.sh`, which on a Mac
  with another default Node uses the checksummed copy
  `prepare-default-agent.sh` caches.
- **Mac npm** is selected independently of the Node archive, whose bundled npm
  may lag. `harnesses/prepare-npm.mjs` verifies the recorded npm archive
  integrity and applies the locked vendor repairs in `harnesses/npm-runtime`
  (undici, ip-address and minimatch; npm ignores overrides for its bundled
  dependencies, so the replacement is explicit). Maintenance reviews npm's
  vendored selections on every refresh and removes a repair once npm ships a
  secure version. No global npm or active Node tree changes.
- **Docker Engine** for Linux bots is an exact static release, because the
  bot engine runs as root with a verified, distribution-independent binary set
  on Ubuntu, Debian and Arch alike. `bots/engine/bots-engine.py install`
  downloads it and verifies the SHA-256 before installing it. Maintenance
  selects the newest stable `docker-<version>.tgz` and records both
  architectures' checksums. The Mac VM selects the same Docker release from
  Docker's signed APT repository.
- **Woven Mac VM guest** (the bots engine on a Mac) is an exact selection for
  security and core function: a VM that changed itself broke earlier tests,
  so nothing in it updates on its own. The
  official Ubuntu LTS arm64 cloud image is pinned by serial directory and
  SHA-256; the helper verifies size and digest before converting it.
  `docker-ce`, `docker-ce-cli` and `containerd.io` are exact versions from
  Docker's apt repository, verified with the bundled signing key whose
  fingerprint and digest are recorded. A new image serial or package pin
  affects only new installs; an installed VM keeps what it was built with.
- **CEF** is compiled and signed into the app. The newest stable build is
  always proposed: Chromium ships security fixes only on its current major.
- **Sparkle** delivers every later fix, so the Xcode project requires the exact
  release commit, and its signing tools come from the same release record.
- **Cua Driver** is the sole native Computer Use engine. This exact selection
  is required because it executes desktop input under the app's macOS
  permissions. `scripts/prepare-cua.py` verifies the download and executable,
  preserves the upstream signature, and bundles only the self-contained
  universal executable and notices. Builds never run an upstream installer.
  Maintenance checks Cua's non-nightly release channel (upstream marks plain
  SemVer driver releases as GitHub prereleases; they are stable) and refreshes
  every record and notice together.
- **Pi family and Chord** must resolve to one release, taken as upstream ships
  it: the versions Pi and Chord pin themselves are not overridden. A known
  vulnerability in one of those pins is reported at release time rather than
  patched inside the package.
- **Bots runtime** (`bots/`) declares the same Pi family, Chord, Claude Agent
  SDK and ws selections as `default-agent` for its type check and tests. At
  run time it never loads its own copy of the SDK packages: it resolves them from the copy Pi Durable runs on that machine
  (`bots/src/pi-durable-sdk.ts`), and packaging removes bots' own copy
  (`scripts/prune-bots-sdk.py`). One SDK update covers both. The bot base
  image and toolchain image build through the Engine API from `bots/image`
  under content-hash tags.

## SDK updates on installed apps

Settings can update Pi Durable's SDK packages (`default-agent/src/sdk.mjs`):
it installs their latest releases into a fresh folder in the server's data
folder, checks that they load, and points `sdk/current` at it. Running
sessions keep the packages they started with; new ones use the update. The
update and the one before it are kept. The bots runtime on that machine uses
the same copy. A failed update is discarded and leaves the working copy active.

Agent CLIs are the person's own native installs: Woven Matter installs a
missing one with its vendor's official installer and updates it with the
vendor's own command, so it records no CLI selection. ACP connectors install
from npm, exactly as published, with the npm bundled beside the server
(`harnesses/install-adapter.mjs`). The server installs the Codex or Claude Code
connector by itself as soon as it finds that CLI without one; it never installs
or updates the CLI to do so. `harnesses/catalog.json` sets no minimum versions
for connectors, CLIs or SDKs: install and update always take the latest.
Updates come only from an explicit Settings action. There is no background
updater.

## Runtime data

Usage API estimates read LiteLLM's public model price file at run time, only
after someone turns them on. It is display data, not code: parsed as untrusted
JSON, size-limited, cached for a day, and never bundled or used for billing.
There is no pinned selection to maintain.

## Source maintenance

Maintenance belongs in an owner-run agent task or a manual session. Do not add
Dependabot or GitHub-hosted dependency proposal schedules.

- Scan the dependency declarations and runtime records above against current
  upstream releases, including GitHub Actions. If there are no updates, finish
  without changing the tree.
- Prepare updates in an isolated worktree based on current `main`. Keep
  declarations, lockfiles, Swift graphs, runtime checksums and notices
  coherent, using package-manager tooling. Keep Pi packages and Chord on one
  fully published release.
- Review breaking changes, including majors and 0.x minors, and fix affected
  code. Validate with `scripts/test-changes.sh`.
- Open one focused PR with the changes and validation results. Never
  auto-merge, release, or deploy.

## GitHub Actions

Read-only CI and analytics helpers follow their upstream default branch
(`@main`). Workflows holding write tokens or signing material pin the exact
current release commit, with a comment naming the reason: `release.yml` and
`pr-author.yml`. Maintenance reviews those SHAs against current releases.
PR CI runs in the official `swift` container image of the release recorded in
`server/linux-build.json`. Desktop jobs (release signing, desktop validation)
use the `xcode-27` image with `DEVELOPER_DIR` set to Xcode 27.2, the
toolchain the app is developed with. Review newer stable Xcode releases and
runner labels during maintenance.

## Releases

Cutting a release starts with `scripts/release-check.py` on a maintainer Mac,
never on GitHub: anything still behind is updated in one development PR, and
known vulnerabilities in shipped code are reported for a decision before the
build. The release ships the selections committed on its release commit: `npm
ci` and frozen Swift resolution never select newer versions during packaging,
so the shipped graph is the tested graph.

## Delivery

Merging source changes updates nothing that is already installed. Node, CEF,
Sparkle, Cua Driver, the bundled SDK snapshot and the Linux server reach
installed machines only in a signed app release. Release, publication, and
deployment keep their explicit-approval requirements.
