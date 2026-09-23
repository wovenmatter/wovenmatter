# Built-in implementation

The native app adds `AgentRuntimeKind.defaultAgent`; the eight external harnesses
remain in the installation catalog. Local discovery resolves only the app-bundled
Node executable and `default-agent/src/main.mjs`. The helper imports the pinned
Pi SDK directly and exposes ACP to reuse the native conversation, tool activity,
notes, persistence, and model-control presentation. It never invokes the
external `pi` command.

`default-agent/package-lock.json` pins the SDK dependency graph. The macOS build
prepares Node 24.18.0 with pinned archive SHA-256 checks and includes its license.
The workspace image uses its pinned Node base and installs the same locked SDK.
Node receives its own JIT entitlement when the app is signed. SDK dependencies
and runtime binaries are build products, not checked into Git. Remote deployment
archives include only the helper's source and package manifests; local binaries,
dependencies, tests, and build caches are not uploaded.

`DefaultAgentSettingsScope` stores non-secret preferences and per-workspace
replacements. API keys and owned OAuth credentials use macOS Keychain.
Connections is the central account management surface for Built-in, Usage,
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
Snapshots reconcile only exact run/conversation identities belonging to Built-in. Service restarts do not replay accepted work.

Search is an explicit Exa adapter, with a separate credential slot and bounded
results. Model providers are independent of search providers. Adding a search
provider requires its own adapter, key entry, and selection option; entering an
arbitrary key does not imply protocol compatibility.

Deterministic checks: `npm test --prefix default-agent`, Swift package tests,
remote service tests, and `scripts/test-changes.sh --all`. None consume model or
search services. Live provider login, inference, billing/quota behavior, and a
real remote-host disconnect remain separate acceptance checks.

## Connections, dictation, and custom servers

The app-owned coordinator supplies access-only snapshots to Usage, native Grok
STT, and the Built-in transports. Concurrent refreshes coalesce. An STT or
Usage HTTP 401 can request one early renewal through the same lock, with a
compare-and-swap Keychain save so sign-out or a replacement account wins. Global
connections serve app-wide consumers; workspace overrides serve Built-in.
Usage does not restore persisted quotas belonging to a previous shared account
or an independently signed-in harness.

`DictationModel` owns a single recording across workspace views. Native
AVAudioEngine capture converts microphone input to PCM16LE mono at 16 kHz;
`GrokSpeechClient` sends it directly from the Mac to xAI's STT websocket using
only the shared Grok OAuth access token. It waits for `transcript.created`, sends
binary audio, finishes with `audio.done`, and inserts only `transcript.done`.
There is no API-key billing fallback. A bounded audio queue, connection/final
response deadlines, cancellation, and generation fencing prevent runaway
recordings or late insertion. Neither audio nor transcript previews are saved.
Cancellation is checked again after each suspended response, including a final
transcript arriving after a newer recording starts. Capture/send failures retain
their specific error instead of being masked by socket cancellation.

Each native editor exposes a `DictationEditor` bridge. Stop captures its logical
identity, current text, and UTF-16 selection. Insertion uses AppKit's native text
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

The pinned Claude Agent SDK bundles Anthropic’s signed, unmodified Claude Code
runtime. Pi remains the owner of the agent loop, tool execution, approvals,
history, and compaction. Claude acts as a model client with native tools, skills,
settings, and session persistence disabled for model requests. This follows the
host-loop design of [Nous’s Hermes Claude subscription plugin](https://hermes-agent.nousresearch.com/docs/plugins/claude-subscription-directsdk).

A per-request loopback relay admits one upstream generation and captures its
stream. Native recovery attempts are rejected locally so they cannot replace the
first response or trigger extra model calls. Native authorization headers pass
through memory only; the relay never logs or persists them. Structured assistant
replay relies on the pinned SDK transport and is covered by a real-runtime test
against a synthetic local endpoint. Model metadata uses a conservative 200K
context budget; token counts do not establish monetary charges.

`claude-subscription` and `anthropic` are distinct provider identities, so their
models, credentials, and fallback choices cannot silently exchange billing modes.
The model selector includes native runtime model discovery. Native account status
is metadata only; the app neither reads credential files nor receives refresh
credentials from Claude. The Usage page uses that status rather than reading the
native subscription token to fetch quota information.

The Connections button opens the bundled runtime’s own interactive sign-in in
Terminal, locally or through the workspace’s existing SSH/docker-exec route.
No authentication UI is driven by automated tests. On macOS,
`CLAUDE_SECURESTORAGE_CONFIG_DIR` targets a private, read-only directory: the pinned
runtime uses its path to identify the native Keychain entry, and its disk fallback
cannot write there. Runtime settings use a separate writable config directory.
This native storage contract must be rechecked when updating the runtime pin.
Linux uses a private, verified tmpfs directory for native state. Host swap and
memory snapshots remain outside the file-storage guarantee.

The composer’s permission setting gates Pi write/edit/shell tools; approvals use
ACP locally and a cancellable request queue through the remote service. Remote
reconnection can reattach to a pending approval without replaying a tool. Thinking
levels are advertised from the selected model’s supported levels. Existing stored
runtime IDs, session paths, and preference keys remain unchanged by the rename.
