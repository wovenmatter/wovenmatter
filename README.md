# Woven Matter

[![Download Woven Matter for Apple silicon](https://img.shields.io/badge/Download-Woven_Matter_for_Apple_silicon-000000?logo=apple&logoColor=white)](https://github.com/wovenmatter/wovenmatter/releases/latest)

**The workspace for all of your harnesses.**

Woven Matter brings **Codex, Claude Code, Grok Build, Cursor, Hermes, OpenClaw,
OpenCode, and Pi** together in one simple, welcoming Mac app. Work with the
agents you already use, try others, and keep your conversations and notes
together in an interface designed to feel comfortable from the start.

Whether you're researching a subject, planning a project, working with data,
or building software, you can choose the agent that fits the task. Woven Matter
is a native macOS app designed to stay lightweight and responsive while you
work with multiple agents.

[Download](https://github.com/wovenmatter/wovenmatter/releases/latest) ·
[Getting started](docs/guide/getting-started.md) · [Documentation](docs/README.md) ·
[Website](https://wovenmatter.com)

## Your agents, working in the same place

Each of the eight harnesses has a dedicated integration in Woven Matter. Use
your existing installations and provider accounts, or install a harness from
Settings. Models, authentication, and available controls follow the capabilities
of the harness you're using.

All agents in your **local agent workspace** work from the same root on your
Mac. They can use the same project files, instructions, research, and plans.
When you work with another harness, that shared material is already there.

Each **remote agent workspace** follows the same pattern: its agents share a
root within that workspace. You choose where the work happens, and use Woven
Matter to work with agents in all of those locations.

## Your conversations, saved together

Woven Matter saves the **agent transcripts from your conversations in a local
SQLite database** that powers the app. Conversations with different harnesses,
on your Mac or in remote agent workspaces, are recorded in one place under
your control, alongside your notes and other app records.

That gives you a central record of the work you do in Woven Matter, in addition
to the history a harness keeps itself. Return to earlier conversations, review
what an agent did, and continue supported sessions when the agent is connected.
You can organize a project's conversations together even when you use several
different harnesses to work on it.

The shared record is also the foundation for broader collaboration between
agents. **In development:** a workspace-history CLI that will let agents
retrieve prior conversations recorded by Woven Matter, so you can bring earlier
work into a new task with another harness. Transcripts are saved centrally
today; automatic access to that history across agents is still being built.

Project files stay in their respective workspaces. The central database stores
the conversation record; it does not automatically copy every file an agent
creates or synchronize local and remote folders.

## Work on your Mac and other machines

Start with the local agent workspace on your Mac. If you have another Linux
machine on your network or Tailscale network, you can create a remote agent
workspace on it from Woven Matter. A rented Linux host reachable over SSH works
too; Tailscale is optional.

Each remote workspace is a container with a persistent home for its files,
harnesses, and credentials. You can create multiple workspaces, run agents in
parallel, and work with them from the same Mac interface. Their conversation
transcripts are saved in Woven Matter's database alongside your local chats.

Remote setup includes host inspection, any authorized preparation, and controls
for the workspace and its runtimes. A remote host needs compatible Docker
support. See [Remote workspaces](docs/guide/remote-workspaces.md) for setup.

Whether work continues after you close the app depends on the harness, its
service, and the machine running it. See [Scheduled work](docs/guide/schedules-and-usage.md)
for the conditions around background jobs.

## Keep your work beside the conversation

Open multiple chat panels to follow different agents at once, or keep a note
beside a conversation. Read a research summary while discussing it, keep a plan
in view as work progresses, and organize notes and conversations in folders.

Agents can also read and edit a note you're working on through Woven Matter's
note tools. This gives longer responses and reference material a place beside
the chat, where you can keep reading without scrolling back through messages.
Agent-driven note editing, tables, and HTML workflows are still experimental.

Database folders give agents a place to curate data that you can revisit or
present in spreadsheets and HTML artifacts. Usage, Calendar, Library, and Cron
Jobs add other ways to organize and follow your work. These supporting features
are evolving; the core of Woven Matter is working with your harnesses, sharing
workspace files, and keeping your conversations together.

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
  REPOS/
  Databases/
  GUIDES/
  PLANS/
  RESEARCH/
  WORK_LOGS/
  OUTBOX/
  .scratch/
```

Adapt the contents to your work. On your Mac, `REPOS` and `Databases` can link
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
