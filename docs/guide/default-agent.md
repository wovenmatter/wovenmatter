# Default Agent

Default Agent is built into Woven Matter. Choose it in **New chat** to work in
your local agent workspace, or choose the Default Agent in a remote workspace.
It includes Pi's file and shell tools, Woven Matter's existing note/workspace
integration, and web search. You do not need to install Pi or Node.

Open **Settings → Default Agent** to configure it:

- **OpenAI:** connect a ChatGPT subscription, an OpenAI API key, or both.
- **OpenRouter / OpenCode Go:** add an API key. The global OpenRouter key is
  shared with Usage.
- **Grok subscription:** reuse an available local sign-in or sign in here.
- **Web search:** add an Exa key. Chat and workspace tools work without it.
- **Models:** choose a default, show or hide models, change their selector order,
  and choose an ordered list of fallback models.

Use **All workspaces** for shared settings. Choose a particular workspace and
turn off **Use settings from All workspaces** to override its preferences.
Workspace-specific API keys override the global keys; otherwise global keys
are reused. Apply changes to connected workspaces with **Apply to workspaces**.
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

API keys can be reused in remote workspaces. Where available, existing OAuth
access can be reused temporarily. Refresh tokens remain owned by the original
sign-in; use **Sign in** with the remote workspace selected to establish an
independently renewable subscription connection there. No fallback is attempted
outside the models you selected.

These disconnect guarantees apply to Default Agent. The other harnesses retain
their existing runtime-specific connection behavior.
