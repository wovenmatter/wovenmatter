# Connections and dictation

Open **Settings → Connections**, immediately below General, to manage shared
accounts. Account/status links in Usage, Built-in, and General lead here.

Connect ChatGPT or Grok subscriptions, or add OpenAI, OpenRouter, and OpenCode Go
API keys. Claude offers separate subscription and API-key connections. Its
subscription uses the bundled Claude runtime’s own sign-in; each remote workspace
has an independent, memory-only Claude login. See [Claude setup](default-agent.md). OpenAI's selector lets you configure both the ChatGPT subscription and
the separately billed API key. Add Exa for Built-in web search. Keys are
stored in macOS Keychain. Shared remote credentials use the encrypted storage
described in [Built-in](default-agent.md#credential-storage).

The shared account selection applies across the app. Workspace overrides apply
to Built-in; app-wide Usage and Dictation use the shared accounts. External
harnesses still own their separate sign-ins. Disabling a feature keeps its shared
connection. Disconnecting that connection affects the features using it.

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
request. Available models then appear in Built-in's model preferences and
conversation selector. Reconnect after loading different models to refresh the
catalog. A failed check leaves an existing saved connection intact. Editing a
server address requires a new connection, keeping existing sessions and keys
bound to their original server.

A remote workspace must be able to reach the server address itself. `localhost`
refers to the machine/container running that agent; use a reachable network
address to share a server across devices. Woven Matter does not install Tailscale
or start model servers.
