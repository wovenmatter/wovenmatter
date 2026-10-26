# Accounts and dictation

Open **Settings → Pi Durable** or **Settings → Usage** to manage shared
accounts. Account/status links in Usage and Pi Durable lead here.

The page groups **Model providers**, **Web search**, and **Local models**.
Expand a provider, then its subscription or API-key section. OpenAI, Anthropic,
Grok/xAI, OpenRouter, and OpenCode connections power Pi Durable.

Save up to four connections per type. Saved rows show account identity or a key
label and date added, never the secret. Older connections show “Existing
connection” when their original date is unknown. Choose **Use first**, then
arrange the remaining accounts as backups. Pi Durable tries these before the next
configured fallback model when authentication fails or allowance is exhausted.
It does not switch for ordinary throttling or replay after output/tools begin.

**Sign in** opens instructions beneath that connection. ChatGPT shows its device
link and code; Claude uses its bundled runtime’s native browser flow. Keys and
app-owned OAuth credentials stay in macOS Keychain. Shared remote credentials
use encrypted storage; native Claude credentials stay with Claude. A remote
workspace can also own one independent ChatGPT/Grok sign-in ahead of its shared
accounts. **Use shared sign-in** removes that independent override.

Workspace overrides apply to Pi Durable. Usage uses global accounts.
**Usage → Usage limits** shows a separate card for each saved account, plus providers
that need sign-in. Use **Go to Usage settings** to add or reconnect an account.
Device analytics imports Woven Matter and local harness history without account
setup, provider enable switches, or Keychain access. It excludes account-wide
OpenRouter API history from device totals and includes all OpenCode billing routes.
API keys without a supported limits endpoint show that limitation rather
than subscription quota. External harnesses keep their separate sign-ins.
Disabling a feature keeps its connection; removing a connection affects the
features using it.

## Executor

**Settings → General → Connected apps · Executor** manages one local or remote Linux Executor runtime, shared by
every agent through Woven MCP. Configure apps in its dashboard, choose defaults,
and select apps per conversation. See [Executor apps](executor.md) for setup,
permissions and recovery.

## Dictation

Dictation uses Apple's native on-device speech APIs on macOS and iOS 26 or later.
No subscription, API key, or provider connection is needed. Grok connections
continue to work for agents and Usage; dictation does not use them.

Click the microphone in a conversation or note to start. Allow microphone access
on first use. Apple may need an internet connection to prepare a language the
first time; the app shows preparation progress and lets you cancel. Once language
support is installed, speech recognition works offline. Audio and live previews
are not written to files or sent to a workspace, provider, or agent.

Dictation is always available. **Settings → General → Dictation** on Mac has a
language selector. Automatic follows your preferred
languages. On iPhone, touch and hold the microphone to choose a language. Language
changes apply to the next recording. Standard keyboard dictation remains available.

Recording continues as you switch conversations and notes. Click the recording
button in the destination editor to stop: the entire finalized transcript is
inserted at that editor's caret, replacing its selection. It remains a draft for
review and is never sent automatically. Native text editing preserves rich-text
attributes and undo. On Mac, **⇧⌘D** starts or stops dictation in the active editor.

Moving again while transcription finishes does not redirect the result. If an
editor closes or its content conflicts with the insertion point, the transcript
is retained for explicit insertion or discard. Cancel discards the recording.
Leaving the workspace for another app page stops capture; backgrounding the
iPhone app also stops capture. Interrupted recordings retain completed text where
possible. Unsupported languages and failed preparation have explicit errors;
there is no cloud transcription fallback.

## Local Model Server

In **Settings → Pi Durable → Local model servers**, enter a **Server URL** and **API key**, then click
**Connect**. Use an OpenAI Responses-compatible base URL, such as
`http://localhost:32100/v1`, or the server's address on your Tailscale network.
No advanced settings are needed. Add up to 12 servers.

Connect discovers models and verifies the Responses endpoint with a small test
request. Available models then appear in Pi Durable's model preferences. Enable the ones
you want in the conversation selector; the default model is always included. Reconnect after loading different models to refresh the
catalog. A failed check leaves an existing saved connection intact. Editing a
server address requires a new connection, keeping existing sessions and keys
bound to their original server.

A remote workspace must be able to reach the server address itself. `localhost`
refers to the machine/container running that agent; use a reachable network
address to share a server across devices. Woven Matter does not install Tailscale
or start model servers.
