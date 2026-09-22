# Built-in

**Built-in** is included with Woven Matter. Choose it in **New chat** to work in
your local agent workspace or a remote workspace.
It includes Pi's file and shell tools, Woven Matter's existing note/workspace
integration, and web search. You do not need to install Pi, Node, or Claude Code.

Open **Settings → Connections** to connect providers:

- **OpenAI:** connect a ChatGPT subscription, an OpenAI API key, or both.
- **OpenRouter / OpenCode Go:** add an API key. The global OpenRouter key is
  shared with Usage and Built-in.
- **Claude:** use your Claude subscription through Anthropic’s native sign-in,
  an Anthropic API key, or both. They appear as separate model connections.
- **Grok subscription:** sign in here independently of the Grok Build harness.
- **Web search:** add an Exa key. Chat and workspace tools work without it.
- **Local Model Server:** connect up to 12 OpenAI Responses-compatible servers.
  Their models appear in the existing Built-in model picker.

Open **Settings → Built-in Agent** to choose a default, show or hide models,
change their selector order, and choose an ordered list of fallback models.

See [Connections and dictation](connections-and-dictation.md) for account and microphone setup.

Use **All workspaces** for shared Built-in settings. Choose a particular workspace and
turn off **Use settings from All workspaces** to override its preferences.
Workspace-specific API keys override the global keys; otherwise global keys
are reused. Changes synchronize to connected workspaces automatically. **Apply to workspaces** retries synchronization immediately.
New workspaces inherit these settings automatically. An offline workspace gets
the current settings when it reconnects.

Fallback applies when a connection loses authentication or exhausts its available
usage. Woven Matter tries your configured fallback models in order, updates the
model selector, and shows a popup explaining the switch. Ordinary transient
rate limits do not trigger fallback. A turn that has already produced output or
executed tools is not automatically replayed.

Remote workspaces include the same helper. Their Built-in runs continue
when the Mac app disconnects, while the remote container and service remain
running. Reopening the conversation recovers the completed response; reconnecting
to an unfinished response waits for that remote turn to finish. A container or
service restart interrupts active work and requires an explicit retry.

Connections owns shared provider accounts for Built-in, Usage, and
Dictation. Subscription connections remain distinct from separately billed API
keys. Signing in here does not sign in
Codex, Claude Code, external Pi, or the other installed harnesses, and their
credential files are not imported.

API keys can be reused in remote workspaces. For shared OAuth subscriptions,
the Mac owns and renews the access and refresh tokens. Remote borrowers receive
only access tokens. Renewed access is saved on the Mac before being sent to
connected workspaces. Launch, wake, reconnect, settings changes, and an
expiry-aware background check keep those workspaces current. Ordinary message
submissions check cached state; opening conversation history does not refresh
authentication. Token lifetimes come from each provider, not a fixed number of days.

In Connections, use **Sign in** with a remote workspace selected for an independent subscription
connection there. **Use shared sign-in** removes that independent connection and
returns to shared credentials. An active remote helper can keep working while
the Mac is offline. If borrowed access expires, it waits before the next model
request until access is supplied again; it does not repeat completed tools.
Starting a new turn can use your configured fallback instead.

## Credential storage

App-managed Built-in credentials on the Mac, including OAuth refresh tokens, are
stored in macOS Keychain. Each remote workspace has one encrypted credential
store using AES-256-GCM. Its separate random key is kept in the Mac's Keychain
and delivered over the authenticated SSH connection. The remote helper keeps
the key in memory; after a helper/container restart, reconnect Woven Matter to
unlock it. Updates do not restart active sessions.

If the Mac's workspace key is lost, use **Reset workspace credentials** on that
workspace in Connections. This removes independent ChatGPT/Grok sign-ins and
restores shared connections. Claude’s native sign-in is separate; use its
**Sign out** button to remove it. Files and conversations remain.
Existing Built-in plaintext stores migrate after secure storage succeeds;
older backups may still contain previous plaintext copies.

Encryption protects stored credential files and disk backups. It does not
protect credentials from an administrator controlling an unlocked machine.
Crash dumps are disabled for managed helpers/containers; host swap and memory
snapshots remain host responsibilities. Removing stored credentials does not
revoke copies already obtained elsewhere; revoke those through the provider.

Open **Local agent workspace** or a specific **Remote agent workspace** in
Settings and select **Refresh sign-in status**. It checks Built-in and
independent harnesses without starting login. Results distinguish stored
credentials, a harness reporting sign-in, missing sign-in, unsupported checks,
and failures. These checks do not verify remaining usage. Local harnesses whose
credential access is disabled stay unchecked.

These disconnect guarantees apply to Built-in. The other harnesses retain
their existing runtime-specific connection behavior.

## Claude models

In **Settings → Connections → Claude**, choose **Claude subscription** and click
**Sign in with Claude**. Complete Anthropic’s own flow in Terminal, then click
**Refresh connections**. Woven Matter bundles the unmodified official runtime;
this sign-in is separate from an independently installed Claude Code harness.
An API key uses the separate **Claude API key** option and is billed separately.

Claude provides model responses while Built-in retains its tools, approvals,
history, and compaction. The composer exposes model, thinking, permissions, and
workspace-tool controls. Settings is titled **Built-in Agent**; the sidebar shows
**Built-in Pi SDK** or **Built-in Claude SDK** for the most recently used backend.

Claude owns subscription login, storage, and refresh. On this Mac, it uses its
native Keychain entry; plaintext fallback is blocked if Keychain is unavailable.
In remote workspaces, sign in separately. Claude’s native state lives in a private
memory-backed directory and disappears when the container restarts, so sign in
again afterward. Claude subscription tokens are never copied between workspaces.
API keys retain the existing Keychain/encrypted remote storage behavior.

Subscription entitlement and any enabled extra usage are controlled by your
Claude account. To prevent subscription overage billing, disable extra usage
there. Woven Matter does not automatically substitute your separately billed API
key. An explicitly configured fallback can switch connections and will update
the selector and show a notice.

Usage shows the native Claude account’s sign-in status. Remaining subscription
limits are checked in Claude; Woven Matter does not extract its token to query
those limits. Live account acceptance and billing attribution require testing
with your own account.
