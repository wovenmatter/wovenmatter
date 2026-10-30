# Woven Matter documentation

Woven Matter is a Mac workspace for Pi Durable, Codex, Claude Code, Grok Build,
and OpenCode. Start locally, then add a Linux host if you need one. iOS is coming soon.

## Get started

1. [Getting started](guide/getting-started.md): install the app and send your first task.
2. [Harnesses and accounts](guide/agents.md): use existing installations and accounts, or install a harness.
3. [Conversations and panels](guide/conversations.md): work side by side and return to saved sessions.

## Use the workspace

- [Workspaces and storage](guide/workspaces.md): project folders, reference locations, and where your files live.
- [Remote workspaces](guide/remote-workspaces.md): run agents on a native Linux host over Tailscale.
- [Pi Durable](guide/default-agent.md): the included agent, provider connections, models, and fallbacks.
- [Agent tools and permissions](guide/agent-tools.md): defaults, conversation controls, and outside-agent access.
- [Notes, Library, and Databases](guide/notes-and-data.md): documents, exchanged files, and linked data.
- [Calendar, Scheduled Tasks, and Usage](guide/schedules-and-usage.md): events, recurring work, and account limits.
- [Executor](guide/executor.md): connect apps and choose which accounts agents can use.
- [Accounts and dictation](guide/connections-and-dictation.md): shared accounts, on-device speech, and local model servers.
- [Troubleshooting](guide/troubleshooting.md): resolve setup, connection, and data problems.

These guides describe the code on `main`. Check the
[release notes](https://github.com/wovenmatter/wovenmatter/releases) for your installed version.

## Technical references

- [Woven MCP tools](AGENT_TOOLS.md) and [credential access](KEYCHAIN_ACCESS.md)
- [Native Linux hosts](reference/REMOTE_HOSTS.md) and [remote workspace internals](reference/REMOTE_WORKSPACES.md)
- [Managed remote databases](reference/REMOTE_DATABASES.md)
- [Runtime installation and updates](RUNTIME_MAINTENANCE.md)
- [Pi Durable implementation](reference/DEFAULT_AGENT.md)
- [Native Woven instructions](NATIVE_INSTRUCTIONS.md)
- [Engineering notes](internals/README.md)

## Build and maintain

- [Contributing](../CONTRIBUTING.md) and [maintainer workflow](MAINTAINER_WORKFLOW.md)
- [Development builds](DEVELOPMENT_BUILDS.md) and [dependency policy](DEPENDENCIES.md)
- [Desktop updates](DESKTOP_UPDATES.md) and [Apple device setup](APPLE_DEVICE_SETUP.md)
- [UI style guide](STYLE_GUIDE.md) and [app icons](app-icons/README.md)
- [Security policy](../SECURITY.md)
