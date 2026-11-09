# Woven everywhere: devices, library and bots

This is the working contract for the change that makes every Woven Matter
surface reach every other one directly, gives every machine its own library
copy, and moves bots into this repository. Each workstream builds against the
interfaces here. When an interface has to change, change this document in the
same commit.

## Product rules

- **Everything reaches everything.** Once paired, every device reaches every
  other online device directly. No single Mac is ever required. Macs are the
  full user interface, the iPhone is a focused interface, and Linux machines
  are headless hosts.
- **One kind of machine.** Each Linux or macOS machine runs one Woven server.
  It hosts the workspace, a full library copy, Woven MCP and, when enabled,
  bots. A Linux machine may run bots without being a workspace; adding the
  workspace later reuses the same server. A Mac must have the Woven Matter
  desktop app installed by hand and be connected on the Mac connections page
  before it can host bots.
- **Full access by default** for every harness everywhere, including sessions
  agents start. Agent-started sessions use the destination workspace's own
  saved defaults and are never capped by the caller. The UI shows each
  harness's own mode names, with every full mode shown as "Full access".
- **Nothing waits on a prompt.** Macs grant Keychain and macOS privacy
  permissions once from Settings. Each Mac's permission status reaches every
  device. Password prompts in sessions fail at once with a clear message.
- **No consent prompts** for sending data to providers the user signed in to.

## Membership and device keys

- Every device has a long-lived Curve25519 signing identity: the Mac Keychain,
  the iPhone Keychain, and a 0600 file on Linux under the Woven data root.
  This generalizes today's paired-Mac identity (`PairedMacIdentity.swift`).
- The **member list** is a synced, signed record set. Each member entry names
  the device ID, kind (`mac`, `linux`, `ios`), display name, public key,
  endpoints, the adding device and its signature. Any Mac member may add a
  device, because adding needs the UI. Removal is a signed revocation that
  every device applies as soon as it syncs.
- **Authentication between members.** A device proves its key with the
  existing challenge/handshake pattern (`v1/peers/challenge`,
  `v1/peers/handshake`, `v1/peers/proof`), generalized to any member kind. The
  verifier accepts any key on the current member list. The resulting bearer is
  cached by the caller and stays valid until revocation. Nothing is issued only
  by a "managing" Mac, and nothing expires on a timer.
- The Linux Node server verifies member signatures itself; Ed25519 in Node is
  compatible with CryptoKit Curve25519 signing keys. It reads the member list
  from its local library copy.
- Remote host administration (status, logs, restart, update) is available to
  every Mac member. First install still runs over Tailscale SSH from the Mac
  that adds the machine.
- Bots are not members. Each bot has its own Woven MCP key (see Bots).

## Library on every surface

- Macs and Linux machines hold a full library database and run the same Swift
  library code: `WovenMatterDashboardStore` and its dependencies, built for
  Linux. Linux has no rendering; agents read and edit notes, calendar, history
  and artifacts through the database with the exact same code as the Mac
  (`NoteDocument`, `applyNoteEdits`, receipts, versions).
- On Linux this code runs as the `wovenmatter-library` executable, which the
  Node server supervises. It listens on a loopback port and a Unix socket. It
  serves:
  - the peer sync protocol (today's paired-Mac protocol, generalized to all
    members);
  - the mobile library API that the iPhone uses (today's
    `CompanionWorkspaceAPI` and `CompanionFederationAPI`), so a phone can sync
    with any Mac or Linux machine;
  - the library-backed Woven MCP tool groups (notes, history, calendar,
    library, artifacts) for the local Node server, replacing today's relay to
    one Mac's `/mcp/workspace`.
  The peer and mobile routes are published with Tailscale Serve on the host,
  under the same path layout a Mac uses (`/wovenmatter`).
- **Sync** is peer-to-peer among every online member, using the existing
  row-level replication (`PairedLibraryStore`: change log, version vectors,
  per-peer cursors, conflict copies). A local change is announced to online
  peers once and batched; a device that comes online catches up once. There is
  no constant polling: today's 5-second loop becomes change-driven, with a
  slow presence check.
- Linux session history is written into the machine's own library copy, which
  then syncs everywhere. That replaces the per-Mac publisher outbox.
- **iPhone sync set.** Full copies of notes, Quick Chats with their
  transcripts, calendar, and timers and reminders. The list of every session
  on every device, with title and status. Transcripts for very recent
  sessions, plus any session the user opens. Large files are fetched when
  opened.
- **Versions.** Sync requires matching schemas (`PairedLibraryStore` already
  rejects a mismatch). When peers disagree, every device shows which part
  needs updating and offers "Update everything". There is no compatibility
  layer.

### Library host (`wovenmatter-library`)

The `wovenmatter-library` executable (`app/Sources/WovenMatterLibraryDaemon`,
logic in `WovenMatterLibraryHost`) builds for Linux and macOS. Linux hosts run
the statically linked build described under "Linux build".

**Command line.** Every path is explicit or derived from `--data-root`; there
is no default production location.

```
wovenmatter-library --data-root DIR [--port N] [--socket PATH] [--token-file PATH]
                    [--harness-catalog PATH] [--migrate-only]
wovenmatter-library --version
```

- `--port N`: loopback TCP port (127.0.0.1 only). `0`, the default, picks a
  free port.
- `--socket PATH`: the local API's Unix socket, default `DIR/run/library.sock`.
- `--token-file PATH`: the local API bearer, default `DIR/run/library-api.token`.
- `--harness-catalog PATH`: the shared `harnesses/catalog.json`; by default the
  copy a host release ships three directories above the binary.
- `--migrate-only`: open and migrate the database, print
  `{"event":"migrated"}` and exit. Use it to verify an install or update.
- When both listeners are ready it prints one line to stdout and writes the
  same object to `DIR/run/library.json` (0600):
  `{"event":"ready","pid":N,"port":N,"socket":"…","version":"1"}`. SIGTERM or
  SIGINT stops it cleanly and removes that file. Exit codes: 0 clean, 1
  startup failure, 64 usage.

**Data layout.** The root and every directory it creates are 0700 and must be
owned by the running user.

| Path | Contents |
| --- | --- |
| `DIR/library/` | The `DashboardStore` support directory: `workspace.sqlite` (+ WAL), `dashboard-device-id` (this machine's device ID), library and attachment files |
| `DIR/secrets/` | 0600 files that replace Keychain items (`LinuxSecretStore`), one per generic-password item |
| `DIR/run/library.sock` | Local API socket, 0600; peers must also be this user (checked with `SO_PEERCRED`) |
| `DIR/run/library-api.token` | Local API bearer, 0600, 43–256 base64url characters. The Node server may create it before starting the host; otherwise the host creates it |
| `DIR/run/library.json` | Ready record (above) |

**Loopback routes** (published with Tailscale Serve under `/wovenmatter`,
which the host strips):

- `GET /v1/health` → `{"status":"ok","service":"wovenmatter-library","version":"1","deviceID":"…","uptimeSeconds":N}`,
  or 503 when the database is unavailable. Unauthenticated; it reveals only
  the device ID.
- Peer sync and mobile library routes are mounted with
  `LibraryHost.mount(prefix:_:)`, for example `/v1/peers/` and
  `/v1/federation/`. Nothing is mounted yet: the member authentication those
  routes need belongs to the membership workstream, and unmounted paths return
  404. The handlers already in the package (`PairedLibraryStore` replication,
  `CompanionWorkspaceAPI`) are the ones to mount.

**Local API** (Unix socket, for this machine's Node server). Every request
carries `Authorization: Bearer <token file contents>`. Requests are HTTP/1.1,
one per connection, with `Host`; POST bodies are `application/json`.

- `GET /v1/health`: as above.
- `POST /v1/callers` registers a conversation as a local session so tool
  effects (notes, receipts, versions, mutation history) are attributed to it:
  `{"conversationID":"<uuid>","title":"…","runtimeKind":"default_agent","workingDirectory":"/home/…","enabledGroups":["notes","calendar"]}`
  (only `conversationID` is required) →
  `{"conversationID":"<uuid>","enabledGroups":"calendar,notes"}`.
- `POST /v1/mcp`: stateless MCP JSON-RPC (`initialize`, `ping`, `tools/list`,
  `tools/call`), the same messages the Node server sends a Mac's
  `/mcp/workspace` today. Headers: `X-Woven-Conversation-ID` (the caller, a
  UUID; registered on first use), `X-Woven-Enabled-Groups` (comma-separated,
  the caller's current selection; the Node server is the authority for its own
  sessions' tool policy), optional `X-Woven-Context-ID` and
  `MCP-Protocol-Version`. Served groups: `notes` (including spreadsheet and
  HTML note artifacts), `history`, `calendar` and `library`, plus
  `woven_context`. Other tools are not listed and are refused; `woven_html_render`
  needs the caller's active run and stays in the Node server until Linux
  session history is written into this library. A `tools/call` result's
  `structuredContent` is the `WovenMatterToolResponse`
  (`{success,result,error,code,requestID}`); errors use the usual codes
  (`tool_disabled`, `revision_required`, `revision_conflict`, `not_found`, …).

Tool execution is `WorkspaceToolExecutor` in `WovenMatterDashboardStore`, the
same code the Mac app's `WorkspaceAgentToolsModel` now delegates to. Note edits
go to `WorkspaceDatabase.readNoteForEditing` / `applyNoteEdits`, so a Linux
edit stores the same `NoteDocument` bytes a Mac stores for the same edit.

**Linux build.** `scripts/build-linux-library.sh` builds
`remote/host/library/linux-{x86_64,aarch64}/wovenmatter-library` (static musl,
any distribution) in the pinned Swift image with the pinned Static Linux SDK
and SQLite amalgamation (`remote/library/build-version.json`). Anything under
`remote/host/` is a host bundle input, so a Mac app built with those binaries
present ships them to every host install and update at
`<release>/host/library/linux-<arch>/wovenmatter-library`. Starting and
supervising it is the Node server's job. `scripts/test-linux-library.sh` builds
and tests the portable targets on Linux; the manual validation workflow
(`linux` scope) runs both and keeps the binaries as an artifact.

## Sessions across devices

- Every Mac's agents can create and manage sessions on every Mac and Linux
  workspace through Woven MCP. The iPhone is never a target: it runs only its
  own Quick Chats.
- Workspaces are named explicitly by ID and name. `local` is no longer
  accepted as a destination.
- The iPhone connects directly to every Mac and Linux workspace with its own
  member key. It has no home Mac.

## iPhone Quick Chat

- Pi Durable runs on the phone in full access.
- Its tools: notes, web search and read (with the provider connected in
  Connections: Exa, Brave or Firecrawl), asking the user a question, timers
  and reminders, and calendar.
- There is no shell, no file tools, no embedded Python and no background
  execution. A timer fires as a local notification, and any agent work it
  needs runs when the user opens it. Recurring agent work becomes a scheduled
  task on a Mac or Linux workspace.
- Other devices see Quick Chats as read-only synced history.

## Bots

### Runtime

- The bots runtime is a Node package in `bots/`, ported from Pi Bot's server
  (pinned `wovenmatter/pi-bot` at `6571bb4`) without its web UI. It runs Node
  26 directly; TypeScript runs through Node's built-in type stripping, so
  there is no build step. Its npm lockfile follows `docs/DEPENDENCIES.md`.
- The Woven server on the bot machine supervises it as a child process. It
  listens only on a loopback port and serves Pi Bot protocol 1, with
  additions, over WebSocket at `/ws`. Woven apps reach a remote machine's bots
  through that machine's Woven server at `/v1/bots/ws`, authenticated as a
  member, which then proxies to the loopback socket.
- Each bot's agent loop runs in the runtime on the host, and its tools run
  inside its container through the in-container helper (Pi Bot's
  `docker/agent.mjs`, mounted read-only from the host). Provider keys and
  sign-ins never enter a container. The runtime gets provider credentials the
  same way the machine's default agent does
  (`docs/architecture/DEFAULT_AGENT_CREDENTIALS.md`), and bots use the
  provider connections in Woven settings. Pi Bot's own credential store and
  configuration editor are dropped.
- Woven MCP: each bot gets its own key from the machine's Woven server. The
  principal is `woven:bot:<machine-device-id>:<bot-id>`, with attribution,
  per-bot revoke and pause-all. The existing `WorkspaceToolSettings.botMCP`
  toggles decide which tool groups bots get. Session management reaches only
  Woven workspaces, under those workspaces' own permissions. Bot schedules
  are Woven MCP timers delivered back to the bot.
- Bot conversations are written into the machine's library copy as
  conversations, so they sync everywhere.

### Engine

- The runtime talks to a Docker Engine API over a Unix socket; no `docker`
  CLI is required. The engine is never the user's own Docker.
- **Linux:** Woven installs its own `dockerd` instance (unit
  `wovenmatter-docker.service`) with its own socket
  (`/run/wovenmatter/docker.sock`), data root, exec root and bridge. Installing
  it needs sudo once.
- **Mac:** a Woven-managed Linux VM (Virtualization framework) runs Docker
  Engine. Its socket is forwarded over vsock to a Unix socket under the app's
  support directory. The VM stays running so a wake only starts a container,
  and it returns unused memory to the Mac through the balloon and free page
  reporting.
- **Image:** Ubuntu 26.04 LTS with Chromium and Playwright, git, Node, Python,
  build tools and tini. A bot runs as a user with passwordless sudo, which
  gives it full root inside its container.
- **Network:** the container has internet access. Outbound traffic to the
  tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48), private and link-local ranges
  and the host is blocked by the engine host: iptables on the Woven bridge on
  Linux, and inside the guest on a Mac. No container port is published except
  through previews. The Docker socket is never mounted into a bot.

### Resources

- **RAM pool:** default 8 GB per machine. It may be set anywhere from 1 GB to
  the device's total RAM, or to no cap. Show the device's total RAM, and warn
  when the pool leaves the device less than 4 GB.
- **Per-bot RAM:** default 4 GB. It may be set anywhere up to the pool, or to
  no cap.
- **Disk:** one total cap for all bots, default 50 GB. It may be set up to the
  disk's total size, or to no cap. Show the disk's total size and free space,
  and warn when the cap exceeds free space.
- **Enforcement on Linux:** a cgroup slice (`MemoryMax`) for the engine and a
  sparse disk image for its data root. On a Mac: the VM's memory and its
  sparse disk. Per-bot RAM is the container memory limit. Raising the disk
  cap is immediate; lowering it stops at what is already used.

### Idle and wake

- A bot stops fully after 15 minutes idle. The period is fixed.
- A bot is idle when it has no turn running, no command running, no timer due
  soon, no one viewing its chat, and no preview traffic during the period.
- On wake, the agent loop is already running in the runtime, so it can reply
  immediately. The container starts on the first tool call. After that, the
  restart list and the browser come back in the background.
- **Restart list:** the bot registers long-running services with a Woven
  tool, `keep_running` (name, command, directory). The helper supervises them
  inside the container and starts them on every container start.
- **Browser:** Woven owns a persistent Chromium profile in the bot's storage.
  Tabs, cookies and sign-ins survive a stop, and open tabs reopen on wake.
  Bots get a browser tool built on Playwright inside their container.

### Previews

- The bot asks to share a container port. Woven publishes it to a loopback
  port on the host, runs a small activity-counting proxy in front of it, and
  publishes that proxy with Tailscale Serve on the host's tailnet name using
  its own HTTPS port. The bot gets back the URL to give the user.
- Previews are inbound only and never use Funnel.

### Updates

- The UI offers "Update everything" across all devices. Each part can also be
  updated on its own: this Mac's app, a Linux host, or bots from the Bots
  page.
- Clicking Update stops running work immediately. Woven snapshots each bot
  (container filesystem and storage), updates it in place, runs a health
  check, and rolls back to the snapshot on failure. Only the snapshot from the
  last update is kept. Afterwards it restarts from the restart list and tells
  the bot that its last turn was interrupted.
- **Rebuild** recreates a bot from a clean image while keeping its storage.

### Discovery and UI

- **Discover devices**, on the Bots page and on Mac connections, lists every
  online Linux and macOS tailnet peer and its state:
  - a Linux machine with no server: install bots (sudo once);
  - a Mac without the app: "Install Woven Matter on this Mac first", with the
    steps (download, open, connect on Mac connections, finish the setup card);
  - ready.
- The native SwiftUI bot UI and settings come from PR #226, adapted to this
  runtime and to Woven's provider connections.

## Out of scope

- TestFlight preparation (its own PR).
- The `wovenmatter/pi-bot` repository and its workstation preview, which stay
  untouched.
- Outside-agent MCP on Linux or the iPhone.
