# Default Agent

Default Agent is built into Woven Matter. Choose it in **New chat** to work in
your local agent workspace, or choose the Default Agent in a remote workspace.
It includes Pi's file and shell tools, Woven Matter's existing note/workspace
integration, and web search. You do not need to install Pi or Node.

Open **Settings → Default Agent** to configure it:

- **OpenAI:** connect a ChatGPT subscription, an OpenAI API key, or both.
- **OpenRouter / OpenCode Go:** add an API key. The global OpenRouter key is
  shared with Usage.
- **Grok subscription:** sign in here independently of the Grok Build harness.
- **Web search:** add an Exa key. Chat and workspace tools work without it.
- **Models:** choose a default, show or hide models, change their selector order,
  and choose an ordered list of fallback models.

Use **All workspaces** for shared settings. Choose a particular workspace and
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

Remote workspaces include the same helper. Their Default Agent runs continue
when the Mac app disconnects, while the remote container and service remain
running. Reopening the conversation recovers the completed response; reconnecting
to an unfinished response waits for that remote turn to finish. A container or
service restart interrupts active work and requires an explicit retry.

Default Agent owns its provider connections. Signing in here does not sign in
Codex, Claude Code, external Pi, or the other installed harnesses, and their
credential files are not imported.

API keys can be reused in remote workspaces. For shared OAuth subscriptions,
the Mac owns and renews the access and refresh tokens. Remote borrowers receive
only access tokens. Renewed access is saved on the Mac before being sent to
connected workspaces. Launch, wake, reconnect, settings changes, and an
expiry-aware background check keep those workspaces current. Ordinary message
submissions check cached state; opening conversation history does not refresh
authentication. Token lifetimes come from each provider, not a fixed number of days.

Use **Sign in** with a remote workspace selected for an independent subscription
connection there. **Use shared sign-in** removes that independent connection and
returns to shared credentials. An active remote helper can keep working while
the Mac is offline. If borrowed access expires, it waits before the next model
request until access is supplied again; it does not repeat completed tools.
Starting a new turn can use your configured fallback instead.

## Credential storage

All Default Agent credentials on the Mac, including OAuth refresh tokens, are
stored in macOS Keychain. Each remote workspace has one encrypted credential
store using AES-256-GCM. Its separate random key is kept in the Mac's Keychain
and delivered over the authenticated SSH connection. The remote helper keeps
the key in memory; after a helper/container restart, reconnect Woven Matter to
unlock it. Updates do not restart active sessions.

If the Mac's workspace key is lost, use **Reset workspace credentials** on that
workspace's Default Agent settings page. This removes independent remote
sign-ins and restores shared connections. Files and conversations remain.
Existing Default Agent plaintext stores migrate after secure storage succeeds;
older backups may still contain previous plaintext copies.

Encryption protects stored credential files and disk backups. It does not
protect credentials from an administrator controlling an unlocked machine.
Crash dumps are disabled for managed helpers/containers; host swap and memory
snapshots remain host responsibilities. Removing stored credentials does not
revoke copies already obtained elsewhere; revoke those through the provider.

Open **Local agent workspace** or a specific **Remote agent workspace** in
Settings and select **Refresh sign-in status**. It checks Default Agent and
independent harnesses without starting login. Results distinguish stored
credentials, a harness reporting sign-in, missing sign-in, unsupported checks,
and failures. These checks do not verify remaining usage. Local harnesses whose
credential access is disabled stay unchecked.

These disconnect guarantees apply to Default Agent. The other harnesses retain
their existing runtime-specific connection behavior.
