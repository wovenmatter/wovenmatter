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
- [Notes and data](guide/notes-and-data.md): notes, spreadsheets, HTML, the browser, Library, and databases beside your work.
- [Scheduled work and usage](guide/schedules-and-usage.md): scheduled tasks, timers, Calendar, and provider usage.

### Your devices

- [Apple devices](guide/apple-devices.md): pair Macs, keep the library in sync, and the iPhone app (beta).
- [Remote workspaces](guide/remote-workspaces.md): add a Linux host and run agents there.
- [Bots](guide/bots.md): long-running agents, each in its own container.
- [Updates](guide/updates.md): versions and updates for every device and harness in one place.
- [Troubleshooting](guide/troubleshooting.md): setup, connection, sync, and data problems.

## Architecture

- [Woven everywhere](architecture/WOVEN_EVERYWHERE.md): devices, membership, library sync, streaming, and bots.
- [Paired libraries and execution workspaces](DISTRIBUTED_CLIENT_ARCHITECTURE.md): the storage, execution, and sync contract.
- [Paired Mac libraries](PAIRED_MAC_LIBRARIES.md): pairing, sync, upgrade, and recovery between Macs.
- [Conversation streaming](CONVERSATION_STREAMING.md): how live sessions reach every window and device.
- [Background execution](architecture/BACKGROUND_EXECUTION.md): the background server and work that continues while the window is closed.
- [Project roots and managed data](WORKSPACE_DATA_MODEL.md): folders, roots, and managed datasets.
- [Session creation](SESSION_CREATION.md): how a new chat captures its defaults.
- [Active-run steering](architecture/active-run-steering.md): sending to a session while it is working.
- [Pi Durable execution storage](architecture/PI_DURABLE_STORAGE.md)
- [Default agent credentials](architecture/DEFAULT_AGENT_CREDENTIALS.md)
- [Internal database concurrency](architecture/ASYNC_DATABASE.md)
- [Chat HTML rendering](architecture/CHAT_HTML_RENDERING.md)
- [Shared workspace browser](design/embedded-browser.md)

## References

### Agents and tools

- [Woven MCP agent tools](AGENT_TOOLS.md): tools, access, outside agents, and bot keys.
- [Native Woven instructions](NATIVE_INSTRUCTIONS.md)
- [Program status](program-status.md): the session status vocabulary.
- [Mac access and credentials](MAC_ACCESS.md): Permissions & Access, Keychain, and browser credentials.
- [Runtime installation and updates](RUNTIME_MAINTENANCE.md)
- [OpenCode integration](opencode-v2/PARITY.md) and [testing](opencode-v2/TESTING.md)
- [Chat and note menu actions](CHAT_MENU_ACTIONS.md)
- [Document preview tabs](DOCUMENT_PREVIEWS.md)
- [Finding and setting up Macs](APPLE_DEVICE_SETUP.md)

### Linux hosts

- [Native Linux hosts](reference/REMOTE_HOSTS.md): install, layout, permissions, and lifecycle.
- [Linux host validation](reference/REMOTE_HOST_VALIDATION.md)
- [Remote browser performance](reference/REMOTE_BROWSER_PERFORMANCE.md)
- [Remote database limits](reference/REMOTE_DATABASES.md)

### iPhone app (beta)

- [iOS app](../ios/README.md): building, TestFlight, and structure.
- [Quick Chat lifecycle](IOS_CONTINUED_EXECUTION.md)
- [iOS Pi Durable runtime](../ios/Runtime/README.md)
- [Embedded execution test package](IOS_EMBEDDED_EXECUTION.md)

## Build and contribute

- [Contributing](../CONTRIBUTING.md), including documentation style
- [Maintainer workflow](MAINTAINER_WORKFLOW.md)
- [Dependency policy](DEPENDENCIES.md)
- [Desktop updates](DESKTOP_UPDATES.md)
- [Distributed client acceptance](DISTRIBUTED_CLIENT_TESTING.md)
- [UI style guide](STYLE_GUIDE.md) and [app icons](app-icons/README.md)
- [Product analytics](analytics/README.md)
