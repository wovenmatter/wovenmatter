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

### Interfaces between the runtime, the Woven servers and the apps

These are what the Mac side implements and calls. The runtime and Linux workstreams
build to the same shapes.

**Runtime config.** The supervising server writes it with mode 0600 and starts
`node bots/src/cli.ts serve --config <file>` with the Node the app already ships.
On a Mac the file is `<support>/Bots/runtime.json` and `dataDir` is
`<support>/Bots/data`.

```json
{ "dataDir": "…", "listen": { "host": "127.0.0.1", "port": 47311 }, "runtimeToken": "…",
  "engine": { "socket": "…/docker.sock", "kind": "mac-vm" }, "image": { "tag": "wovenmatter/bots:<version>" },
  "limits": { "botMemoryBytes": 4294967296 }, "host": { "url": "http://127.0.0.1:<port>", "token": "…" },
  "machine": { "deviceID": "<woven device id>", "name": "…" } }
```

`limits.botMemoryBytes` is `null` for no cap. `image.tag` is `wovenmatter.image` from
`bots/package.json`, or `wovenmatter/bots:<package version>`. The server restarts the
runtime with backoff when it exits and considers it running once `GET /health`
answers 200 on the listen port.

**Runtime host API.** Loopback HTTP on the supervising server, bearer `host.token`.
Errors are `{ "code", "message" }` with a 4xx status.

| Route | Body | Reply |
| --- | --- | --- |
| `POST /v1/bots-host/mcp-keys` | `{ botID, botName }` | `{ endpoint, token }`; 403 `revoked` when the user revoked that bot |
| `DELETE /v1/bots-host/mcp-keys/{botID}` | | `{ ok }` — the bot was deleted |
| `POST /v1/bots-host/previews` | `{ botID, port }` | `{ url }`, the tailnet HTTPS URL |
| `GET /v1/bots-host/previews` | | `{ previews: [{ botID, port, url, lastActivityAt }] }`, for the idle check |
| `DELETE /v1/bots-host/previews/{botID}/{port}` | | `{ ok }` |
| `POST /v1/bots-host/inference-credentials` | `{ provider }` | `{ provider, credential: { type, key?, access?, expires?, accountId? } }`; 404 when not connected |
| `POST /v1/bots-host/conversations/{botID}/entries` | `{ botName, conversationId, mainConversationId?, title?, entries: [{ id, conversationId?, role, text, error?, createdAt? }] }` | `{ recorded }` |
| `DELETE /v1/bots-host/conversations/{botID}` | | `{ ok }` — marks the bot's conversations deleted |

Provider IDs are Woven's `ProviderConnectionID`s (`openai`, `openai-codex`,
`anthropic`, `openrouter`, `xai`, `xai-api`, …). Credentials are the borrowed,
access-only snapshot the machine's own Pi Durable receives; refresh tokens never
leave the machine. Bot IDs and device IDs are identifier tokens
(`[A-Za-z0-9._-]{1,128}`; UUIDs today). Entry IDs are unique per bot, and reporting an
entry again updates it in place, so the runtime may report a reply partially and again
when it ends. `role` is `user`, `assistant`, `system` or `tool`.

**Bot conversations in the library** are two paired-library tables, not chats:
`bot_conversations(id = "<machine>:<bot>:<conversationId>", machine_id, bot_id, bot_name,
conversation_id, main_conversation_id, title, created_at, updated_at, deleted_at)` and
`bot_conversation_entries(id = "<machine>:<bot>:<entryId>", conversation, entry_id, role,
text, error, created_at)`. Regular chat lists never show them.

**Protocol additions** the apps use, beyond Pi Bot protocol 1:

- `hello` carries `machineId`.
- `runtime.status` → `{ version, protocol, image, state, error? }`, `state` being
  `ready`, `updating`, `rebuilding` or `failed`.
- `runtime.update` → the same status when done. It stops running work, snapshots
  each bot, updates it, health-checks it and rolls back on failure; it is a no-op for
  bots already on the current image. Pushes `runtime.progress`
  `{ botId?, phase, message? }` (`stopping`, `snapshot`, `updating`, `checking`,
  `restarting`, `rolledBack`, `done`, `failed`).
- `bots.rebuild { botId }` recreates one bot from a clean image, keeping its storage.
- `onboarding.status.signedIn` means the runtime can use at least one Woven provider
  connection. There is no sign-in, account, search, GitHub or config protocol.
- Woven notifications are `message.send` to the main channel with `deliveryId`.

**Woven server routes for bots.** Every Woven server that hosts bots answers these,
under `/wovenmatter` when reached through Tailscale Serve:

| Route | Reply |
| --- | --- |
| `GET /v1/bots/status` | `{ machine: { deviceID, name, kind }, enabled, state, message?, versions: { app, runtime, protocol }, resources, capacity: { memoryBytes, diskTotalBytes, diskFreeBytes, diskUsedByBotsBytes? }, paused }` |
| `POST /v1/bots/resources` `{ resources: { poolBytes, perBotBytes, diskBytes } }` | the status after applying; `null` is no cap |
| `GET /v1/bots/ws` (WebSocket upgrade) | proxied to the runtime's `/ws` with the runtime's own bearer |

Until member auth lands, a Mac's server accepts any current execution grant
(`CompanionExecutionAuthentication`) for these routes, and a Linux server accepts its
workspace API token through the SSH tunnel. On the Mac, `ApplicationModel.botsAccess`
is the one function member auth replaces.

**Linux bots-only install.** `remote-host.sh install-bots <workspace-id> <port>
<access-mode> <fingerprint>` takes the same stdin (token line, then bundle) as
`install` and installs the Woven server with bots and its engine, asking for sudo once.

**Mac engine.** The bots host codes against `BotEngineHost`
(`app/App/Services/BotEngineHost.swift`): `ensureRunning(resources:)` returns the
Docker socket once the VM answers, `apply(resources:)`, `diskUsedByBots()`,
`forwardPort(botID:containerPort:)` to a loopback port, `removeForward`, `status()` and
`stop()`. `BotEngineHostFactory.make` returns the implementation.

## Out of scope

- TestFlight preparation (its own PR).
- The `wovenmatter/pi-bot` repository and its workstation preview, which stay
  untouched.
- Outside-agent MCP on Linux or the iPhone.
