# Woven Matter

[![Download Woven Matter for Apple silicon](https://img.shields.io/badge/Download-Woven_Matter_for_Apple_silicon-000000?logo=apple&logoColor=white)](https://github.com/wovenmatter/wovenmatter/releases/latest)

A native Mac app for working with coding agents, on your Mac and on remote
Linux machines. Bring your agents, conversations, notes, and data into one
workspace, using your own provider accounts.

[Get started](docs/guide/getting-started.md) · [Documentation](docs/README.md) ·
[Website](https://wovenmatter.com) · [Release notes](https://github.com/wovenmatter/wovenmatter/releases)

## Work with your agents

- **Choose your agent.** Use Codex, Claude Code, Grok Build, Cursor, Hermes,
  OpenCode, or Pi, and connect OpenClaw agents.
- **Work locally or remotely.** Start on your Mac, or create persistent Linux
  workspaces and manage their agents over SSH.
- **Keep work together.** Organize conversations in folders, open chats side by
  side, and work with notes, spreadsheets, and HTML alongside them.
- **Return to ongoing work.** Reopen conversations, review tool activity, and
  manage supported Hermes and OpenClaw scheduled jobs from Cron Jobs.
- **See your usage.** Review recorded activity and supported provider usage in
  one place.

Available models, sign-in methods, and conversation controls depend on the
agent and provider. [Agent setup](docs/guide/agents.md) explains the differences.

## Get started

1. [Download the latest release](https://github.com/wovenmatter/wovenmatter/releases/latest)
   and move Woven Matter into Applications.
2. Open **Settings → Local agent workspace** to review your workspace and
   install or enable an agent runtime.
3. Complete that agent's sign-in or connection setup, then choose **New chat**.

You need an **Apple silicon Mac running macOS 26 or later** for the published
app, plus your own provider access for model calls. Xcode is only needed to
build from source. A remote host is optional.

For work on another machine, follow [Remote workspaces](docs/guide/remote-workspaces.md).
Existing local Buzz workspaces can also be linked from Settings; Buzz is optional
and disabled by default.

## Your workspace

Local agents share `~/.woven-matter`. Each app-created remote workspace has its
own copy at `/home/.woven-matter`, inside a persistent container home.

```text
.woven-matter/
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  REPOS/
  Databases/
  GUIDES/
  PLANS/
  RESEARCH/
  WORK_LOGS/
  OUTBOX/
  .scratch/
```

This is the initial layout, not a restriction on how you organize your work.
On your Mac, `REPOS` and `Databases` can link to folders you already use.
The initializer preserves an existing `CLAUDE.md` instead of replacing it.

The app saves notes and conversation records in a separate local SQLite store;
they are not all files in this tree. Remote workspace files remain on their
host. See [Workspaces and storage](docs/guide/workspaces.md) for the distinction.

## Learn more

- [Conversations and everyday work](docs/guide/conversations.md)
- [Notes, spreadsheets, and databases](docs/guide/notes-and-data.md)
- [Scheduled work and usage](docs/guide/schedules-and-usage.md)
- [Troubleshooting](docs/guide/troubleshooting.md)

Report bugs and suggest improvements through [GitHub issues](https://github.com/wovenmatter/wovenmatter/issues).
For vulnerabilities, follow the [security policy](SECURITY.md).

## Build and contribute

Start with [Contributing](CONTRIBUTING.md) for development requirements, build
commands, and validation. Integration references and maintainer procedures are
listed at the bottom of the [documentation index](docs/README.md).

Woven Matter is [MIT licensed](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md)
and [trademarks](TRADEMARKS.md) for redistribution details.
