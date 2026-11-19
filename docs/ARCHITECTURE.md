# Architecture

Woven Matter is three parts that are built and maintained separately.

- **The Woven Matter library**: one SQLite database on each machine, and the
  sync that keeps the machines' copies level.
- **The Woven Matter background server**: one process on each Mac and Linux
  machine. It owns everything that runs on that machine and is the only thing
  that touches that machine's library.
- **The Woven Matter UI**: a thin client. It draws what servers tell it and
  sends what the person does. It holds no database and runs no agents.

A Mac has the server, the library and the UI. A Linux machine has the server
and the library. The iPhone and iPad app will be a UI client later; `ios/` is
not part of the build.

Tailscale is the security boundary. Every machine on the person's own tailnet
that runs the server is one of their Woven machines.

## Rules

These hold everywhere. A change that breaks one is wrong even if it works.

1. The UI never opens SQLite and never imports the library. It asks a server.
2. Each machine's library has exactly one writer: that machine's server, on one
   serial write lane. No other process is given the file.
3. No SQL triggers. Whatever a write must also do, the writer does in the same
   transaction, in code.
4. One sync mechanism for every synced table. No per-feature channel.
5. A session has one owning machine for its whole life. It never moves.
6. A transcript is stored once in the library. Each runtime keeps its own
   native log; the library's copy is for reading when the owner is away.
7. The database is not in the live path. A server streams to the UI directly
   and saves finished items as it goes.
8. No signing, pairing, approval or bearer tokens between machines. Tailscale
   decides who may connect.
9. No version numbers on anything inside the codebase: not on schemas,
   protocols, routes, tables, files, capabilities or features. Only the app
   has a version.
10. No code for old data, old releases or old behaviour. There is nothing to
    migrate and nothing to stay compatible with.
11. One definition of each thing: one wire protocol, one tool catalog, one
    schema, one scheduler, one adapter interface.

## Layout

| Path | What it is | May depend on |
| --- | --- | --- |
| `protocol/` | The wire types every client and server speaks. Swift. | nothing |
| `library/` | Schema, the writer, reads, sync. Swift, Mac and Linux. | `protocol/` |
| `server/` | The background server. Swift, Mac and Linux. | `library/`, `protocol/` |
| `app/` | The Mac UI, and the entry point that starts the server from the signed app. | `protocol/`; `server/` only at that entry point |
| `default-agent/` | Pi Durable, run by the server as a Node child process. | |
| `bots/` | The bots runtime, run by the server as a Node child process. | |
| `harnesses/` | The harness catalog and adapters. | |
| `ios/` | The old phone app. Untouched and not built. | |

The build enforces the dependency column. View code cannot reach the library
because nothing it can import exposes it.

Node is used only for the two child processes. There is no Node server.

## Machines

A machine is a Mac or Linux computer on the person's tailnet that runs the
server. It has a permanent identifier, created on first start, and a name that
starts as its tailnet name and can be renamed; the name syncs.

- **Joining is automatic.** A server looks at the tailnet's machine list, tries
  the Woven port on each, and treats those that answer as Woven machines.
- **Find Devices** lists tailnet machines without a server and installs and
  starts one over SSH.
- **Remove** stops and uninstalls the server on that machine, then deletes the
  machine, its sessions and its folders from every library. There is no way to
  hide a machine. A machine that is only switched off stays listed as offline.
- A server accepts a connection only when Tailscale reports the caller as a
  machine of this tailnet. A machine shared in from another tailnet is refused.

## Connections

One protocol, JSON messages over WebSocket, serves both UI-to-server and
server-to-server. It has requests with replies, and subscriptions that deliver
events. Its types are defined once in `protocol/`.

- On a Mac the UI reaches its own server over a Unix socket in the app's
  support folder. File permissions protect it.
- A server listens on its machine's Tailscale address for other machines.
- The UI connects to its own server for everything in the library, and
  **directly to the owning machine's server** for the live view of anything
  that runs there. Its own server does not relay live streams.

Two machines on different app releases do not sync. The UI says which machine
needs updating.

## The library

One file, `library.sqlite`, in the server's data folder. The schema is declared
once, in code. At start the server compares the file with the declaration and
adds what is missing. There is no schema counter.

### Sync

Every synced row has:

- `id`: permanent and unique across machines.
- `stamp`: when it was last written, as a hybrid logical clock value that
  orders writes across machines even when clocks disagree.
- `changed`: a counter local to this library, set on every local write and on
  every row accepted from another machine.
- `deleted`: a deleted row stays as a marker so the deletion spreads.

A machine pulls from another by asking for rows whose `changed` is above the
last value it received, table by table. A received row replaces the local one
when its `stamp` is newer. Because rows pass on unchanged, any machine can hand
on another machine's rows; the owner need not be online.

Large content (attachments, images, database copies) is stored by content
digest in a file store beside the library and fetched by digest when needed.

### What syncs how

- **Append-only**: session items, usage records, dictation history. Written
  once by the owning machine, never edited.
- **Newest write wins**: machines, sessions (title, folder, archived), folders,
  settings, schedules, sealed secrets, database descriptions.
- **Newest write wins, loser kept**: notes, pages and apps. Each write records
  the `stamp` it was edited from. When a received write was not made on top of
  the local one, the two were edited apart: the newer becomes current and the
  other is saved in that artifact's version history. No separate copy appears.
- **Never syncs**: sync cursors, this machine's identifier, live state, native
  session handles' process state, provider sign-ins.

Rows that belong to a machine (sessions, folders, databases, schedules) carry
that machine's identifier in a column. Ownership is never held in a side table.

## Sessions

A session is one conversation with one runtime on one machine. The runtimes are
Codex, Claude Code, Grok Build, OpenCode, Pi Durable and bots. All six sit
behind one adapter interface in the server and are treated alike:

- The runtime keeps its own native log, in its own storage, in its own format.
  Pi Durable and bots use their SDK's stock SQLite storage in their own files.
- The server keeps the runtime's process alive between turns, as a terminal
  would. It does not stop and replay it after each turn.
- While a turn runs, the server streams text and tool activity to subscribed
  clients as it arrives.
- When an item finishes (a user message, an assistant message, a tool call with
  its result) the server writes it once to `session_items`, in the same step as
  it announces it. Partial text is never written.
- A client that subscribes gets the finished items, the item in progress if
  there is one, then live events.

When the owning machine is unreachable, the session shows its saved items and
sending is disabled.

When a runtime no longer has the native session behind a chat, the server says
so in the chat and offers a new session. It never starts a fresh native session
under the old chat.

Questions, approvals and run state are live state on the owning server. They
are not stored in the library.

A goal is a prompt that belongs to its session; the session works against it
until it is met or cleared.

## Folders and the sidebar

A folder is a name plus a directory on one machine. It belongs to that machine.

The sidebar shows this machine first, then one section for each other machine,
online or offline, titled by the machine's name. Each section lists that
machine's agents and folders. Starting a chat from a section runs it on that
machine. A new folder is created by the machine that will own it.

## Notes, pages and apps

These are documents in the library. Any machine can edit them at any time
through its own server, online or not. Conflicts follow the rule above.

An app is a live HTML page an agent builds. It has saved state, which is part
of the app's document, and it can read from databases.

## Databases

A database is a named SQLite file that notes, pages and apps link to for live
data. It is separate from the library.

- It lives on one owning machine. That machine's server is its only writer.
- Any machine can write to it: the write goes to the owner's server through the
  Woven MCP and is carried out there. If the owner is unreachable the write
  fails with a clear message.
- After a write the owner publishes a copy. Every machine keeps the latest copy
  and reads from it, so linked content still shows data when the owner is away.

## The Woven MCP

Agents reach Woven through one tool catalog, defined once in the server. Each
server offers it to the runtimes on its machine and carries the tools out. A
tool that concerns another machine (a database it owns, a session it runs) is
forwarded to that machine's server. Browser and computer-use tools are carried
out by the UI on that Mac, because macOS ties those permissions to the app
window; the server asks a connected UI to do them.

## Scheduling

Each server has one scheduler. Scheduled tasks, timers and wake-ups are all
entries in it, and each entry belongs to the machine that will run it. The
calendar page shows and adds entries.

## Bots

There is one set of bots and one Forum. They live on one machine that the
person chooses from their Woven machines; that choice is a synced setting, and
only that machine's server runs the bots runtime.

- Any UI talks to the bots and the Forum through the home machine's server.
- Bot chats and Forum posts are saved to the library like every other
  transcript, so they can be read when the home machine is away.
- Everything a bot is sits in one folder on the home machine, with nothing in
  it tied to that machine: the bots' own database (bots, chats, memories, the
  Forum, schedules), the model profiles, and each bot's files.
- **Transfer** moves the bots to another machine: stop them, copy that folder,
  start them there, change the home setting, remove the old copy. Sign-ins that
  are per machine are made again on the new one.

## Sign-ins and secrets

- Harness CLIs keep their own sign-ins on each machine.
- Subscription sign-ins (ChatGPT, Claude, Grok) are per machine and stay in the
  Keychain on a Mac or a private file on Linux. They are never in the library.
- API keys for Pi Durable and bots, and the GitHub key, sync. Each is sealed
  separately for each machine with that machine's public key, so only that
  machine can open its copy.
- Agents never receive a key file. They get a socket that asks the server to
  use the key for them.

## Mac specifics

macOS grants permissions to the signed app. So the server, although it is
separate code in `server/` and a separate process, is started from the app's
own signed program. The person grants each permission once. See
[Mac access](MAC_ACCESS.md).

## Development

`scripts/build_and_run.sh --instance NAME` builds the app and starts it with
its own data folder and its own server. It never reads or changes the data of
an installed app.

## Tests

The test suite is small on purpose. A test earns its place by covering
behaviour that would hurt if it broke: sync converging, a transcript being
saved once, an owner being the only writer, a session surviving a restart. One
test per behaviour, at the level where the behaviour lives. No tests for
removed features, for wording, or for how code is arranged. Tests use a
stand-in runtime and never call a provider. `scripts/test-changes.sh` runs
them.
