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
| `default-agent/package-lock.json`, `ios/EmbeddedRuntime/package-lock.json`, `bots/package-lock.json` | Exact tested snapshot with integrity hashes, installed with `npm ci` | The same PRs |
| `app/Package.resolved` | Shared SwiftPM/Xcode graph: Sparkle and any transitive packages | Native package-manager tooling during maintenance |
| `default-agent/.node-version` and the Node checksums in `scripts/prepare-default-agent.sh` and `LocalACPManagedRuntime.swift` | One current stable Node release and its official archive SHA-256 values | Maintenance PR, all copies together |
| `remote/host/runtime-versions.json` | The same Node release's Linux archive SHA-256 values and the lockfile's Playwright version | The same maintenance PR; host bundle tests reject drift |
| `dockerVersion` and `dockerSHA256` in `remote/host/runtime-versions.json` | The Docker Engine static release (`download.docker.com/linux/static/stable`) that Linux bot engines install, with its x86_64 and aarch64 archive SHA-256 values | Maintenance PR; both checksums together |
| `bots/image/Dockerfile` (`NODE_VERSION` with its two Linux SHA-256 values, `PLAYWRIGHT_VERSION`) | The bot image's copy of the same Node and Playwright selections; Ubuntu 26.04 packages float and are upgraded at build and by the bots Update | The same maintenance PR, kept equal to `remote/host/runtime-versions.json` |
| `remote/npm-runtime/package-lock.json` | Locked security replacements for npm's vendored dependencies, shared by image builds and each native host release's private npm | Dependency maintenance; runtime API and installer tests validate both uses |
| `harnesses/npm-version.json` | Current private Mac npm archive and registry integrity, with the existing locked `remote/npm-runtime` vendor repairs | Maintenance PR; managed CLI and bundled SDK updater verification |
| `app/Automation/cua-version.json` | Exact Cua Driver archive/executable digests, source and signing identity | Maintenance PR with desktop acceptance |
| `app/Browser/cef-version.json` | Exact CEF build and archive SHA-1 values per architecture | Maintenance PR |
| `remote/library/build-version.json` | Swift toolchain image digest, Static Linux SDK archive SHA-256, and SQLite amalgamation SHA-256 for the Linux `wovenmatter-library` build | Maintenance PR, all together with `app/Package.resolved` |
| `app/VMHelper/guest-version.json` and `app/VMHelper/Guest/docker-archive-keyring.asc` | Woven Mac VM guest: Ubuntu cloud image serial, URL, size and SHA-256; Docker apt repository, signing-key fingerprint and file SHA-256, exact `docker-ce` and `containerd.io` versions | Maintenance PR, record and key together |
| `app/Updater/sparkle-version.json` and the Xcode Sparkle revision | Release, exact commit, and tools archive SHA-256 for the updater | Maintenance PR, both together |
| Generated iOS bundles and `provenance.json` | Output of the locked packages, verified by `--check` in CI | Regenerated from the updated lockfiles during maintenance |

## Build selections and compatibility boundaries

Security-critical runtimes retain verified exact selections. Ordinary libraries
use minimum-only ranges with their resolved versions recorded in lockfiles.
Maintenance checks both for newer releases; recorded does not mean frozen.

- **Docker Engine** for Linux bots is an exact static release, because the
  bot engine runs as root with a verified, distribution-independent binary set
  (dockerd, containerd, runc, docker-proxy, docker-init) on Ubuntu, Debian and
  Arch alike. `remote-host.sh` downloads it once per host and the root helper
  re-verifies the SHA-256 before installing it. Maintenance selects the newest
  stable `docker-<version>.tgz` (no release candidates) and records both
  architectures' checksums. Validation: `scripts/test-support/test_bots_engine.py`
  in CI, and the bots install, egress and uninstall checks on a Linux host
  before release. Installed hosts pick up a new selection on update; the
  engine restarts only when its binaries or configuration changed.
- **Node** runs the signed Built-in agent and managed adapter tools.
  Launch reuses the recorded installed runtime without a metadata lookup; a
  first installation may download its checksummed archive. Select the newest
  stable release, including Current; do not restrict selection to LTS. Exclude
  nightlies and prereleases. CI and release builds use the same release
  (`node-version-file: default-agent/.node-version`); local test scripts run the
  bots suite through `scripts/with-pinned-node.sh`, which on a Mac with another
  default Node uses the checksummed copy `prepare-default-agent.sh` caches. Linux images follow the
  same stable major (`node:<major>-trixie-slim`); `--pull --no-cache` picks up its
  newest patch and Debian security updates on every image build. Workspace
  creation may reuse matching local contents for less than 24 hours; an explicit
  container update always rebuilds. See [image reuse](reference/REMOTE_WORKSPACES.md#image-reuse-and-build-progress). The workspace
  image also raises npm to its tested current stable minimum (`>=12.2.2`), since
  Node's bundled npm may lag. Dependency maintenance reviews that Dockerfile
  floor; locked installs and the container smoke test validate CLI compatibility.
  Unused bundled Yarn is removed from the workspace image.
- **Remote workspace tools** rebuild curl/libcurl 8.23.0 from authenticated
  Debian unstable source against the stable runtime ABI. This replaces the
  older stable and stable-backports builds, including the newly disclosed
  HTTP/2 upload use-after-free affecting curl through 8.22.0.
  The image copies Python 3.15.2 from the official `python:3.15.2-slim-trixie`
  multi-architecture image, now published for amd64 and arm64. Its manifest-index
  digest is recorded in `remote/Dockerfile` to preserve the verified interpreter,
  native modules, and Debian ABI together. The current image rebuild uses the
  current official Debian base refresh for both amd64 and arm64, retaining the same
  Python source checksum, build options, and runtime entry points. This replaces
  the temporary source build used while the registry lagged the expedited
  security release.
  Maintenance checks the current stable Python release, official image recipe,
  both platform configurations, and image digest; refresh all records together.
  The final image still upgrades its Debian runtime libraries at build time.
  Tested minimums are
  pip 26.3 and setuptools 84.2.1, instead of Debian's older interpreter and
  vulnerable bundled venv wheel. The SQLite, TLS, and isolated execution paths
  are exercised on native amd64 and arm64 hosts in the container tests. Local
  checks without Docker validate the recipe but cannot replace those builds.
  Archive::Tar 3.14 replaces Debian's affected module in both remote images
  after its upstream test suite passes. The standalone Executor image applies
  the same curl and base-package refresh before installing its exact resolved
  V2 package.
  They use GitHub CLI's official signed stable APT
  repository (tested minimum 2.104.0), with the published keyring SHA-256 checked
  before trusting it. Debian's older CLI retains CVE-2026-48501. Maintenance
  reviews both the floor and signing-key record against upstream.
  OpenSSH clients are built from the current 10.6p2 source in a separate image
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
  npm 12.2.2 vendors undici 6.29.1, ip-address 10.7.5 and minimatch 10.2.5.
  Its bundled graph still needs the IP parser and glob security repairs below.
  The workspace image retains the same reviewed current HTTP dispatcher across
  Mac and Linux tooling, with tuple-header redirect credential stripping covered
  by provider-free fixtures. It applies the independently locked security selection
  in `remote/npm-runtime` (tested undici 8.12.4, ip-address 10.7.6 and minimatch 11.0.8), addressing CVE-2026-111997,
  GHSA-xjj6-f33q-929c and the
  related denial-of-service advisories. npm ignores overrides for its bundled
  dependencies, so this replacement is explicit in the image definition.
  Maintenance reviews npm's vendored selections on every refresh and removes
  the replacement once npm ships a secure version. Image construction tests
  actual npm registry installation and `npm ci`; container validation checks
  that npm resolves the intended module. The 10.7.6 IP parser also escapes
  invalid IPv6 characters in HTML error diagnostics; provider-free fixtures retain address classification and verify
  that escaping. Audit both lockfiles separately.
  The Executor image consumes the same npm runtime lock, plus
  `remote/executor-runtime/package-lock.json` for sharp 0.35.5 and its native
  libvips packages. This exact overlay is required because the newest supported
  Executor V2 package embeds affected sharp 0.35.4. Since beta.37 the npm
  package is a launcher that downloads its separately checksummed native archive.
  Mac installation materializes that archive in a private candidate generation
  before retiring the active runtime, verifies its executable version, and retains
  the archive digest with provenance. It never uses or prunes the user's shared
  launcher cache. The Linux image materializes the same selected archive during
  construction, then repairs its `native/runtime/node_modules` tree and starts
  the prepared native executable directly. The image verifies the
  replacement loads, then runs the unchanged provider-free V2 behavior suite.
  Executor archives also retain ws 8.21.0, which lacks the automatic-pong
  queue bound. The Linux overlay installs locked ws 8.23.0; Mac candidates copy
  the helper's locked ws package before promotion, retain its registry integrity
  and file digest in provenance, and refuse altered or unrepaired generations.
  The original archive, executable and Executor manifest remain intact;
  only the separately loaded transport package is replaced. Candidate-failure,
  tamper-refusal and real provider-free runtime tests validate this repair.
  Executor also selects only the ncurses, acl, and util-linux source repairs it
  needs; do not install the workspace browser-library repairs into that smaller
  image without a runtime dependency.
  npm also vendors minimatch 10.2.5, affected by GHSA-g3hv-75wg-m249. The
  same graph replaces minimatch with 11.0.8 and its locked dependency closure.
  Mac, native Linux and all container paths copy and verify every graph module,
  including scoped dependencies; npm's actual install/ci behavior and bounded
  glob-pattern fixtures validate this major migration. Keep this replacement
  until npm's bundled graph excludes affected minimatch releases.
- **Mac npm** is selected independently of the Node archive, whose bundled npm
  may lag. `harnesses/prepare-npm.mjs` verifies the recorded npm archive integrity,
  applies the same locked vendor repairs used by Linux, verifies
  their APIs, and retains provenance. Immutable cached selections supply
  managed CLI installs, the locked bundle SDK installation, and the bundled SDK
  updater; bootstrap npm only unpacks the verified archive/security graph. The
  bundle dependency cache includes the private tooling provenance fingerprint,
  so an npm or vendor-repair refresh rebuilds that installation. No global npm
  or active Node tree changes.
  Bot image builds consume the same npm archive, shared preparer and locked
  vendor repairs before installing Playwright. Their build context carries
  these canonical inputs from app resources or a native host bundle, so a
  tooling change also changes the image content hash. Node archive npm remains
  bootstrap-only in that path. Provider-free archive and npm fixtures validate
  selection and integrity; a running Docker daemon is needed for image execution.
  Maintenance compares this npm record with current stable npm and validates
  actual registry installs, lockfiles, SDK updates and patched runtime APIs.
- **CEF** is compiled and signed into the app. The newest stable build is
  always proposed: Chromium ships security fixes only on its current major.
- **Woven Mac VM guest** (bots engine on a Mac, see
  [Woven everywhere](architecture/WOVEN_EVERYWHERE.md#mac-vm)) is an exact
  selection for security and core function: a VM that changed itself broke
  earlier tests (the guest auto-upgraded its kernel), and Woven must be able
  to snapshot, update and roll back as one step. The official Ubuntu 26.04 LTS
  arm64 cloud image is pinned by serial directory and SHA-256 rather than
  built locally, so it stays Canonical's signed, reproducibly published
  artifact; the helper verifies size and digest before converting it.
  `docker-ce`, `docker-ce-cli` and `containerd.io` are pinned to exact
  versions from Docker's apt repository, verified with the bundled signing key
  whose fingerprint and digest are recorded (the helper refuses a key that
  does not match). Maintenance proposes the newest image serial and Docker
  Engine release together; validation boots a fresh VM and runs the Mac VM
  checks (engine socket, egress, exec half-close, previews). Installed VMs
  move to new Docker pins and current Ubuntu security updates only through
  Woven's Update action, which snapshots first and rolls back on failure; a
  new image serial affects only new installs.
- **Sparkle** delivers every later fix, so the Xcode project requires the exact
  release commit, and its signing tools come from the same release record.
  Major lines are proposed with the other majors and need careful review.
- **Cua Driver** is the sole native Computer Use engine. `app/Automation/cua-version.json`
  records the current tested release, source revision, universal archive size and
  SHA-256, executable SHA-256, and upstream signing team. This exact selection is
  required because it executes desktop input under the GUI's macOS permissions.
  `scripts/prepare-cua.py` verifies the download and executable, preserves the
  upstream signature, and bundles only the self-contained universal executable
  and notices. Builds never run an upstream installer or update the runtime.
  Maintenance checks Cua's non-nightly release channel, including new majors and
  0.x minors, and refreshes every record and notice together. Upstream currently
  marks even its numbered driver releases as GitHub prereleases to keep the
  monorepo Latest pointer separate. Its release notes identify plain SemVer
  driver releases as stable; the current selection is 0.47.24. The driver refuses input to macOS security
  and consent prompts.
  The driver is spawned directly by the signed GUI, without a Node SDK or
  additional native libraries. Woven negotiates MCP 2025-06-18 and refuses an
  unsupported initialize response before dispatching desktop tools.
  Provider-free tests cover the MCP contract,
  authorization, lifecycle, cancellation, and packaging integrity. The opt-in
  `scripts/test-cua-desktop.sh` verifies actual input and capture through Woven MCP
  against a disposable native fixture, including background focus preservation.
  Signed-app Accessibility/Screen Recording grants are required for that check.
- **Swift on Linux** (`wovenmatter-library` and the portable library targets).
  `apple/swift-crypto` (floor 5.1.1, transitive `swift-asn1`) replaces CryptoKit
  only on Linux: every use is `#if canImport(CryptoKit) … #else import Crypto`,
  and the package product is conditioned on `.linux`, so Apple builds never
  compile it. Its declaration is a minimum-only range (`"5.1.1"..<"1000.0.0"`)
  and `app/Package.resolved` records the selection; generate both SwiftPM and
  Xcode pins with tooling (`swift package resolve`, then
  `xcodebuild -resolvePackageDependencies`). `shared/` has no Linux dependency:
  it derives identifiers with an internal SHA-256 that its tests check
  against published vectors and CryptoKit. On Linux, `CSQLite` links the
  distribution's SQLite for tests (`libsqlite3-dev`, FTS5 and JSON required);
  the shipped static binary links the SQLite amalgamation recorded in
  `remote/library/build-version.json`, compiled with FTS5 and math functions.
  That binary is an exact selection because it is fully static: the Swift
  toolchain image (by digest), the Static Linux SDK (musl) archive and the
  amalgamation are verified by SHA-256 before use, and SwiftPM verifies the SDK
  again on install. Maintenance moves all three to the current stable
  releases together (the SDK must match the toolchain exactly), regenerates
  the resolved graph, and validates with `scripts/test-linux-library.sh` and
  `scripts/build-linux-library.sh` (manual `linux` validation scope). Hosts
  receive a new binary only in a host bundle from an updated app.
- **MCP TypeScript SDK** uses the current v2 client and server packages. Woven MCP and
  Executor use the supported Streamable HTTP client, with the shared native MCP
  protocol core serving the same focused schemas on Mac, Linux and iOS adapters;
  validate authentication, cancellation and inline results with provider-free fixtures.
  Executor forms without a declared schema dialect retain their prior draft-07
  validation semantics; explicit newer dialects remain supported and tested.
- **Pi family and Chord** must resolve to one release, because the desktop
  and mobile bridges share their data contracts. A partially published release
  is skipped.
  A scoped npm override raises Pi Coding Agent's pinned `undici` to the tested
  `>=8.12.4` security floor, addressing GHSA-4qv8-2p9j-2685,
  GHSA-f72v-6w45-q472, and GHSA-xjj6-f33q-929c. Review this override on every
  Pi refresh and remove it once Pi's own requirement excludes the affected
  releases. Provider-free HTTP security fixtures and the coding-agent suites
  validate the overridden Node dependency; it is not part of the mobile bundle.
  ws 8.23.0 bounds automatic pong queues when a peer floods ping frames but
  stops reading responses. A provider-free loopback regression uses the default
  transport limits, verifies that the flood connection closes, and then checks
  that a healthy peer still receives pongs.
  Chord 1.5.2 declares an optional exact ws 8.21.0 peer, which conflicts with
  the app's current ws 8.23.0 transport. A scoped `$ws` override shares the
  app's tested current transport without editing vendor manifests or ignoring
  peer validation. Real local WebSocket streaming/cancellation fixtures and the
  Chord/Durable suites validate this selection; review it on each Chord refresh.
  Pi AI 1.5.2 also pins older provider clients. Consumer-scoped minimum-only
  overrides select the tested OpenAI 7.56.0, Anthropic 1.8.0, Google GenAI 3.3.0,
  Bedrock Runtime and token providers 3.1168.0, and Smithy Node HTTP handler
  4.14.2 releases without
  changing vendor manifests. Keeping these clients current is required for
  provider API and transport compatibility, including Anthropic's 2026-10-21
  Messages API. Maintenance reviews each upstream requirement and removes an
  override when Pi itself selects an equal or newer client. The committed lock
  records the effective graph; Settings SDK generations retain these overrides.
  The token-provider floor also applies below the SSO credential provider, whose
  current upstream package still pins the previous patch.
  Provider-free loopback fixtures exercise Pi's actual SDK clients, request
  serialization, streaming text/tools, usage and cancellation. They do not
  establish authenticated provider acceptance. The iOS bundle excludes these
  network clients; its generated provenance still follows the shared lock.
  Smithy core 3.40 enables its new retry defaults unconditionally. Pi's Bedrock
  adapter does not forward `maxRetries`, so the dedicated Built-in agent process
  sets Smithy's supported `AWS_MAX_ATTEMPTS=1` before creating clients. Woven's
  conversation boundary owns retries; a real loopback 503 fixture verifies that
  even an inherited retry setting cannot silently replay a provider request.
  GenAI 3 requires Node 22 or newer and defaults the Gemini Developer API to
  `v1`. The recorded Node 26 satisfies that requirement. Pi supplies each model's
  complete versioned base URL with an explicit empty SDK API version, preserving
  existing `v1beta` models and custom endpoints even when the new
  `GOOGLE_GENAI_API_VERSION` environment variable is set. Loopback fixtures cover
  exact versioned paths, streaming tools/usage, and cancellation with GenAI 3.
  Pi Coding Agent 1.5.2 now selects minimatch 11.0.3, which includes the
  GHSA-g3hv-75wg-m249 repair. The consumer-scoped floor advances to the current
  `>=11.0.8` patch, which bounds compiled pattern cache weight and rejects
  excessive extglob recursion. Provider-free model-scope matching and
  bounded adversarial-pattern fixtures validate this
  selection; review the override on every refresh and remove it when Pi itself
  selects the current tested release.
  Pi Durable 1.5 replaces event streams with conversation state watches and
  batches storage commits. The desktop and iOS bridge use state snapshots,
  recover transcript window gaps, and derive progress receipts only from new
  committed entries. Archive/subagent observers use `observeCommits`; SQLite
  migration verifies each batched commit receipt before activation.
- **Bots runtime** (`bots/`) consumes the same Pi family, Chord, Claude Agent
  SDK, typebox and ws selections as `default-agent`, with the same
  consumer-scoped pi-ai provider and Chord `ws` overrides, and minimum-only
  ranges. Its in-container helper ships the runtime's own locked Pi Durable,
  Chord and Pi telemetry packages (copied from `bots/node_modules` into the
  helper volume), so they never drift from the runtime. The bot image builds
  through the Engine API from `bots/image` under a content-hash tag, so a
  changed recipe gives a new image; existing bots move to it with Rebuild.
  `npm test --prefix bots` (type check plus faux-provider suites) validates
  it; `npm run test:engine --prefix bots` with `WOVEN_BOTS_ENGINE_SOCKET` set
  exercises a real engine on request.
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

Agent CLIs, ACP connectors, and connector-owned engines are checked independently.
An up-to-date connector does not establish that its engine or sign-in CLI is current.
Settings selects the newest nondeprecated stable publication for each component;
a stale npm dist-tag cannot hide a newer stable version. Claude's native installer
and updater receive the newest nondeprecated stable CLI version explicitly,
resolved from publication metadata. Native `latest` and `stable` pointers can lag
that publication; unavailable metadata refuses installation rather than retaining
an older configured channel. OpenCode and Executor retain the documented v2 API boundary;
maintenance must review a newer stable API major and implement its migration.

`harnesses/catalog.json` records tested connector and engine minimums separately:
Codex ACP 2.6.0 with Codex 0.167.2, and Claude ACP 0.106.0 with Claude SDK 0.3.323
(native Claude Code 2.1.323). The standalone Codex and Claude sign-in CLIs use their
official current stable release channels. Codex ACP's `^0.166.0` engine range
otherwise keeps its chat engine behind; its `~2.4.0` ACP TypeScript SDK range
also excludes the current 2.6.0. Claude ACP 0.106.0 pins SDK 0.3.322;
the consumer-scoped override selects SDK 0.3.323 independently so engine-only updates
remain eligible when the connector's pin lags. Transcript-write loss
invalidates the native resume marker and refuses tool dispatch/continuation commits;
config-only write loss leaves a valid response intact. Provider-free persistence
fixtures verify canonical replay after recovery. Claude's connector selects protocol SDK
2.6.0 directly. The catalog's independent ACP SDK floor is 2.6.0. Mac and native
Linux/container explicit updates resolve its newest nondeprecated stable
publication independently, retain the vendor manifests, and verify the exact
consumer graph and ACP v1 handshake before activation. SDK-only updates appear
in inventory even when connector and engine are current. Failed candidates
leave the active generation intact. The 2.6 SDK retains stable v1;
its v2 changes remain experimental and do not change Woven Matter's wire API.
The consumer graph created by `harnesses/install-adapter.mjs` therefore declares
the independently selected engine and scopes an npm override to that connector.
This core-function exception keeps the engine used for chat current; it does not
modify upstream manifests, copy credentials, or substitute a standalone CLI.

Each explicit installation/update builds an immutable generation, retains its
npm lockfile and integrity records, verifies package/executable versions and native
Claude signatures, and requires an actual provider-free ACP v1 initialize response
before atomically promoting the executable link. Verification uses an empty,
private configuration with no inherited credentials or executable overrides.
Failed candidates are removed; existing generations stay intact for running
sessions. The Mac and remote installers use the same implementation. System-owned
remote installations remain outside Woven's update ownership.

Maintenance reviews both upstream connector requirements and current engine/CLI
releases, updates catalog minimums, and validates the actual selected pairs plus
host-side session/permission/cancellation interfaces with provider-free fixtures.
This does not establish authenticated provider acceptance on every platform.
Both current connectors still offer experimental ACP v2; Woven negotiates stable
v1 until the stable protocol and implemented session APIs migrate together.

Updates start only from Settings or explicit workspace actions; there is no
background updater.

## Runtime data

Usage API estimates read LiteLLM's public model price file at runtime, only after
someone turns them on. It is display data, not code: it is parsed as untrusted JSON,
size-limited, cached for a day, and never bundled or used for billing. There is no
pinned selection to maintain. A failed download keeps the last saved prices.

Usage also reads Codex's `.jsonl.zst` archives with the Zstandard support in the
bundled Node (`node:zlib`), so there is no separate compression dependency. Remote
hosts do the same, which the remote service's Node 24 minimum guarantees.

## Source maintenance

Maintenance belongs in an owner-run agent task or a manual session. Do not add
Dependabot or GitHub-hosted dependency proposal schedules. The former monolithic
refresh script has been removed. External maintenance jobs are configured separately.

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
  for the changes. PR CI covers portable fixtures; native/mobile/image validation
  uses explicitly requested manual runs. Report any
  platform-specific resolution or validation still pending; version metadata
  alone does not establish native compatibility.
- Open or update one focused PR with the changes, compatibility notes, and
  actual validation results. Never auto-merge, release, or deploy.

`app/Package.resolved` remains the canonical combined SwiftPM/Xcode graph.
Normal package tests use `--force-resolved-versions`, and native builds use
`-onlyUsePackageVersionsFromResolvedFile`, so both consume that one snapshot
without pruning each other's records or selecting new versions. The cross-device
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
Linux jobs use `ubuntu-latest`. Desktop builds (release, release caches,
desktop validation) use the `xcode-27` image with `DEVELOPER_DIR` set to
Xcode 27.2, the toolchain the app is developed with; `macos-26` stops at Xcode
26.6, which crashes compiling the app. The `xcode-27` image is a GitHub preview:
move to its GA label, and to newer Xcode releases, during maintenance. iOS
validation stays on `macos-26`.

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
Sparkle, Cua Driver, and the bundled SDK snapshot reach installed Mac apps only
in a signed app or refresh build (`.github/release-refresh.json`). iOS bundled
JavaScript, Python, and their provenance require an App Store build. Remote
workspaces and Executor pick up a new image definition when the user explicitly
updates or reinstalls them. Release, publication, and deployment keep their
explicit-approval requirements.
