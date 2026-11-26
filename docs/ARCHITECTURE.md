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

A machine is a Mac or Linux computer on the person's tailnet, with or without
the server. It has a permanent identifier, created on first start, and a name
that starts as its tailnet name and can be renamed; the name syncs.

The words for these things are fixed, in the code and in everything a person
or an agent reads. A **machine** is the computer itself. Its **workspace** is
where the person works on it: its agents, folders and sessions. Each machine
has one; the **local workspace** is on the machine in use, and every other
machine's is a **remote workspace**. The **host** is only the machine the bots
run on. The **library** is the synced database, never a workspace. A
**device** is only an iPhone or iPad. What a bot keeps in its container is its
**files**.

- **Joining is automatic.** A server looks at the tailnet's machine list, tries
  the Woven port on each, and treats those that answer as Woven machines.
- **Add workspace** lists Linux machines on the tailnet without a server and
  installs and starts one over SSH. The SSH host and user given at install
  are passed to the new server, which keeps them on its own machine row from
  its first start, so any Mac reaches it later exactly as the person's SSH
  settings say. Before each later command over SSH, the machine
  reached must hold that machine's identifier, or nothing runs.
- **Remove** deletes the machine, its sessions and its folders from every
  library. A Linux machine's server is stopped and uninstalled over SSH first;
  a Mac's server stops itself when the removal reaches it. There is no way to
  hide a machine. A machine that is only switched off stays listed as offline.
- A server accepts a connection only when Tailscale reports the caller as a
  machine of this tailnet. A machine shared in from another tailnet is refused.

On Linux the server is a systemd user unit, `woven-server`, installed over SSH
with everything under `~/.local/share/woven-server`. The Mac sends the static
`woven-server` for that machine's architecture with its own copy of Pi Durable,
the bots runtime and the harness files in one archive. The Linux machine
downloads the official Node for Linux from nodejs.org and checks it against
the SHA-256 the Mac app carries. It needs `tar`, `gzip`, `sha256sum`, and
`curl` or `wget`. The installer turns on
lingering for the account, so the server keeps running after the person logs
out. The bots' container engine is a system unit, `woven-bots-engine`,
installed once with sudo. A development instance appends its instance name to
both unit names. It stays off the tailnet unless it is given a port of its own
(for example 47338); it then listens on that port, finds only servers on that
port, and installs servers that use it.

## Connections

One protocol, JSON messages over WebSocket, serves both UI-to-server and
server-to-server. It has requests with replies, and subscriptions that deliver
events. Its types are defined once in `protocol/`.

- On a Mac the UI reaches its own server over a Unix socket that only the
  person can open.
- A server listens on its machine's Tailscale address, port 47337, for other
  machines and for UIs on other machines.
- The UI connects to its own server for everything in the library, and
  **directly to the owning machine's server** for the live view of anything
  that runs there. Its own server does not relay live streams.
- The UI follows its own server's machine list. Each other machine is listed
  with where its server answered, which the server knows only while it is
  linked to that machine, so the list is sent again whenever a link starts or
  ends, and the UI connects to the address listed.

Every connection is pinged every 15 seconds and closed after 45 seconds of
silence, so a machine that slept or lost power is noticed.

Machines on any app releases link and show online to each other. They sync
while their libraries have the same shape: each server's hello carries a digest
of its synced tables, their rules and their columns. With different shapes
they stay linked but pull nothing, and the UI says the machine can't sync right
now until the one behind is updated.

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

A library has one `changed` counter across all its tables. A machine pulls from
another by asking for rows whose `changed` is above the last value it received,
and gets them from every table in that order. A received row replaces the local
one when its `stamp` is newer. Because rows pass on unchanged, any machine can
hand on another machine's rows; the owner need not be online.

Deletion is final: a deleted row stays deleted whatever edit arrives later.
Deleting a row also removes what belongs to it (a session's items, an
artifact's versions, a machine's sessions and folders), and rows that arrive
later for a deleted parent are refused. Settings and sealed secrets are the
exception: they are keyed by name, so they are never deleted. Unsetting one
writes an empty value, and the newest write wins as usual.

Large content (attachments, images, database copies, the visual replies agents
show in chats) is stored by content digest in a file store beside the library and
fetched by digest when needed.

### What syncs how

- **Append-only**: session items, usage records, dictation history. Written
  once by the owning machine, never edited.
- **Newest write wins**: machines, sessions (title, folder, archived), folders,
  settings, schedules, sealed secrets, database descriptions. Only the owning
  machine writes its `schedules` rows; a request about another machine's entry
  is refused with the owner's name, so the caller can send it there.
- **Newest write wins, loser kept**: notes, pages, sheets and apps. Each write records
  the latest write it has seen from each machine. When a received write has
  not seen everything the local one has, the two were edited apart: the newer
  becomes current and the other is saved in that artifact's version history.
  No separate copy appears.
- **Never syncs**: sync cursors, this machine's identifier, live state, native
  session handles' process state, provider sign-ins, how far the harness
  histories have been read.

Rows that belong to a machine (sessions, folders, databases, schedules) carry
that machine's identifier in a column. Ownership is never held in a side table.

## Sessions

A session is one conversation with one runtime on one machine. The runtimes are
Codex, Claude Code, Grok Build, OpenCode, Pi Durable and bots. All six sit
behind one adapter interface in the server and are treated alike:

- Codex and Claude Code run behind ACP adapters. The server installs an
  adapter by itself, with the npm bundled beside it, as soon as it finds that
  CLI without one. Installing an adapter never installs or updates the CLI.
- The runtime keeps its own native log, in its own storage, in its own format.
  Pi Durable and bots use their SDK's stock SQLite storage in their own files.
- The server keeps the runtime's process alive between turns, as a terminal
  would. It does not stop and replay it after each turn.
- While a turn runs, the server streams text and tool activity to subscribed
  clients as it arrives.
- A message sent while a turn runs steers that turn: it goes to the runtime
  at once through the runtime's own mid-turn input, and the turn takes it in
  and goes on. Nothing is queued. The message is saved where it came, after
  the reply so far and before what the turn says next, and the turn still
  ends once. Goal, timer, wake-up and scheduled turns never steer.
- A runtime can start a turn by itself, for example when a background
  command it ran finishes. Its first output with no turn running starts a
  turn, which shows as running, can be stopped and is saved item by item
  like any other. It ends with the runtime's own end report, or, for a
  runtime that gives none, after a few seconds without output. Should an
  end report never come, it ends after two minutes without output with no
  tool call open and no question waiting. A goal does not count such a turn
  or continue after it.
- When an item finishes (a user message, an assistant message, a tool call with
  its result) the server writes it once to `session_items`, in the same step as
  it announces it. Partial text is never written while it streams. When a
  turn is stopped, what was said so far is saved as the finished item.
  Items are numbered in the order they finish; a tool call the server saw
  start carries where it started, counted rather than timed (the session's
  last saved item then, and its place among the calls that started), and
  clients show it in that place. When a turn ends, the server saves a
  `turnEnded` notice before it says so, so every view times the turn from
  its saved end, and its text is "stopped" when Stop was asked while the
  turn ran; views draw nothing for it.
- A tool call's stored input and output are each capped at 256K characters;
  the start and the end are kept, with a line saying how much was left out.
- A script a harness runs in code mode, calling tools from JavaScript, is
  one tool call: its source, its output, and the tool calls it made, at most
  100, each with its input cut to about 1,000 characters. Its string and
  template literals over 2,000 characters keep only their length, so a page
  written into a script is not kept.
- An agent shows a chart, a table or anything interactive as a visual reply,
  with the Woven tool `render_html`: one self-contained HTML document, at most
  512,000 characters, given as its text or as an HTML file the agent wrote on
  the machine the session runs on (never from a bot), with its absolute local
  image paths embedded (each a real image of at most 10 MiB, the whole at most
  25 MiB) on that machine. A visual reply is not a Page: it belongs to its chat only, is not in
  the Library and is never edited. Its HTML is stored once, in the content
  store; the session gets one small item, `visualReply` (title, starting
  height, the width it asked for if any, digest), saved when the tool is called, after the text so far. The
  runtime's own report of the call keeps only the HTML's length, and the chat
  shows the visual reply in its place. The chat shows it above the agent's text
  in an opaque sandboxed frame, with no access to the app, its tools or the
  session, and a machine that does not hold it fetches it by digest. The frame
  takes the height of the visual reply's content as it changes, so one sized by
  the viewport (vh, vmin, vmax) is refused. It is the chat's width, or the
  narrower width the agent asked for.
- A client that subscribes gets the newest 200 finished items, the item in
  progress if there is one, then live events. Older items are fetched a page
  at a time as the person scrolls back.

When the owning machine is unreachable, the session shows its saved items and
sending is disabled.

When a runtime no longer has the native session behind a chat, the server says
so in the chat and offers a new session. It never starts a fresh native session
under the old chat.

Questions, approvals and run state are live state on the owning server. They
are not stored in the library.

A goal is a prompt that belongs to its session. Setting one on an idle session
starts a turn toward it, and each turn that ends with the goal still set is
followed by one asking the runtime to continue. It ends when the agent calls
the Woven tool `goal_met` or the person clears it. It pauses after an
interrupted or failed turn, while a question or approval waits, after the
person dismisses one, and after three goal turns in a row that neither said nor did anything. The person's
next message resumes it.

## Usage

Each server counts the usage of every harness on its own machine, whether the
work was done in Woven Matter or not, and writes it to the library as usage
records, which sync like any other append-only rows. The Usage page on any
machine reads its own library and so shows every machine.

- **Codex, Claude Code, Grok Build, OpenCode and the Pi CLI** are counted only
  from their own history: Codex's rollouts (`~/.codex/sessions` and
  `archived_sessions`, compressed ones too), Claude Code's transcripts
  (`~/.claude/projects`), Grok Build's `updates.jsonl` (`~/.grok/sessions`),
  OpenCode's database (`~/.local/share/opencode/opencode.db`) and the Pi CLI's
  sessions (`~/.pi/agent/sessions`). A turn Woven Matter runs with one of them
  writes no usage of its own; its usage is in that history and is counted from
  there, once. Woven Matter's own record of which native session each of its
  sessions is (`native_sessions`) names the session and marks it as made in
  Woven Matter.
- **Pi Durable** writes one record per turn, and **bots** one per model turn,
  in their chats and in the Forum alike, from what the runtime reports. Nothing
  else counts them.
- Only counts leave a history: the harness, model, time, tokens by kind, the
  cost when the harness records one, and the harness's own session
  identifier. No text, path or credential is read into the library.
- The server reads each history on from where it stopped (a digest of the
  path keys the place, in a local table), at start and every two minutes. A
  file is the same history while its first line is, so one copied back,
  restored or rewritten whole is read on, not again. A copy of another
  session's responses in a resumed or forked session is recognised by the
  session it names and left out. Beyond that, each response is remembered by
  the harness's own identifier for 60 days, so a file whose first line
  changed is read again from the start without counting what was seen in
  that time.
- Every history may have been written by anyone. A line that is not what its
  harness writes is skipped; a file that cannot be read (it fails to
  decompress, or the database is locked or corrupt) is passed over until it
  changes. A read is counted in the history's row before it begins and the
  count cleared when it ends, so one open when the server dies is read again
  at the next start, and one open at two such ends in a row is passed over
  until it changes; a normal stop ends the read in progress, or OpenCode's
  page, first and counts nothing. Counts are held below a trillion per response,
  and decompression stops at 256 MiB per file.
- What it reads is summed per harness session, model and hour in a local
  table. When the hour is over, each sum becomes one synced record, so a year
  of heavy use stays a few thousand rows per machine. The page includes this
  machine's hour in progress.

## Usage statistics

Anonymous usage statistics are sent by servers, never by the UI. A server
counts a person as active when a deliberate request from a UI connection
succeeds. The UI tells its own server only what the server cannot see: the
app opening and the updater's steps. The library's anonymous identifier and
the on/off choice are ordinary synced settings. Throttle times and the last
release run stay in a local table. Only a release server sends. See
[Analytics](analytics/README.md).

## Folders and the sidebar

A folder is a name plus a directory on one machine. It belongs to that machine.

The sidebar shows this machine first, then one section for each other machine,
online or offline, titled by the machine's name. Each section lists that
machine's folders. A chat started in a folder runs on that folder's machine.
A new folder is created by the machine that will own it.

## Notes, pages, sheets and apps

These are documents in the library. Any machine can edit them at any time
through its own server, online or not. Conflicts follow the rule above.

An app is a live HTML document an agent builds. It has saved state, which is part
of the app's document, and it can read from databases.

## Databases

A database is a named SQLite file that notes, pages, sheets and apps link to
for live data. It is separate from the library.

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
window; the server asks a connected UI to do them. So is `preview_html`, which
renders HTML as the chat would show it as a visual reply, in a web view no
window holds, and returns a screenshot; it saves nothing.

- A harness or Pi Durable starts a small local bridge, `harnesses/woven-mcp.mjs`,
  that speaks MCP over standard input and output and passes it to the server's
  tool socket, a Unix socket that only the person can open. The bridge first
  says a key the server gave that runtime in memory, so the server knows who
  is calling. OpenCode serves all its sessions through one bridge and names
  the session in each call. It offers the tools only in its Code Mode, to
  scripts, so its instructions list each tool's exact call. The bots runtime
  asks for the tools over its own connection to the server.
- Each tool declares the shape of its result, and every success is one JSON
  object of that shape, given to MCP as structured content and as its text, so
  a script gets a value it can use and pass back: an id is named as the
  argument that takes it. A failure is an error result with text alone.
  `preview_html`, `browser` and `computer` put their images beside that
  object, never in it. Old transcripts keep the text their tools returned.
- The tools are in groups, and each session is offered only the groups it may
  use. A tool in no group (goals, places, `render_html`, `preview_html`) is
  always offered to sessions. Bots are offered only the tools meant for them,
  and a call to any other is refused. Bots are offered the browser, the
  computer and `preview_html` as sessions are, while **Give bots Woven MCP** is
  on. Nothing on the host's disk is read for a bot's visual reply, so it is
  previewed and stored as written.
- Agents outside Woven Matter on that machine can use the same bridge without a
  key, only while the person turns that on, and only with the groups chosen
  for them.
- Sessions and bots alike start (`start_session`), steer (`send_to_session`)
  and stop (`stop_session`) agent sessions on any machine; each call is carried
  out by the session's owner. A caller may stop only a session it manages: one
  where it is the author of an item, because it started it or sent it a
  message. `start_session` returns once the caller's machine holds the new
  session, so the next call can name it. A message from a session or a bot is
  saved as theirs. A session reports back to a bot with `message_bot`, which
  the bot's chat saves as from that session. Only bots post to the Forum, with
  their own tools.

## Scheduling

Each server has one scheduler. Scheduled tasks, calendar events, timers and
wake-ups are all entries in `schedules`, and each entry belongs to the machine
that will run it. Only that machine's server writes its entries and fires
them. A calendar event never fires. An entry that came due while its server
was off fires once, late, when the server is back; no occurrence fires twice.
The calendar page shows and adds tasks and events.

## Bots

There is one set of bots and one Forum. They live on one machine that the
person chooses from their Woven machines; that choice is a synced setting, and
only that machine's server runs the bots runtime. The setting is never written
as an ordinary setting. The first host is chosen through a request that a
server accepts only while its library names no host and holds no bots, and
after every machine it reaches has said the same. Every later change is a
transfer.

- Any UI talks to the bots and the Forum by connecting directly to the host's
  server. A server forwards a bots call to the host only when
  an agent on its own machine makes one through the Woven MCP.
- Bot chats and Forum posts are saved to the library like every other
  transcript, so they can be read when the host is away. A visual reply a
  bot shows in its own chat is saved there as a `visualReply` item in place of
  its call. A visual reply it publishes during a Forum turn is a post of its own in
  the room or thread it is answering in, in order with its words: the bots'
  database keeps a small reference with the post, and the library one
  `visualReply` item. Its HTML is stored once, in the content store, and a new
  host fetches by digest what it does not hold as the posts arrive.
- A bot's items are a session's kinds, saved through the same writer: messages
  (one from another session under its name), the model's thinking, tool calls
  with their input and output under the same cap, visual replies, failures and
  stops as notices, and one usage record per model turn.
- A bot hears the Forum and each thread it is in through a seat: a
  conversation of its own. Its posts, and its tool calls and thinking there,
  are saved in the room under its name, in time order; what it says in its
  seat without posting stays private. Each of a seat's model turns is recorded
  as usage under the room, also after the seat is gone (its thread deleted,
  the bot switched out). A Forum post carries the person's open notes to the
  bots as a chat message does, and Stop in a room stops the bots working there
  only; Pause stops every room.
- The bots folder on the host holds the bots' own database (bots,
  chats, memories, the Forum, schedules) and the model profiles. Nothing in it
  is tied to that machine. Each bot's files are a volume in that machine's
  container engine and can be written out and read back as an archive.
- What runs the bots (the engine, the Mac's virtual machine, sockets, logs) is
  kept outside the bots folder and is never moved.
- **Transfer** moves the bots to another machine, in this order: the old host
  stops the bots (running turns are interrupted); writes each bot's files out
  as archives and sends them with the bots folder in pieces, each checked by
  digest; the target reads them in, starts the bots and confirms its library
  holds every bot and chat; the target sets the host to itself; the old host
  removes its copy. Any failure before the switch leaves the bots on the old
  host: the target removes what it received and the old host starts them
  again. Each side records its step, so a restart ends in one of those two
  states. Sign-ins that are per machine are made again on the new one.
- Until the switch, the old host asks the target how it stands every few
  seconds. A target that hears nothing of the transfer for a minute gives it
  back. An old host that cannot reach the target starts the bots again only
  once the target has said it gave the transfer back, or 90 seconds after it
  last asked it anything else. Once the target has begun to switch, nothing
  gives the transfer back, and an old host that lost the reply waits for the
  target's answer.
- Each new host saves the chats under sessions of its own and carries over
  what the person set on the old ones: title, Trash, folder, pin and read
  state. Deleting a bot chat deletes it in the bots runtime, so it never comes
  back.

## Sign-ins and secrets

- Harness CLIs keep their own sign-ins on each machine.
- Subscription sign-ins (ChatGPT, Claude, Grok) are per machine and stay in the
  Keychain on a Mac or a private file on Linux. They are never in the library.
- The Claude subscription is the sign-in of the Claude Code installed on that
  machine, for Pi Durable and bots alike. The server keeps only a marker for
  it, which follows what Claude Code reports whenever sign-ins are listed,
  and shows the account Claude Code names. Signing in or reconnecting runs
  the Claude Code harness's own `claude auth login`, with its link and pasted
  code shown in the app, so it works on a machine without a browser; Remove
  runs `claude auth logout`.
  A Claude API key is the separate Anthropic provider, which never runs
  Claude Code.
- API keys for Pi Durable and bots, and the GitHub key, sync. Each is sealed
  separately for each machine with that machine's public key, so only that
  machine can open its copy.
- Agents never receive a key file. Each server offers the runtimes on its
  machine one socket that asks the server to use the key for them.

## Mac specifics

macOS grants permissions to the signed app. So the server, although it is
separate code in `server/` and a separate process, is started from the app's
own signed program. The person grants each permission once. See
[Mac access](MAC_ACCESS.md).

The app runs that program with `--server` as a per-user launchd agent, which
it loads with `launchctl bootstrap` and starts with `kickstart`. Quitting the
app leaves the server and its sessions running. macOS credits the agent's
background activity to the app that loaded it, so after a quit the Dock shows
Woven Matter as running in the background. Choosing **Stop Running in
Background** there, or turning the app off under Background App Activity in
System Settings, stops the server and whatever it is running. Opening the app
starts it again.

The app updates through Sparkle. Another Mac's UI can ask this Mac's server to
update it (`UpdateApp`): the server opens the app if it is closed and hands the
request to it, and the app downloads the newest release, installs it with no
window and relaunches. A Linux machine's server is updated by a Mac's server
over SSH, to the release that Mac carries.

## Development

`scripts/build_and_run.sh --instance NAME` builds the app and starts it with
its own bundle identifier, data folder and server. It never reads or changes
the data of an installed app. `--port PORT` puts that instance's server on the
tailnet on that port.

## Tests

The test suite is small on purpose. A test earns its place by covering
behaviour that would hurt if it broke: sync converging, a transcript being
saved once, an owner being the only writer, a session surviving a restart. One
test per behaviour, at the level where the behaviour lives. No tests for
removed features, for wording, or for how code is arranged. Tests use a
stand-in runtime and never call a provider. `scripts/test-changes.sh` runs
them.
