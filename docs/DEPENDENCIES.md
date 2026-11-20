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
| `DOCKER_VERSION` and `DOCKER_SHA256` in `bots/engine/bots-engine.py` | The Docker Engine static release (`download.docker.com/linux/static/stable`) that Linux bot engines install, with its x86_64 and aarch64 archive SHA-256 values | Maintenance PR; both checksums together |
| `bots/image/toolchain/Dockerfile` (`NODE_VERSION` with its two Linux SHA-256 values, `PLAYWRIGHT_VERSION`) | The bot toolchain's copy of the same Node and Playwright selections. Bots get it through the runtime's shared volume, so a change updates them in place and never moves them to a new container | The same maintenance PR, kept equal to `remote/host/runtime-versions.json` |
| `bots/image/Dockerfile` and `bots/image/chromium-packages.txt` | The bot base image: the Ubuntu release, its packages (they float and are upgraded at build and by every bots Update), and Chromium's system libraries from Playwright's Ubuntu list. A change moves bots to a new container, carrying what they installed | Refresh `chromium-packages.txt` from `playwright-core`'s native dependency table when Ubuntu or Chromium's libraries change; an update whose Chromium needs more installs them in the container (`playwright install-deps`) |
| `remote/npm-runtime/package-lock.json` | Locked security replacements for npm's vendored dependencies, shared by image builds and each native host release's private npm | Dependency maintenance; runtime API and installer tests validate both uses |
| `harnesses/npm-version.json` | Current private Mac npm archive and registry integrity, with the existing locked `remote/npm-runtime` vendor repairs | Maintenance PR; managed CLI and bundled SDK updater verification |
| `app/Automation/cua-version.json` | Exact Cua Driver archive/executable digests, source and signing identity | Maintenance PR with desktop acceptance |
| `app/Browser/cef-version.json` | Exact CEF build and archive SHA-1 values per architecture | Maintenance PR |
| `server/linux-build.json` | The swift.org macOS toolchain package (SHA-256 and signer), the Static Linux SDK archive SHA-256 (as swift.org publishes it), the SQLite amalgamation SHA-256, and the Linux Node archives' SHA-256 (the release in `default-agent/.node-version`) for the Linux `woven-server` release the Mac app carries | Maintenance PR, all together; the toolchain and SDK must be the same Swift release |
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
  Arch alike. `bots/engine/bots-engine.py install`, run once with sudo,
  downloads it and verifies the SHA-256 before installing it. Maintenance
  selects the newest stable `docker-<version>.tgz` (no release candidates) and
  records both architectures' checksums. Validation: the bots install, egress
  and uninstall checks on a Linux host before release. Running the installer
  again picks up a new selection; the engine restarts only when its binaries
  or configuration changed.
  The static Linux host and the Mac VM both select Docker 29.10.0. Maintenance
  checks the VM's signed Resolute APT publication independently; a static
  archive cannot replace the VM's managed APT packages.
- **Node** runs the signed Built-in agent and managed adapter tools.
  Launch reuses the recorded installed runtime without a metadata lookup; a
  first installation may download its checksummed archive. Select the newest
  stable release, including Current; do not restrict selection to LTS. Exclude
  nightlies and prereleases. CI and release builds use the same release
  (`node-version-file: default-agent/.node-version`); local test scripts run the
  bots suite through `scripts/with-pinned-node.sh`, which on a Mac with another
  default Node uses the checksummed copy `prepare-default-agent.sh` caches. Linux images follow the
  same stable major (`node:<major>-trixie-slim`); `--pull --no-cache` picks up its
  newest patch and Debian security updates on every image build.
- **Executor image tools** (`remote/Executor.Dockerfile`) rebuild curl/libcurl
  8.23.0 from authenticated Debian unstable source against the stable runtime
  ABI. This replaces the older stable and stable-backports builds, including the
  newly disclosed HTTP/2 upload use-after-free affecting curl through 8.22.0.
  Archive::Tar 3.14 replaces Debian's affected module after its upstream test
  suite passes. The image applies the curl and base-package refresh before
  installing its exact resolved V2 package.
  Debian stable source packages without timely fixes are rebuilt against the
  stable ABI from authenticated APT source indexes. `remote/security/backports.json`
  records exact source versions, reviewed patch origins, and patch SHA-256 values.
  The current fixed Debian source is used for acl 2.4.0.
  Util-linux retains Debian stable 2.41.5 with the missing 2.41.6 security fixes
  and the later stable-branch symlink-guard correction. Stable ncurses retains its
  stable SONAME with a reviewed Ubuntu security patch. Package builds run their
  normal Debian checks and symbol validation.
  Build provenance is retained in the image. Maintenance must remove each local
  rebuild when Debian stable ships an equal or newer fix, refresh exact sources
  and patch checksums together, and validate both amd64 and arm64 images.
  npm 12.2.3 vendors undici 6.29.1, ip-address 10.7.5 and minimatch 10.2.5.
  Its bundled graph still needs the IP parser and glob security repairs below.
  Linux host releases and the bots image use the same
  reviewed current HTTP dispatcher as Mac tooling, with tuple-header redirect
  credential stripping covered by provider-free fixtures. They apply the
  independently locked security selection in `remote/npm-runtime` (tested undici
  8.12.4, ip-address 10.7.6 and minimatch 11.0.9), addressing CVE-2026-111997,
  GHSA-xjj6-f33q-929c and the related denial-of-service advisories. npm ignores
  overrides for its bundled dependencies, so this replacement is explicit in the
  install recipe.
  Maintenance reviews npm's vendored selections on every refresh and removes
  the replacement once npm ships a secure version. Image construction tests
  actual npm registry installation and `npm ci`, and checks that npm resolves the
  intended module. The 10.7.6 IP parser also escapes
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
  Current V2 releases lift binary resources, images and audio into separate MCP
  content blocks. The broker restores their references before crossing its JSON
  job boundary, retaining the existing response-size limit. Invalid references
  interrupt the job without replaying it. Broker regressions and the real
  provider-free Executor fixture cover inline and lifted results.
  npm also vendors minimatch 10.2.5, affected by GHSA-g3hv-75wg-m249. The
  same graph replaces minimatch with 11.0.9 and its locked dependency closure.
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
  driver releases as stable. The driver refuses input to macOS security
  and consent prompts.
  The driver is spawned directly by the signed GUI, without a Node SDK or
  additional native libraries. Woven negotiates MCP 2025-06-18 and refuses an
  unsupported initialize response before dispatching desktop tools.
  Provider-free tests cover the MCP contract,
  authorization, lifecycle, cancellation, and packaging integrity. The opt-in
  `scripts/test-cua-desktop.sh` verifies actual input and capture through Woven MCP
  against a disposable native fixture, including background focus preservation.
  Signed-app Accessibility/Screen Recording grants are required for that check.
- **The Linux server** (`woven-server`). `scripts/prepare-linux-server.sh`
  cross-compiles it on the Mac, statically linked against musl, for x86_64
  and aarch64, with the swift.org toolchain (unpacked from its signed package,
  never installed; swift.org publishes no checksum for it, so its SHA-256 and
  the Developer ID signer are recorded) and the Static Linux SDK (checksum
  from swift.org's release list, verified again by `swift sdk install`). Xcode's
  compiler cannot use that SDK. SQLite is the recorded amalgamation, compiled
  with FTS5 and math functions. Its child processes get the official Linux
  Node of `default-agent/.node-version` and Pi Durable's packages installed
  for Linux with `npm ci`, all shipped in the release, so a target downloads
  nothing at install. Release builds always build it; Debug builds copy one
  already built. Maintenance moves the toolchain and SDK together.
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
  overrides select the tested OpenAI 7.60.0, Anthropic 1.10.0, Google GenAI 3.6.0,
  Bedrock Runtime and token providers 3.1171.0, and Smithy Node HTTP handler
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
  `>=11.0.9` patch, which bounds compiled pattern cache weight and rejects
  excessive extglob recursion. The 11.0.9 patch also preserves expanded-range
  semantics inside repeating and negated extglobs; provider-free fixtures cover
  those model/skill selection patterns. Provider-free model-scope matching and
  bounded adversarial-pattern fixtures validate this
  selection; review the override on every refresh and remove it when Pi itself
  selects the current tested release.
  Pi Durable 1.5 replaces event streams with conversation state watches and
  batches storage commits. The desktop and iOS bridge use state snapshots,
  recover transcript window gaps, and derive progress receipts only from new
  committed entries. Archive/subagent observers use `observeCommits`; SQLite
  migration verifies each batched commit receipt before activation.
  Pi Coding Agent also pins brace-expansion 5.0.12. Its consumer-scoped
  `>=5.0.13` override adds the upstream total parser-work bound for hostile
  patterns. Retain it until Pi excludes earlier versions; bounded child-process
  fixtures verify normal expansion, nesting and literal fallback for over-budget
  input.
- **Bots runtime** (`bots/`) declares the same Pi family, Chord, Claude Agent
  SDK, typebox and ws selections as `default-agent`, with the same
  consumer-scoped pi-ai provider and Chord `ws` overrides, and minimum-only
  ranges, for its type check and tests. At run time it never loads its own
  copy of the SDK packages: the machine's Woven server tells it where Pi
  Durable is, it asks Pi Durable's `resolveSDKRuntime` which copy Pi Durable
  runs there (the active Settings SDK update, or the bundled
  `default-agent`), and it resolves `@earendil-works/pi-durable`, `pi-ai`,
  `pi-coding-agent`, `chord` and `@anthropic-ai/claude-agent-sdk` from that
  copy, with that copy's Claude binary (`bots/src/pi-durable-sdk.ts`). A
  resolution outside the copy fails. App and host packaging remove bots' own
  copy of those packages and what only they depend on
  (`remote/host/prune-bots-sdk.py`). One SDK update covers both: the server
  restarts a running bots runtime once a new copy is active. Its in-container
  helper ships the packages its imports load from that copy, as Node resolves
  them there (nested ones included), into the shared volume; they reach
  existing containers on their next Update. The bot base image and
  toolchain image build through the Engine API from `bots/image` and
  `bots/image/toolchain` under content-hash tags. A changed toolchain reaches
  bots in place on their next Update; a changed base image moves them to a new
  container on their next Update or Rebuild, carrying what they installed.
  `npm test --prefix bots` (type check plus faux-provider suites) validates
  it; `npm run test:engine --prefix bots` with `WOVEN_BOTS_ENGINE_SOCKET` set
  exercises a real engine on request.
- **Remote service** (`remote/`) declares no npm packages of its own. Its
  live stream and bots relay (`remote/src/websocket.mjs`) load `ws` from the
  Built-in agent's locked graph (`default-agent/package.json` `>=8.22.2`,
  `default-agent/package-lock.json`), the same selection the bots runtime
  uses. Every host release already installs that graph
  with `npm ci` beside `src/`, as it does for the agent modules `server.mjs`
  loads, so there is one `ws` selection and no second lockfile to keep in
  sync. Maintenance refreshes it with the Built-in agent; `remote/test`
  checks that the loaded copy is the locked one, and the provider-free
  stream and bots relay suites validate the selection.
- **Pyodide and esbuild** produce the offline iOS resources and their
  provenance. They refresh together with the generated files.

## Minimum versions on installed apps

The Settings SDK updater (`default-agent/src/sdk-management.mjs`) reads the
**bundled** `package.json` minimum (`>=version`). This means that version or any
newer stable release, including a new major. It selects the newest nondeprecated
publication; an older npm `latest` tag does not hide a newer stable release.
It installs into a new generation, verifies the APIs it uses, and activates it
atomically. It then deletes the generation it replaced, even if a running
session still uses it; unrelated packages stay at their installed versions. A
failed or cancelled candidate is discarded and leaves the working copy active.
The machine's bots run the same copy and restart onto the update, so where the
bots runtime is installed the candidate must also pass `bots/src/cli.ts
verify-sdk`: bots' whole module graph, the Claude Agent SDK and binary, and the
in-container helper, loaded from the staged copy as bots start. The SDK status
reports a copy missing a package or its Claude binary as inconsistent, and the
update reinstalls it.
These checks catch missing APIs, but cannot guarantee that every future upstream
behavior remains compatible; integration fixes and release validation remain
part of maintenance.

Every app release carries the SDK snapshot committed on its release commit. When the bundled source
or dependency graph changes, its fingerprint supersedes SDK generations from
the previous app, so new launches use the release's bundled SDKs without
requiring a separate Settings update.
The fingerprint includes JavaScript helpers in nested source directories, so
broker-only fixes also supersede stale generations without deleting them.

Agent CLIs and ACP connectors are checked independently. The CLIs are the person's
own native installs: Woven Matter installs a missing one with its vendor's official
installer and updates it with the vendor's own command, so it records no CLI
selection. An up-to-date connector does not establish that the CLI is current.
Each CLI is compared with the channel its vendor's own installer and update command
read, which can trail npm: `releases.openai.com/codex/channels/latest` for Codex,
`downloads.claude.ai/claude-code-releases/latest` for Claude Code, `x.ai/cli/stable`
for Grok Build and `opencode.ai/update/api/latest/cli/npm` for OpenCode 2. Official
installers run with the catalog's arguments and install what their channel names.
For connectors, Settings selects the newest nondeprecated stable npm publication; a
stale npm dist-tag cannot hide a newer stable version. OpenCode and Executor retain
the documented v2 API boundary; maintenance must review a newer stable API major and
implement its migration.

`harnesses/catalog.json` sets no minimum versions for connectors, CLIs or SDKs.
A connector or CLI that is present and runs counts as installed, and an update is
available when npm (for a connector) or the vendor's channel (for a CLI) has a newer
version than the installed one. Install and update always take the latest. The
adapters drive the native Codex and Claude CLIs (`CODEX_PATH`,
`CLAUDE_CODE_EXECUTABLE`). The CLI copy npm bundles inside each adapter package is
never selected, checked or used, so `harnesses/install-adapter.mjs` installs the
adapter exactly as published, with no version overrides and without npm optional
packages: those carry only the adapters' bundled platform CLI builds
(`@openai/codex-<platform>`, `@anthropic-ai/claude-agent-sdk-<platform>`), and an
install requires the native CLI's path. The native Claude CLI has no ACP mode:
Claude ACP is an ACP server built on the Claude Agent SDK, whose `query()` starts the
native CLI and talks to it over stdio. The libraries inside a connector, including
its ACP SDK and Claude ACP's Claude Agent SDK, are the connector's own: they move
only with a connector update and are not listed or tracked separately. The Claude
Agent SDK is otherwise a direct dependency only of the Built-in agent and bots.
Transcript-write loss invalidates the native resume marker and refuses tool
dispatch/continuation commits; config-only write loss leaves a valid response
intact. Provider-free persistence fixtures verify canonical replay after recovery.

Each connector installation or update builds a new generation in
`Installations/<generation>`, retains its npm lockfile and integrity records,
verifies the installed connector version, and requires an actual provider-free ACP
v1 initialize response, with the adapter pointed at the native CLI, before
atomically repointing the executable link. Verification uses an empty, private
configuration with no inherited credentials. Once the link moves, the generation it
pointed to before is deleted at once, even if a running chat still uses it. A failed
candidate is removed and leaves the working generation and link untouched. The Mac
and remote installers use the same implementation. System-owned remote
installations remain outside Woven's update ownership.

Maintenance validates the current connector and CLI releases against host-side
session/permission/cancellation interfaces with provider-free fixtures. This does
not establish authenticated provider acceptance on every platform. Both current
connectors still offer experimental ACP v2; Woven negotiates stable v1 until the
stable protocol and implemented session APIs migrate together.

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
current release commit, with a comment naming the reason: `release.yml` and
`pr-author.yml`. The maintenance agent reviews those
SHAs against current released versions. There is no blanket SHA requirement.
Linux jobs use `ubuntu-latest`. Desktop jobs (release signing, desktop
validation) use the `xcode-27` image with `DEVELOPER_DIR` set to
Xcode 27.2, the toolchain the app is developed with; `macos-26` stops at Xcode
26.6, which crashes compiling the app. The `xcode-27` label is [generally available](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)
on Apple Silicon; the preview and GA labels are the same. Review newer stable
Xcode releases and runner labels during maintenance. iOS
validation stays on `macos-26`.

## Releases

Scheduled maintenance keeps dependencies current. Cutting a release starts with
`scripts/release-check.py` on a maintainer Mac, never on GitHub: anything still
behind is updated in one development PR, and known vulnerabilities in shipped
code are reported for a decision before the build. The release ships the
selections committed on its release commit.

The lockfile is the exact snapshot that release ships. For example,
`>=1.3.0` permits 2.0.0; after maintenance selects and validates 2.0.0, the updated
lockfile makes both CI and the release build install 2.0.0. `npm ci` does not
contact the registry to select newer versions during packaging. This keeps the
shipped graph identical to the tested graph.

## Delivery

Merging source changes updates nothing that is already installed. Node, CEF,
Sparkle, Cua Driver, and the bundled SDK snapshot reach installed Mac apps only
in a signed app release. iOS bundled
JavaScript, Python, and their provenance require an App Store build. Remote
workspaces and Executor pick up a new image definition when the user explicitly
updates or reinstalls them. Release, publication, and deployment keep their
explicit-approval requirements.
