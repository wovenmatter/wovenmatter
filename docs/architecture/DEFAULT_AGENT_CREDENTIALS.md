# Provider credential ownership

Every device stores and renews its own sign-ins; nothing is copied or relayed
between devices. Subscription credentials and separately billed API keys stay
distinct. No external harness auth files are read or changed.

On a Mac, sign-ins live in Keychain (the `global` scope). The Mac
`ProviderAccountCoordinator` owns renewal for Pi Durable, Usage, bots and
Dictation: it serializes renewal, persists replacements to Keychain, and only
then publishes a snapshot. Local SDK helpers receive access-only credentials
over private JSON-RPC pipes; refresh helpers receive owned credentials through
a private control pipe and return replacements. A failed early renewal does not
interrupt access that is still valid, and explicitly revoked refresh credentials
are excluded from borrowed exports.

On a Linux host, the sign-in store (`credentials.enc.json`) and its key
(`credentials.key`) are both files, 0600, in that workspace's Pi Durable folder
(`.wovenmatter/default-agent`). Anything running as that user can read them: the
AES-256-GCM encryption is not protection at rest. The host renews its own
subscriptions. A Mac sends a host chat settings only, and changes the host's
sign-ins through its signed `v1/sign-ins` route; the key never leaves the host.

Configuration, operation journals and wire histories do not contain credential
payloads. App-managed OAuth tokens are not launch arguments or tool environment
variables. Claude API mode supplies its selected API key to the native runtime
through its process environment, never command arguments. Pi Durable credential
IPC is excluded from wire recording.

A credential update changes the store without replacing SDK sessions; the next
model or search request reads current credentials. Initial turn admission can
select an explicitly configured fallback. Once output or tools have begun,
authentication/usage errors never cause a whole-turn replay. Cancelling a turn
also cancels its credential preparation, so a pending auth check cannot start a
model request after Stop.

Read-only status checks are separate from synchronization and login. Pi Durable reports credential presence/expiry, not provider validation. External
harness status commands have deadlines and bounded captured output; raw output
is never returned to the UI. Ambiguous failures remain unknown. No test consumes
provider inference, OAuth, or search services.

Control responses and HTTP error inspection are bounded while reading. Only
app-authored operation errors reach the UI or remote completion journals; raw
SDK/provider exceptions are replaced with a generic connection error.

## Protection boundary

Keychain and remote encrypted files protect persistent storage. The design does
not promise isolation from host administrators, arbitrary privileged agent
commands, process-memory inspection, swap or VM memory snapshots. Managed helper
launches/container settings disable core dumps. No extra broker, cloud KMS, or
hardware key service is required. Losing the Mac key requires an explicit reset
and re-sign-in for independent remote accounts. This feature is not a SOC 2 or
FIPS certification claim.

Settings → GitHub's SSH key is stored on every Mac and Linux host and reaches
agents only through a signing agent's socket; see `GITHUB_IDENTITY.md`.

Dictation uses Apple's on-device SpeechAnalyzer API and does not consume provider
credentials. Grok subscription and API connections remain available to agents and
Usage. Local model server keys use the same Keychain and encrypted remote vault,
with a separate identity per server.

## Native Claude subscription exception

Claude subscription authentication belongs exclusively to Anthropic’s unmodified
runtime. Connections exposes native sign-in and status, with no token import,
copy, refresh, or borrowed-access route. The app’s OAuth coordinator does not own
this account. API-key mode uses the existing app-managed secret store and stays
separate from subscription mode.

The Mac native credential directory is read-only, preventing plaintext fallback
when native Keychain access fails. A separate config directory holds non-secret
runtime settings. Remote native state uses private tmpfs and is not included in
the persistent workspace volume. Container restarts require a new native sign-in;
Mac reconnection cannot restore Claude subscription credentials. Account extra
usage remains controlled by Anthropic’s account settings.

Connections starts the bundled runtime’s native sign-in locally or through the
workspace’s existing SSH/docker-exec route. The authorization link appears beneath
the account; the user completes sign-in in their browser. No authentication UI is
driven by automated tests. On macOS, `CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps a
stable private path that identifies the native Keychain entry. An
`everyone deny add_file` macOS ACL blocks regular-file creation, including
temporary files used by the plaintext fallback. Owner mode `0700` still permits
the selected runtime to create and remove its `.storage-write.lock` directory
before accessing Keychain. The ACL is installed before enabling directory writes;
existing non-directory entries stop setup without reading or removing their
contents. A native login exit code of zero is followed by a native status check;
an unsaved or unverifiable connection is reported as a failure. This storage
contract must be rechecked when updating the runtime pin. Linux uses a private,
verified tmpfs directory for native state. Host swap and memory snapshots remain
outside the file-storage guarantee.
