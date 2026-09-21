# Shared provider credential ownership

The Mac `ProviderAccountCoordinator` owns shared OAuth renewal for Default
Agent, Usage, and Dictation. Connections is the shared account-management page.
App-wide consumers use global accounts; Default Agent can use workspace
overrides. Subscription credentials and separately billed API keys stay distinct. Local SDK conversation helpers
receive access-only credentials over private JSON-RPC pipes; refresh helpers
receive owned credentials through a private control pipe and return replacements.
The coordinator serializes renewal, persists replacements to Keychain, and only
then publishes a snapshot. No external harness auth files are read or changed.

Snapshots carry a stable digest revision. Connected remotes acknowledge the
revision after encrypting the update. Ordinary sends compare the cached
revision/deadline and workspace request identity entirely in app memory. Stale
snapshots and concurrent sends share one renewal/sync task. Launch, activation,
wake and reconnection trigger checks; the background timer checks the deadline
without spawning helpers on each tick. Transient failures retain existing
credentials and retry with a delay. Explicitly revoked refresh credentials are
excluded from borrowed exports. An expired access token is never renewed remotely
unless that workspace owns an independent sign-in.

Each remote process starts sealed. One AES-256-GCM JSON store contains shared
credentials and independently owned OAuth credentials. A random 256-bit key is
persisted only in Mac Keychain. Every write uses a new 96-bit nonce, a 128-bit
authentication tag, and workspace/version associated data. Writes are private,
atomic and serialized across helper processes. Failed decryption never falls
back to plaintext. Independent sign-ins take precedence over shared credentials.
Configuration, operation journals and wire histories do not contain credential
payloads. API keys and OAuth tokens are not launch arguments or tool environment
variables. Default Agent credential IPC is excluded from wire recording.

A credential update changes the store without replacing SDK sessions. The next
model/search request reads current credentials. A remote run whose borrowed token
expires waits between model requests; cancellation still works. Initial turn
admission can select an explicitly configured fallback. Once output or tools
have begun, authentication/usage errors never cause a whole-turn replay.

After a service restart, a locked response prompts the SSH bridge to request
an unlock snapshot from the Mac before retrying admission. Durable operation IDs
prevent replay of an already accepted run. Workspace request identities fence
late desktop responses when a destination or credential consent changes.

Read-only status checks are separate from synchronization and login. Default
Agent reports credential presence/expiry, not provider validation. External
harness status commands have deadlines and bounded captured output; raw output
is never returned to the UI. Ambiguous failures remain unknown. No test consumes
provider inference, OAuth, or search services.

## Protection boundary

Keychain and remote encrypted files protect persistent storage. The design does
not promise isolation from host administrators, arbitrary privileged agent
commands, process-memory inspection, swap or VM memory snapshots. Managed helper
launches/container settings disable core dumps. No extra broker, cloud KMS, or
hardware key service is required. Losing the Mac key requires an explicit reset
and re-sign-in for independent remote accounts. This feature is not a SOC 2 or
FIPS certification claim.

Grok dictation uses the same in-memory access snapshot as other app consumers;
it never creates a second credential file or passes credentials to a remote
workspace for speech capture. An early HTTP 401 can trigger a single coordinated
renewal. Account labels are display metadata, not proof of entitlement. Dictation
being disabled does not remove the shared sign-in. Local model server keys use
the same Keychain and encrypted remote vault, with a separate identity per server.
