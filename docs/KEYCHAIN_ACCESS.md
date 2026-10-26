# Keychain access and prompt policy

**Settings → General → Keychain access** is the single deliberate recovery entry.
Use **Enable Keychain access** initially or **Restore Keychain access** after a failure.
When macOS asks, **Always Allow** remembers access to that item; it is not a blanket
authorization for future credentials. Background checks stay noninteractive.

The card reports **Access ready** only after checking the browser encryption key,
website-password vault, saved Pi Durable/Usage items, and remote workspace keys.
The checks run in the process that owns each credential. Accepting the disclosure
alone is not proof of access. Failure or cancellation shows **Access needs attention**.
No credentials or Keychain values are returned to the presentation layer.

## Audited paths

| Credential or activity | Background behavior | Deliberate access |
| --- | --- | --- |
| OpenRouter usage key | Attributes-only presence checks; noninteractive secret reads; successful reads cached for the session and used by limits; device analytics does not read credentials | Saving/removing the key stays silent; General recovery may authorize access |
| Claude subscriptions | Usage reads the saved Pi Durable profile; native Claude owns its credential permissions | Sign-in lives in Pi Durable and Usage settings; General does not probe unrelated native profiles |
| Remote workspace API token | Cached by workspace; noninteractive on service calls; denied reads are not repeated; disabling access clears the cache | General recovery; provisioning, reconnect and deletion stay noninteractive |
| Codex/Grok usage limits | Saved account API reads only; no native CLI fallback during refresh | Account management lives in Usage settings; the limits page has no authentication controls |
| Browser encryption key and website passwords | Consent-gated, noninteractive preflight before CEF starts; exact-origin password vault cached in memory; writes suppress UI | General recovery preauthorizes Chromium Safe Storage and the website-password vault |
| Local runtime readiness | Startup, reopen, Settings, and passive refresh resolve installed executables without starting credential-sensitive provider sessions | Installed harnesses are available without an Enable step; explicit Sign in opens only the chosen native CLI flow |
| Codex title options | No automatic session solely to discover models | Existing Refresh options action |

OpenCode service registration does not call Keychain. Existing
user-enabled service restoration and actual conversation runs can start external
provider processes; those processes own their own credential storage and system
permissions. Woven Matter's process-local suppression does not control another
process. Usage/status polling therefore must not start those processes merely
to discover account state.

## Enforcement

All app-owned `SecItem` operations use `KeychainAccess`. App startup disables
legacy login-Keychain UI process-wide, covering Chromium's asynchronous OSCrypt
calls as well as Swift callers. Browser helpers independently suppress UI before
loading CEF. Failure to install that policy blocks browser startup.

General's recovery action establishes a task-local authorization scope. Wrapped
operations serialize process-wide policy changes, enable UI only inside that
scope, then restore suppression before returning. Background operations also
supply a noninteractive `LAContext`, even during recovery. A policy already
disabled before app startup remains disabled. The scope crosses backend IPC only
through the dedicated saved-credential recovery commands; normal connect/retry
commands cannot authorize UI. Recovery finishes before refresh work starts.

Browser startup requires app consent and readable Chromium Safe Storage. A denied
read blocks initialization and points to General rather than falling back to an
unencrypted profile or prompting from the browser. The existing shared Chromium
secret is preserved. A missing secret is generated in the format expected by the
bundled Chromium build. Website passwords use a separate Keychain item under
`wovenmatter.browser.passwords`, scoped by app bundle ID, and never enter agent
context, snapshots, diagnostics, defaults or plaintext files. Dev and production
have separate password vaults as well as separate Chromium profiles.

A denied read is different from a missing item: it must never erase a token or
imply that a user needs a replacement key. Credential values are never written
to diagnostics. Tests use
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
current access. The app caches successful app-owned reads for its session. Always Allow granted
to an older ad-hoc test binary does not authorize a differently signed Dev app.
The saved app consent centralizes recovery; it cannot combine macOS approval for
distinct pre-existing Keychain items into a single OS dialog.

Apple references: [Code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Mac Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Validation

Provider-free regression suites cover read/write suppression and policy
restoration, denied/missing credentials, concurrent operations, last-good usage
retention, one-time authorization reuse, remote-token caching, provider-scoped
CLI fallback, and
passive runtime discovery. `scripts/test-dev-signing.sh` verifies certificate
selection, persistence, ambiguity handling, and failure without identity
downgrade using fake tools. The normal full test command also builds and
validates the native app.

Browser credential tests inject synthetic Keychain operations for consent,
origin isolation, persistence, failed writes and recovery. An opt-in real CEF
fixture uses a disposable profile, mock Chromium Keychain, synthetic loopback
form and hidden window; see `docs/design/embedded-browser.md` for its command.
