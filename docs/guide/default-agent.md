# Pi Durable

**Pi Durable** is included with Woven Matter. Choose it in **New chat** to work in
your local agent workspace or a remote workspace.
It includes Pi's file and shell tools, Woven Matter's existing note/workspace
integration, and web search. You do not need to install Pi, Node, or Claude Code.

Open **Settings → Subscriptions & API Keys** to connect providers:

- **OpenAI:** connect a ChatGPT subscription, an OpenAI API key, or both.
- **OpenRouter / OpenCode Go:** add an API key. The global OpenRouter key is
  shared with Usage and Pi Durable.
- **Claude:** use your Claude subscription through Anthropic’s native sign-in,
  an Anthropic API key, or both. They appear as separate model connections.
- **Grok/xAI:** connect a Grok subscription or a separately billed xAI API key.
- **Web search:** add Exa, Brave, or Firecrawl keys under **Web search**, then select
  the provider to use on its row.
  Exa remains the default. Exa and Firecrawl also read webpages; Brave returns
  search context, with the browser available for page reading. Chat and workspace
  tools work without a search key.
- **Local Model Server:** connect up to 12 OpenAI Responses-compatible servers.
  Their models appear in the existing Pi Durable model picker.

Open **Settings → Agents → Pi Durable** to choose a default, show or hide models,
change their selector order, and choose an ordered list of fallback models.
After connecting an account, choose **Choose chat models** to open the model browser. Choose the models
you want in chat; the first selection becomes the default. The default is always shown. Filter
the catalog by connection type, model lab across connections, or subscriptions.

See [Connections and dictation](connections-and-dictation.md) for account and microphone setup.

Set **Applies to** to **All workspaces** for shared Pi Durable settings. To give
one workspace its own model, thinking, permission, and tool preferences, choose
it under **Applies to** and turn off **Use shared chat settings**. Accounts stay
independent of this switch: workspace-specific API keys override the global
keys; otherwise global keys are reused. Changes synchronize to connected
workspaces automatically, and **More → Synchronization → Retry synchronization**
retries immediately. New workspaces inherit these settings automatically. An
offline workspace gets the current settings when it reconnects.

**More → Subagents** sets how many subagents can be active in one conversation.
It applies to new conversations; the parent agent does not count.

SDK versions are under **More → Software**. Expand a workspace to see its
**Pi Durable SDK** and **Claude SDK** versions. Use **Check for updates**, then **Update**
for the SDK you want to update. With **All workspaces** selected the list shows
each location; choosing one workspace limits the list to that location.
Collapsing a workspace hides its SDK details without discarding update progress.

SDK installations belong to each location, independently of inherited provider
preferences. Updating the local SDK does not update remote workspaces or the
separately installed Pi and Claude Code CLIs. Older remote workspace services
need a workspace software update before they can expose SDK management.

ChatGPT, Claude, and Grok each support one subscription account per workspace.
API keys still support up to four accounts per connection type. Existing subscription
account lists keep the selected account and remove additional entries. Reconnect
the current subscription or remove it before changing accounts.

Fallback applies when a connection loses authentication or exhausts its available
usage. API-key connections try the preferred key and its ordered backups first.
Subscription connections use only their current account; an
independent workspace sign-in does not fall back to a shared subscription account.
Woven Matter then tries your enabled fallback models in order, updates the
model selector, and shows a popup explaining the switch. Ordinary transient
rate limits do not trigger fallback. A turn that has already produced output or
executed tools is not automatically replayed.

Remote workspaces include the same helper. Their Pi Durable runs continue
when your Mac disconnects, as long as the Linux host and its Woven service keep
running. Reopening the conversation shows the completed response, and an
unfinished response keeps streaming when you reconnect. A service restart
interrupts active work and requires an explicit retry.

Pi Durable and Usage use the same saved provider accounts, managed in Settings → Subscriptions & API Keys.
Dictation uses on-device speech and needs no account. Subscription connections remain distinct from separately billed API
keys. Signing in here does not sign in
Codex, Claude Code, Grok Build, or OpenCode, and their
credential files are not imported.

API keys can be reused in remote workspaces. For shared subscription sign-ins,
the Mac that added the workspace keeps and renews the credentials. The
workspace receives only short-lived access, never the long-lived refresh
credential. Renewed access is saved on the Mac before being sent to
connected workspaces. Launch, wake, reconnect, settings changes, and an
expiry-aware background check keep those workspaces current. Ordinary message
submissions check cached state; opening conversation history does not refresh
authentication. Token lifetimes come from each provider, not a fixed number of days.

For an independent subscription sign-in on one remote workspace, open
**Settings → Subscriptions & API Keys**, set **Accounts for** to that workspace,
and use **Sign in**. **Use shared sign-in** removes that independent connection and
returns to shared credentials. An active remote helper can keep working while
the Mac is offline. If borrowed access expires, it waits before the next model
request until access is supplied again; it does not repeat completed tools.
Starting a new turn can use your configured fallback instead.

## Code mode and Executor

**More → Code mode** in Pi Durable settings defaults to **On**, alongside ordinary
tools. **Only** presents those tools through code mode; **Off** removes the code
mode tool. Nested calls retain normal approval. User Pi extensions remain
disabled. Executor Execute is independent and available when Executor is enabled
in the conversation. See [Executor apps](executor.md).

## Credential storage

App-managed Pi Durable credentials on the Mac, including OAuth refresh tokens, are
stored in macOS Keychain. Each remote workspace has one encrypted credential
store using AES-256-GCM. Its separate random key is kept in the Keychain of
the Mac that added the workspace and delivered to the host's server in a
request signed with that Mac's device key (over the installer's SSH link only before the host is enrolled). The host
keeps the key in memory; after it restarts, the next action from that Mac
unlocks it again. Updates do not restart active sessions.

If the Mac's workspace key is lost, open **Settings → Subscriptions & API Keys**,
set **Accounts for** to that workspace, and use **Account recovery → Reset
workspace credentials**. This removes independent ChatGPT/Grok sign-ins and
restores shared connections. Claude’s native sign-in is separate; use its
**Remove** button to disconnect that account. Files and conversations remain.
Existing Pi Durable plaintext stores migrate after secure storage succeeds;
older backups may still contain previous plaintext copies.

Encryption protects stored credential files and disk backups. It does not
protect credentials from an administrator controlling an unlocked machine.
Crash dumps are disabled for managed helpers; host swap and memory
snapshots remain host responsibilities. Removing stored credentials does not
revoke copies already obtained elsewhere; revoke those through the provider.

Open **Settings → Agents** or a remote workspace in **Settings → Workspaces** to see
sign-in status. It checks Pi Durable and independent harnesses without starting login. Results distinguish stored
credentials, a harness reporting sign-in, missing sign-in, unsupported checks,
and failures. These checks do not verify remaining usage. Local harnesses whose
credential access is disabled stay unchecked.

With **Keep working in the background** on for a remote workspace (in its
**Settings → Workspaces** page), the workspace also keeps supported sessions
running across Mac disconnections. A service restart is a separate boundary:
interrupted sends are not automatically repeated. See
[Background execution](../architecture/BACKGROUND_EXECUTION.md).

## Claude models

In **Settings → Subscriptions & API Keys**, expand **Anthropic** and click
**Sign in with Claude**. Open the inline link and complete Anthropic’s sign-in flow.
Paste the full code returned by Claude into the sign-in form and click **Continue**.
The account list refreshes when sign-in completes. Woven Matter bundles the unmodified
official runtime; this sign-in is separate from an independently installed Claude Code harness.
An API key uses the separate **Claude API key** option and is billed separately.

Claude provides model responses while Pi Durable retains its tools, approvals,
history, and compaction. The composer exposes model, thinking, permissions, and
workspace-tool controls. The agent is named **Pi Durable** throughout the app,
regardless of the selected model or provider. SDK management identifies its
underlying libraries as **Pi Durable SDK** and **Claude SDK**.

Claude owns subscription login, storage, and refresh. On this Mac, it uses its
native Keychain entry; plaintext fallback is blocked if Keychain is unavailable.
In remote workspaces, sign in separately. On a Linux host, Claude keeps its
sign-in in private memory-backed storage (`/dev/shm`), which is cleared when the
host restarts, so sign in again after a reboot. Claude subscription credentials
are never copied between workspaces.
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

## iPhone Quick Chat (beta)

The iPhone app is a beta available through TestFlight. Its Quick Chat runs Pi
Durable on the phone, with one subscription connection per provider (ChatGPT,
Claude, and Grok) and multiple API-key connections. Edit a saved
connection to reconnect it or change its sign-in. To try it, email
trey@wovenmatter.com with the email address to add as a TestFlight tester.
