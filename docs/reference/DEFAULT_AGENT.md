# Default Agent implementation

The native app adds `AgentRuntimeKind.defaultAgent`; the eight external harnesses
remain in the installation catalog. Local discovery resolves only the app-bundled
Node executable and `default-agent/src/main.mjs`. The helper imports the pinned
Pi SDK directly and exposes ACP to reuse the native conversation, tools, notes,
permissions, persistence, and model-control presentation. It never invokes the
external `pi` command.

`default-agent/package-lock.json` pins the SDK dependency graph. The macOS build
prepares Node 24.18.0 with pinned archive SHA-256 checks and includes its license.
The workspace image uses its pinned Node base and installs the same locked SDK.
Node receives its own JIT entitlement when the app is signed. SDK dependencies
and runtime binaries are build products, not checked into Git.

`DefaultAgentSettingsScope` stores non-secret preferences and per-workspace
replacements. API keys and owned OAuth credentials use macOS Keychain. Connections is the central account management surface for Default Agent, Usage,
and Dictation. Global OpenRouter keeps its existing shared Keychain item. Local helpers receive access-only
credentials over private pipes. `ProviderAccountCoordinator` owns renewal and saves rotated
credentials before publishing new snapshots. External harness sign-ins are separate
and their credential stores are never imported. Ordinary message checks compare
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
Snapshots reconcile only exact run/conversation identities belonging to Default
Agent. Service restarts do not replay accepted work.

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
STT, and the Default Agent transports. Concurrent refreshes coalesce. An STT or
Usage HTTP 401 can request one early renewal through the same lock, with a
compare-and-swap Keychain save so sign-out or a replacement account wins. Global
connections serve app-wide consumers; workspace overrides serve Default Agent.
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
