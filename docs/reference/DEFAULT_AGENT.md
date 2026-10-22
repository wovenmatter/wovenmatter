# Pi Durable implementation

The native app adds `AgentRuntimeKind.defaultAgent`; the eight external harnesses
remain in the installation catalog. Local discovery resolves only the app-bundled
Node executable and `default-agent/src/main.mjs`. The helper imports the bundled
Pi Durable SDK directly and exposes ACP to reuse the native conversation, tool activity,
notes, persistence, and model-control presentation. It never invokes the
external `pi` command.

`default-agent/package-lock.json` is the tested SDK dependency graph; builds and
the workspace image install it with `npm ci`. The macOS build bundles the Node
LTS release named in `default-agent/.node-version` and verifies its official
archive SHA-256 values. Linux images follow the same LTS line. Node receives its
JIT entitlement when signed. SDK dependencies and runtime binaries are build
products, not checked into Git. Remote deployment archives include only the
helper's source and package manifests; local binaries, dependencies, tests, and
build caches are not uploaded. Daily source-maintenance PRs keep these records
on current releases; see [the dependency policy](../DEPENDENCIES.md).

External harness installs and updates resolve the newest supported release at
the time of the operation. ACP adapters take their latest release at or above
the catalog minimum. OpenCode stays on stable v2, the server API Woven Matter
implements. Each installation freezes the concrete version it selected.

SDK updates use the bundled `package.json` range as their compatibility policy.
They select the newest stable Pi or Claude SDK release in that range, and Pi
only selects a release published for every Pi package and Chord. A newer
release outside the range is shown as needing a Woven Matter update.

SDK management is scoped to the executing location. Installed-version reads use
package metadata only; registry checks and updates are explicit user actions.
The macOS bundle includes npm alongside its pinned Node distribution so updates
do not depend on a user-installed package manager. Installation occurs under
`<agent-directory>/sdk-runtime/generations`, outside the signed app bundle.
Updates stage a complete locked dependency graph, keep unrelated packages at
their installed versions, keep the Pi packages aligned, disable npm lifecycle
scripts, and verify required SDK exports before atomically activating an
immutable generation. A failed or cancelled candidate is discarded. Existing generations remain
available to running helpers. A helper-source fingerprint prevents an app
update from selecting an older copied helper implementation.

The blocking local maintenance loop owns an OS thread, so saturation of Swift's
cooperative executor or the shared dispatch pool cannot prevent helper admission
and cancellation. Local installer cancellation is confined to the owned maintenance process group and
escalates if its children ignore termination. Once activation commits, later
worker restart or label refresh failures do not turn the installation into a
failure; installed-version metadata remains the source of truth. A successful
update invalidates cached full and enabled model labels for every scope using
that installation, without eagerly loading the full model catalog.

SDK export and native-signature checks cover the inspected package contract.
They do not prove an unseen vendor release preserves native authentication
storage behavior. Claude integration continues to rely on the native secure
storage environment and the existing filesystem policy; changes to those
upstream conventions require compatibility review.

Local ACP starts through `main.mjs`, which selects a generation before importing
SDK code. The remote HTTP service delegates Pi Durable execution to a managed child
process, retaining credentials only in the existing private process boundary.
It waits for active work and admission leases before switching generations;
scheduled runs hold a lease through setup and completion. SDK commands use the
same authenticated workspace connection as other maintenance operations. The
native background service owns update jobs across settings navigation; status,
progress, and errors are scoped to their workspace.

`DefaultAgentSettingsScope` stores non-secret preferences and per-workspace
replacements. API keys and owned OAuth credentials use macOS Keychain.
Connections is the central account management surface for Pi Durable, Usage,
and Dictation. Global OpenRouter keeps its existing shared Keychain item. Local
helpers receive access-only credentials over private pipes.
`ProviderAccountCoordinator` owns renewal and saves rotated credentials before
publishing new snapshots. External harness sign-ins are separate and their
credential stores are never imported. Ordinary message checks compare
cached revisions and deadlines without Keychain or network access.

Remote configuration travels over the existing authenticated workspace service
connection and is encrypted using AES-256-GCM in the persistent workspace volume.
The per-workspace key persists only in Mac Keychain; a restarted helper stays
locked until the Mac reconnects. Shared OAuth exports contain no refresh tokens.
Independent remote sign-ins remain encrypted and take precedence. See
[credential ownership](../architecture/DEFAULT_AGENT_CREDENTIALS.md) for lifecycle,
migration, recovery, and protection boundaries.

Remote SDK sessions and accepted operations are owned by
the workspace service, not an SSH reader. The helper inside `docker exec` only
attaches to those operations. Accepted native run UUIDs make duplicate submissions
idempotent; journals and completion snapshots recover results after disconnect.
Snapshots reconcile only exact run/conversation identities belonging to Pi Durable. Service restarts do not replay accepted work.

Search is an explicit Exa adapter, with a separate credential slot and bounded
results. Model providers are independent of search providers. Adding a search
provider requires its own adapter, key entry, and selection option; entering an
arbitrary key does not imply protocol compatibility.

Deterministic checks: `npm test --prefix default-agent`, Swift package tests,
remote service tests, and `scripts/test-changes.sh --all`. None consume model or
search services. Live provider login, inference, billing/quota behavior, and a
real remote-host disconnect remain separate acceptance checks.

## Connections, dictation, and custom servers

The app-owned coordinator supplies access-only snapshots to Usage and Pi Durable
transports. Concurrent refreshes coalesce. Usage HTTP 401 responses can request
one early renewal through the same lock, with a compare-and-swap Keychain save so
sign-out or a replacement account wins. Global connections serve Usage;
workspace overrides serve Pi Durable. Usage does not restore persisted quotas
belonging to a previous shared account or independently signed-in harness.

`DictationSession` owns one native recording on the interface device, shared by
Mac and iPhone. `AppleDictationEngine` uses SpeechAnalyzer with SpeechTranscriber,
or DictationTranscriber for a supported language/device where appropriate.
Apple-managed language assets are prepared only on an explicit recording action.
The microphone stream is converted to the analyzer's negotiated audio format;
audio is neither stored nor forwarded through workspace RPC. Finalized text
segments are accumulated by audio range, and volatile revisions are preview-only.
Stop drains and finalizes the analyzer before insertion. Cancellation fences late
results and retains resource ownership until native work has settled. Capture
interruptions retain completed text for explicit insertion where possible.

Each native editor exposes a `DictationEditor` bridge. Stop captures its logical
identity, current text, and UTF-16 selection. Insertion uses the platform's native text
system for rich text and one undo group. Non-overlapping edits can be reconciled;
a reused/closed editor or conflicting edit retains the final transcript for
explicit insertion. Leaving the workspace always stops capture. Test fixtures
inject permission, credentials, transport, and audio without accessing providers,
Keychain, or the microphone.

Local server URLs/catalogs use non-secret preferences; keys use Keychain and
remote encrypted credential snapshots. Explicit Connect checks `/models` and a
small, non-stored `/responses` turn. Redirects are rejected, responses are bounded,
and failures keep the saved connection intact. Each server gets its own stable
provider ID, so duplicate model names across servers remain distinct. Keys are
literal credential values, never shell expressions or environment variable names.
URLs are resolved from the workspace running the agent; localhost is not a tunnel
to the Mac from a remote workspace.

Live acceptance remains required: Woven Matter's issued Grok OAuth token must
actually be accepted by STT, and the account's usage must be checked before/after
user-driven dictation. xAI source support alone does not establish subscription
entitlement, included allowance, or billing attribution for a particular account.

## Claude model backend

The bundled Claude Agent SDK bundles Anthropic’s signed, unmodified Claude Code
runtime. Pi remains the owner of the agent loop, tool execution, approvals,
history, and compaction. Claude acts as a model client with native tools, skills,
settings, and session persistence disabled for model requests. This follows the
host-loop design of [Nous’s Hermes Claude subscription plugin](https://hermes-agent.nousresearch.com/docs/plugins/claude-subscription-directsdk).

A per-request loopback relay admits one upstream generation and captures its
stream. Native recovery attempts are rejected locally so they cannot replace the
first response or trigger extra model calls. Native authorization headers pass
through memory only; the relay never logs or persists them. Structured assistant
replay relies on the supported SDK transport and is covered by a real-runtime test
against a synthetic local endpoint. Model metadata uses a conservative 200K
context budget; token counts do not establish monetary charges.

`claude-subscription` and `anthropic` are distinct provider identities, so their
models, credentials, and fallback choices cannot silently exchange billing modes.
The model selector includes native runtime model discovery. Native account status
is metadata only; the app neither reads credential files nor receives refresh
credentials from Claude. The Usage page uses that status rather than reading the
native subscription token to fetch quota information.

Connections starts the bundled runtime’s native sign-in locally or through the
workspace’s existing SSH/docker-exec route. The authorization link appears beneath
the account; the user completes sign-in in their browser.
No authentication UI is driven by automated tests. On macOS,
`CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps a stable private path that identifies the
native Keychain entry. An `everyone deny add_file` macOS ACL blocks regular-file
creation, including temporary files used by the plaintext fallback. Owner mode
`0700` still permits the selected runtime to create and remove its
`.storage-write.lock` directory before accessing Keychain. The ACL is installed
before enabling directory writes; existing non-directory entries stop setup
without reading or removing their contents. Runtime settings use a separate
writable config directory. A native login exit code of zero is followed by a
native status check; an unsaved or unverifiable connection is reported as a
failure. This storage contract must be rechecked when updating the runtime pin.
Linux uses a private, verified tmpfs directory for native state. Host swap and
memory snapshots remain outside the file-storage guarantee.

The composer’s permission setting gates Pi write/edit/shell tools; approvals use
ACP locally and a cancellable request queue through the remote service. Remote
reconnection can reattach to a pending approval without replaying a tool. Thinking
levels are advertised from the selected model’s supported levels. Existing stored
runtime IDs, session paths, and preference keys remain unchanged by the rename.
