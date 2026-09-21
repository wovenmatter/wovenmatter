# Credential access and prompt policy

Woven Matter remembers one app-wide credential-access consent. Enabling a
provider or remote workspace still selects which features to use; it does not
create another app-wide permission. The General settings recovery action is
deliberate, runs once, and stops at the first failed authorization. Background
refresh never opens credential authorization UI.

## Audited paths

| Credential or activity | Background behavior | Deliberate access |
| --- | --- | --- |
| OpenRouter usage key | Attributes-only presence checks; noninteractive secret reads; successful reads cached for the session and shared by analytics and limits | Saving/removing the key or reconnecting saved credentials |
| Claude Code credential | File first, then cached session token or noninteractive Keychain read; no CLI fallback after a denied read | Existing provider enable/retry or global recovery may authorize one read |
| OpenClaw device identity/token | Cached by gateway scope; unchanged tokens are not rewritten; reads and token updates suppress UI; failures stop reconnect retries and remain blocked until explicit recovery | Existing Link/Reconnect/Restart or global recovery |
| Remote workspace API token | Cached by workspace; noninteractive on service calls; denied reads are not repeated; disabling access clears the cache | Provision/delete, existing Reconnect, or global recovery; rollback deletion remains silent |
| Codex/Grok/Cursor usage probes | Direct file/API reads only; unavailable reads preserve last-good limits | A selected provider's explicit access action may use its CLI fallback; cannot authorize other providers |
| Local runtime readiness | Startup, reopen, Settings, and passive refresh resolve installed executables without starting credential-sensitive provider sessions | Existing runtime Enable checks only that runtime |
| Codex title options | No automatic session solely to discover models | Existing Refresh options action |

OpenCode service registration, Buzz discovery/configuration, and local OpenClaw
configuration/SQLite credential resolution do not call Keychain. Existing
user-enabled service restoration and actual conversation runs can start external
provider processes; those processes own their own credential storage and system
permissions. Woven Matter's process-local suppression does not control another
process. Usage/status polling therefore must not start those processes merely
to discover account state.

## Enforcement

All app-owned `SecItem` operations use `KeychainAccess`. Silent operations are
serialized, temporarily disable legacy login-Keychain interaction, also set a
noninteractive `LAContext`, and restore the exact prior policy. If suppression
fails, the credential operation does not run. Explicit operations never override
an already-disabled system policy. This covers writes as well as reads.

A denied read is different from a missing item: it must never generate a new
OpenClaw identity, erase a token, or imply that a user needs a replacement key.
Failed OpenClaw token persistence retains the pending identity/token for one
explicit retry. Credential values are never written to diagnostics. Tests use
in-memory operations and synthetic credentials rather than the user's Keychain.

## Development builds

The old Dev launcher disabled signing, so each changed binary had a different
ad-hoc identity. `scripts/build_and_run.sh` now uses a unique existing Apple
Development certificate and pins its fingerprint in the build cache. Set
`WOVENMATTER_DEV_SIGNING_IDENTITY` to select an existing identity explicitly.
A previously signed cache never silently falls back to ad-hoc signing when its
identity becomes unavailable. Machines without a certificate can still build
ad-hoc; an explicit `-` opts out of certificate signing.

This does not modify Keychain ACLs, migrate or copy provider credentials, create
certificates, or weaken Keychain protection. macOS still controls initial
approval for individual items. A stable app signature permits persistent system
approval to survive compatible rebuilds; one-time Allow only authorizes the
current access. The app caches that successful read for its session.

Apple references: [Code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Mac Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Validation

Provider-free regression suites cover read/write suppression and policy
restoration, denied/missing credentials, concurrent operations, last-good usage
retention, one-time authorization reuse, OpenClaw identity preservation and
unchanged-token writes, remote-token caching, provider-scoped CLI fallback, and
passive runtime discovery. `scripts/test-dev-signing.sh` verifies certificate
selection, persistence, ambiguity handling, and failure without identity
downgrade using fake tools. The normal full test command also builds and
validates the native app.
