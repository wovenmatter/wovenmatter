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
replacements. API keys use macOS Keychain. Global OpenRouter uses the same
Keychain item as Usage. A local helper receives its configuration in the launch
environment, removes it before creating tools, and accepts fresh configuration
before subsequent turns. Owned SDK OAuth credentials are private files, protected
by a cross-process lock for token rotation. Existing Codex/Grok credentials are
borrowed without taking refresh ownership. The source sign-in is reread so a
logout does not leave a stale process cache authenticated.

Remote configuration travels over the existing authenticated workspace service
connection and is stored privately in the persistent workspace volume. It is
never part of an image. Remote SDK sessions and accepted operations are owned by
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
