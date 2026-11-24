# Woven Matter documentation

Woven Matter runs Pi Durable, Codex, Claude Code, Grok Build and OpenCode on
your Macs and Linux machines, with bots and one library synced across your
machines over your own tailnet. The guides cover what you can do in the app;
the references record the contracts behind it.

These pages follow the code on `main`. See the
[release notes](https://github.com/wovenmatter/wovenmatter/releases) for changes
in your installed version.

## Guides

### Get started

1. [Getting started](guide/getting-started.md): install Woven Matter and send your first task.
2. [Agent setup](guide/agents.md): use your existing installations and provider accounts, or install a harness.
3. [Conversations](guide/conversations.md): models, permissions, Woven tools, and sessions in parallel.

### Work with your agents

- [Folders and storage](guide/workspaces.md): project folders, chats without a folder, and where your work lives.
- [Pi Durable](guide/default-agent.md): the built-in agent, its providers, and its models.
- [Connections and dictation](guide/connections-and-dictation.md): subscriptions, API keys, GitHub, Mac permissions, and on-device dictation.
- [Notes and data](guide/notes-and-data.md): notes, pages, sheets, apps, Library, the browser, and databases.
- [Scheduled work and usage](guide/schedules-and-usage.md): scheduled tasks, timers, wake-ups, and usage.

### Your machines

- [Your machines](guide/machines.md): Macs and Linux machines on your tailnet, and how they join.
- [Bots](guide/bots.md): long-running agents, each in its own container, and the Forum.
- [Updates](guide/updates.md): Woven Matter and harnesses on every machine.
- [Troubleshooting](guide/troubleshooting.md): setup, connection, sync, and data problems.

## Architecture

- [Architecture](ARCHITECTURE.md): the library, the background server and the UI, and the rules they keep.

## References

- [Mac access](MAC_ACCESS.md): Permissions & Access, which process macOS credits, and the Keychain.
- [Chat and note menus](CHAT_MENU_ACTIONS.md): pin, rename, export, Trash and Restore.
- [Document previews](DOCUMENT_PREVIEWS.md): Quick Look tabs and files in replies.
- [Embedded browser and Computer Use](design/embedded-browser.md): the browser, the `browser` and `computer` tools, and CEF maintenance.
- [Analytics](analytics/README.md): the app's anonymous usage statistics, the GitHub analytics workflow and the PostHog dashboard.

## Build and contribute

- [Contributing](../CONTRIBUTING.md), including documentation style
- [Dependency policy](DEPENDENCIES.md)
- [Desktop updates](DESKTOP_UPDATES.md)
- [UI style guide](STYLE_GUIDE.md) and [app icons](app-icons/README.md)
