# Woven Matter documentation

Woven Matter runs Pi Durable, Codex, Claude Code, Grok Build, and OpenCode in
one Mac app, with Linux hosts and bots on your own tailnet and one library
synced across your devices. The guides cover what you can do in the app; the
references record the contracts behind it.

These pages follow the code on `main`. See the
[release notes](https://github.com/wovenmatter/wovenmatter/releases) for changes
in your installed version.

## Guides

### Get started

1. [Getting started](guide/getting-started.md): install Woven Matter and send your first task.
2. [Agent setup](guide/agents.md): use your existing installations and provider accounts, or install a harness.
3. [Conversations](guide/conversations.md): models, permissions, tools, and sessions in parallel.

### Work with your agents

- [Workspaces and storage](guide/workspaces.md): project folders, chat directories, and where your work lives.
- [Pi Durable](guide/default-agent.md): the built-in agent, its tools, provider connections, and fallback models.
- [Connections and dictation](guide/connections-and-dictation.md): shared accounts, web search, local model servers, and on-device dictation.
- [Executor apps](guide/executor.md): shared app capabilities, approvals, and code mode.
- [Notes and data](guide/notes-and-data.md): Notes, Sheets, Artifacts, Pages, the browser, Library, and databases beside your work.
- [Scheduled work and usage](guide/schedules-and-usage.md): scheduled tasks, timers, Calendar, and provider usage.

### Your devices

- [Apple devices](guide/apple-devices.md): your Macs and the library they share.
- [Remote workspaces](guide/remote-workspaces.md): add a Linux host and run agents there.
- [Bots](guide/bots.md): long-running agents, each in its own container.
- [Updates](guide/updates.md): versions and updates for every device and harness in one place.
- [Troubleshooting](guide/troubleshooting.md): setup, connection, sync, and data problems.

## Architecture

- [Architecture](ARCHITECTURE.md): the library, the background server and the UI, and the rules they keep.
- [Shared workspace browser](design/embedded-browser.md)

## References

- [Mac access and credentials](MAC_ACCESS.md): Permissions & Access, Keychain, and browser credentials.
- [Chat and note menu actions](CHAT_MENU_ACTIONS.md)
- [Document preview tabs](DOCUMENT_PREVIEWS.md)

## Build and contribute

- [Contributing](../CONTRIBUTING.md), including documentation style
- [Dependency policy](DEPENDENCIES.md)
- [Desktop updates](DESKTOP_UPDATES.md)
- [UI style guide](STYLE_GUIDE.md) and [app icons](app-icons/README.md)
- [Product analytics](analytics/README.md)
