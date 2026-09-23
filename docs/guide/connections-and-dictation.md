# Connections and dictation

Open **Settings → Connections**, immediately below General, to manage shared
accounts. Account/status links in Usage, Built-in, and General lead here.

The page groups **Model providers**, **Web search**, and **Local models**.
Expand a provider, then its subscription or API-key section. OpenAI, Anthropic,
Grok/xAI, OpenRouter, and OpenCode connections power Built-in. Cursor is for
Usage limits only and keeps its single native account on this Mac.

Save up to four connections per type. Saved rows show account identity or a key
label and date added, never the secret. Older connections show “Existing
connection” when their original date is unknown. Choose **Use first**, then
arrange the remaining accounts as backups. Built-in tries these before the next
configured fallback model when authentication fails or allowance is exhausted.
It does not switch for ordinary throttling or replay after output/tools begin.

**Sign in** opens instructions beneath that connection. ChatGPT shows its device
link and code; Claude uses its bundled runtime’s native browser flow. Keys and
app-owned OAuth credentials stay in macOS Keychain. Shared remote credentials
use encrypted storage; native Claude credentials stay with Claude. A remote
workspace can also own one independent ChatGPT/Grok sign-in ahead of its shared
accounts. **Use shared sign-in** removes that independent override.

Workspace overrides apply to Built-in. Usage and Dictation use global accounts.
In **Usage → Usage limits**, each provider's **Account** selector chooses whose
limits to display without changing the preferred inference account or fallback
order. API keys without a supported limits endpoint show that limitation rather
than subscription quota. External harnesses keep their separate sign-ins.
Disabling a feature keeps its connection; removing a connection affects the
features using it.

## Dictation

Enable **Dictation** in **Settings → General**, above Conversation titles.
Connect your Grok subscription in Connections and allow microphone access when
you first record. The conversation's agent and model do not affect dictation.

Click the microphone in a conversation or note to start. Recording continues
as you switch conversations, panels, and notes. Click the recording button in
the destination editor to stop: the **entire transcript** is inserted at that
editor's caret, replacing its selection. It remains a draft for review. Undo
reverses the insertion as one edit. Moving again while transcription finishes
does not redirect the result.

Leaving the workspace for Settings, Usage, or another app page stops capture at
the last active workspace editor. Cancel discards the recording. If an editor
closes or its text conflicts with the selected insertion point, the final
transcript is retained for explicit insertion or discard. Audio and transcription
previews are not saved to files. Dictation runs on the Mac, including while
viewing remote conversations.

Grok decides account eligibility and available allowance. Sign-in failures,
subscription restrictions, exhausted usage, and temporary request limits have
separate messages. Dictation never switches to a separately billed API key.

## Local Model Server

At the bottom of Connections, enter a **Server URL** and **API key**, then click
**Connect**. Use an OpenAI Responses-compatible base URL, such as
`http://localhost:32100/v1`, or the server's address on your Tailscale network.
No advanced settings are needed. Add up to 12 servers.

Connect discovers models and verifies the Responses endpoint with a small test
request. Available models then appear in Built-in's model preferences. Enable the ones
you want in the conversation selector; the default model is always included. Reconnect after loading different models to refresh the
catalog. A failed check leaves an existing saved connection intact. Editing a
server address requires a new connection, keeping existing sessions and keys
bound to their original server.

A remote workspace must be able to reach the server address itself. `localhost`
refers to the machine/container running that agent; use a reachable network
address to share a server across devices. Woven Matter does not install Tailscale
or start model servers.
