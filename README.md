# Woven Matter

[![Download Woven Matter for Apple silicon](https://img.shields.io/badge/Download-Woven_Matter_for_Apple_silicon-000000?logo=apple&logoColor=white)](https://github.com/wovenmatter/wovenmatter/releases/latest)

**The workspace for all of your harnesses.**

WovenMatter brings **Codex, Claude Code, Grok Build, Cursor, Hermes, OpenClaw,
OpenCode, and Pi** together in one workspace. Work with all of your harnesses
in a simple, easy-to-use interface that keeps all of your work organized in one
place. All of your agents within each workspace work out of the same root,
allowing them to collaborate and work together seamlessly. WovenMatter ships
with a local agent workspace, which runs locally on your Mac. You can also
launch remote agent workspaces on other machines on your network or Tailscale
network, and work with those agents from the same interface.

WovenMatter is essentially a user interface built on top of a SQLite database.
This database saves all of your conversations, notes, and any other items
created within WovenMatter. This gives you control over your data by saving all
of your work history in one location, so you can return to earlier conversations
and keep related work together. This, along with our user interface and
shared workspace design, allows for seamless collaboration between your agents,
allowing you the freedom to work across the harnesses and models of your choice.

[Download](https://github.com/wovenmatter/wovenmatter/releases/latest) ·
[Getting started](docs/guide/getting-started.md) · [Documentation](docs/README.md) ·
[Website](https://wovenmatter.com)

The **Built-in** agent is ready in local and remote workspaces. Connect your providers,
choose models and fallbacks, and add an Exa search key in Settings.
See [Built-in](docs/guide/default-agent.md).

## Your agents, working in the same place

WovenMatter is a lightweight macOS app designed to let you work and collaborate
with all of your different harnesses. Each of the eight harnesses has a
dedicated first-class integration. Use your existing installations or install
harnesses in the settings page. Use your existing provider accounts and/or API keys.
Models, authentication, and controls depend on the harness you use.

All agents in your **local agent workspace** work from the same root on your
Mac. They can use the same project files, instructions, research, and plans.
When you work with another harness, that shared material is already there.

Each **remote agent workspace** follows the same pattern: its agents share a
root within that workspace. You choose where the work happens, and use Woven
Matter to work with agents in all of those locations.

## Your conversations, saved together

Conversations with different harnesses, on your Mac or in remote agent
workspaces, are saved in the same local SQLite database as your notes and other
items created while working in WovenMatter. This gives you a central work
history alongside the histories each harness already independently maintains.

Return to earlier conversations, review what an agent did, and continue
supported sessions when the agent is connected. Organize a project's
conversations together even when you use several harnesses to work on it.

Project files stay in their respective workspaces. Saving transcripts centrally
does not automatically copy every file an agent creates or synchronize local
and remote folders.

## Work on your Mac and other machines

Start with the local agent workspace on your Mac. If you have another Linux
machine on your network or Tailscale network, you can create a remote agent
workspace on it from Woven Matter. A rented Linux host reachable over SSH works
too; Tailscale is optional.

Each remote workspace is a container with a persistent home for its files,
harnesses, and credentials. You can create multiple workspaces, run agents in
parallel, and work with them from the same Mac interface. Their conversation
transcripts are saved in Woven Matter's database alongside your local chats.

Woven Matter inspects the host and asks you to authorize any preparation before
creating a workspace. Remote hosts need compatible Docker support. See
[Remote workspaces](docs/guide/remote-workspaces.md) for setup and management.

Whether work continues after you close the app depends on the harness, its
service, and the machine running it. See [Scheduled work](docs/guide/schedules-and-usage.md)
for the conditions around background jobs.

## Work across sessions in parallel

Run multiple sessions in parallel with the same harness or across different
harnesses. Use panels to view up to five sessions at once, while additional
sessions can continue running in the background. Open a note beside your
conversation to work on it with your agent. Organize your notes and
conversations in folders to keep related work together.

Agents can also read and edit a note you're working on through Woven Matter's
note tools. This gives longer responses and reference material a place beside
the chat, where you can keep reading without scrolling back through messages.

Database folders give agents a place to curate data that you can revisit or
present in spreadsheets and HTML artifacts. Usage, Calendar, Library, and Cron
Jobs add other ways to organize and follow your work.

Read more about [conversations and panels](docs/guide/conversations.md),
[notes and data](docs/guide/notes-and-data.md), and
[schedules and usage](docs/guide/schedules-and-usage.md).

## Get started

You need an **Apple silicon Mac running macOS 26 or later** for the published
app. No Woven Matter account is required. You use your own AI subscriptions or
API keys; model availability and costs depend on your providers.

1. [Download Woven Matter](https://github.com/wovenmatter/wovenmatter/releases/latest)
   and move it into Applications.
2. Open **Settings → Local agent workspace** to see the harnesses discovered
   on your Mac, or install one you want to try.
3. Enable it and complete its sign-in or connection setup.
4. Choose **New chat**, select your agent, and give it a task.

Start with a harness you already use and have provider access for. If you're
looking for an example, the [getting-started guide](docs/guide/getting-started.md)
can help you choose and set one up. You don't need a remote machine to begin.

Woven Matter and the harnesses you enable need access to the files and accounts
used for your work. Review the credential-access disclosure and any macOS
permission prompts during setup. [Agent setup](docs/guide/agents.md) explains
the installation and connection steps.

## Workspace layout

The local agent workspace starts at `~/.woven-matter`. Each app-created remote
workspace starts at `/home/.woven-matter` inside its persistent container home.
Both use this initial layout:

```text
.woven-matter/
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  Repos/
  Databases/
  GUIDES/
  PLANS/
  RESEARCH/
  WORK_LOGS/
  OUTBOX/
  .scratch/
```

Adapt the contents to your work. On your Mac, `Repos` and `Databases` can link
to folders you already use. Initialization preserves an existing `CLAUDE.md`
instead of replacing it. See [Workspaces and storage](docs/guide/workspaces.md)
for folder setup and the distinction between workspace files and app records.

## Help and feedback

Browse the [documentation](docs/README.md), check
[troubleshooting](docs/guide/troubleshooting.md), or read the
[release notes](https://github.com/wovenmatter/wovenmatter/releases).
Report bugs and suggest improvements through [GitHub issues](https://github.com/wovenmatter/wovenmatter/issues).
For vulnerabilities, follow the [security policy](SECURITY.md).

## Build and contribute

Start with [Contributing](CONTRIBUTING.md) for development requirements, build
commands, and validation. Xcode is needed to build from source, not to use the
published app. Integration references and maintainer procedures are listed in
the [documentation index](docs/README.md).

Woven Matter is [MIT licensed](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md)
and [trademarks](TRADEMARKS.md) for redistribution details.
