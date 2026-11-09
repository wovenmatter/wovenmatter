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
  inside its container through the in-container helper (`bots/helper/`: Pi
  Bot's env agent plus a supervisor, browser and preview forwarder). The
  helper is mounted read-only at `/opt/woven-bot` from a content-versioned
  volume (`woven-bots-helper-<hash>`) that the runtime fills from its own
  install through the Engine API, so a Mac VM needs no file sharing and
  runtime updates need no image change. A bot picks up a new helper on
  Update or Rebuild. Provider keys and
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

#### Runtime config

`node bots/src/cli.ts serve --config <file>` reads one JSON file that the
Woven server writes (mode 0600). Unknown keys are refused.

```json
{
  "dataDir": "/abs/path",
  "listen": { "host": "127.0.0.1", "port": 4317 },
  "runtimeToken": "≥32 random characters",
  "engine": { "socket": "/run/wovenmatter/docker.sock", "kind": "linux-dockerd" },
  "image": { "tag": "wovenmatter-bots" },
  "limits": { "botMemoryBytes": 4294967296 },
  "host": { "url": "http://127.0.0.1:<port>/", "token": "bearer for the host API" },
  "machine": { "deviceID": "<member device id>", "name": "Studio" }
}
```

- `listen.host` must be loopback (`127.0.0.1`, `::1`, `localhost`). Every HTTP
  request and WebSocket upgrade needs `Authorization: Bearer <runtimeToken>`;
  `Host` and `Origin`, when present, must be loopback.
- `engine.kind` is `linux-dockerd` or `mac-vm`. `image.tag` without a tag
  (`wovenmatter-bots`) gets the content hash of `bots/image` as its tag and is
  built through the Engine API when missing; a tagged name is used as is.
- `limits.botMemoryBytes` is each container's memory limit (`Memory` and
  `MemorySwap`); `null` means no cap.
- `host.url` must be loopback `http`. The runtime keeps its own state under
  `dataDir`: `bots.sqlite` (bots, threads, Pi Durable tables, memory, limits,
  cached Woven tool lists, previews), `settings.json` (model profiles, title
  model, memory extraction, compaction, bot-to-bot limits; no secrets) and
  `claude-agent/` (the Claude Agent SDK's private scratch directory).
- Exit on SIGTERM/SIGINT is graceful. Containers keep running across a runtime
  restart and are picked up by the next start.

#### Runtime host API

Served by the machine's Woven server at `host.url`, `Authorization: Bearer
<host.token>`, JSON bodies. Non-2xx means failure; the runtime never shows the
reply body. Replies are at most 1 MiB.

| Request | Body | Reply |
| --- | --- | --- |
| `POST /v1/bots-host/mcp-keys` | `{botID, botName}` | `{endpoint, token}`: the bot's Woven MCP key, principal `woven:bot:<machine.deviceID>:<botID>`. The same bot may ask again (after a restart, or a 401 from MCP); the host returns its current key or rotates it. |
| `DELETE /v1/bots-host/mcp-keys/{botID}` | none | 2xx. Sent when the user purges a bot. |
| `POST /v1/bots-host/previews` | `{botID, port, containerPort}` | `{url}`. `port` is the runtime's loopback activity proxy; the host publishes `http://127.0.0.1:<port>` with Tailscale Serve (its own HTTPS port, inbound only, never Funnel). Idempotent for the same `(botID, port)`; sent again after a runtime restart. |
| `DELETE /v1/bots-host/previews/{botID}/{port}` | none | 2xx. |
| `POST /v1/bots-host/inference-credentials` | `{provider}` | `{credential}`, where `credential` is `null` (not connected), `{type: "api_key", key}`, `{type: "oauth", access, expires, accountId?}` (access only; `expires` epoch ms; the host renews, the runtime asks again a minute before expiry), or `{type: "native", configDir, secureStorageDir?}` (Claude subscription: the machine's native Claude runtime directories, which the default agent uses, passed to the Claude Agent SDK as `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`; no token material). `provider` is a Woven connection id: `openai-codex`, `openai`, `openrouter`, `opencode-go`, `xai`, `xai-api`, `claude-subscription`, `anthropic`, `exa`, `brave`, `firecrawl`, or `web-search`, which also returns `searchProvider` (`exa`, `brave` or `firecrawl`, the selected web search provider) with that provider's key. |
| `POST /v1/bots-host/conversations/{botID}/entries` | `{bot: {id, name}, conversations: [{conversationId, kind: "main"\|"thread", parentConversationId?, forkedAt?, title?, pinned?, createdAt?}], entries: [{id, conversationId, role: "user"\|"assistant", text, error?, stopped?, createdAt}]}` | 2xx. The host writes them into its library copy, upserting entries by `(botID, id)` and conversations by `(botID, conversationId)`. Entry ids are unique per bot and never reused. `conversations` always lists the bot's main channel and every thread; a batch may have no entries when only metadata (a title, a pin, a rename) changed. Batches hold at most 200 entries, in id order; the runtime resends after a failure. |

The runtime caches credentials in memory only (keys 60 s, "not connected"
15 s) and never stores them. A credential change in Woven settings takes
effect within that window.

#### Runtime protocol

Pi Bot protocol 1 over WebSocket at `/ws`: JSON text frames, each request
`{id, type, …}` answered by `{type: "result", id, data}` or `{type: "error",
id?, message}`. `hello` carries `version`, `protocol: 1`, `installationId`,
`capabilities` and `environment` (`none`, `linux-dockerd` or `mac-vm`).
Capabilities: `groups`, `woven.mcp`, `message.context`, plus the additions
`bots.environment`, `runtime.update` and `previews`. `GET /health` returns the
same identity with `ok: true`.

Kept from Pi Bot, with their wire shapes: `bots.list`, `bots.create`,
`bots.delete`, `bots.listDeleted`, `bots.restore`, `bots.purge`,
`bots.rename`, `bots.setManager`, `bots.setTeam`, `bots.replaceManager`,
`bots.setOrchestrator`, `bots.setGroup`, `bots.setProfile`, `groups.list`,
`groups.create`, `groups.rename`, `groups.delete`, `groups.reorder`,
`onboarding.status`, `onboarding.setMainModel`, `profiles.list`,
`profiles.save`, `profiles.delete`, `profiles.setDefault`, `memory.list`,
`memory.add`, `memory.update`, `memory.delete`, `account.notes`,
`account.setNotes`, `conversation.open`, `conversation.close`,
`conversation.abort`, `message.send` (with `context` and `deliveryId`),
`thread.fork`, `thread.setPinned`, `threads.list`, `models.catalog`,
`models.setRoles` (now live: `restartRequired` is always `false`).

Changed:

- `woven.status` → `{state, toolCount, error?, bots: {<botId>: {state,
  toolCount}}}`, aggregated over the bots' own keys. `woven.connect` and
  `woven.disconnect` are gone: keys come from the host API.
- `settings.accounts` is read-only: `{accounts: [{id, label, group, method,
  configured}], search: {provider, providers: [...]}}`, with Woven connection
  ids.

Dropped: `credentials.set`, `credentials.remove`, `login.start`,
`login.respond`, `login.cancel`, `config.get`, `config.validate`,
`config.save`, `config.update`, `github.get`, `github.setSshKey`,
`github.generateSshKey`, `github.removeSshKey`, `github.setIdentity`,
`server.restart`, and the `login` push. Sign-ins and keys are Woven
connections; bots set up their own git and SSH inside their containers.

Added requests:

| Request | Reply |
| --- | --- |
| `bots.environment {botId}` | `{environment: {botId, state: "missing"\|"running"\|"stopped"\|"unavailable", busy?, lastActivity?, services?, previews: [{port, url}]}}`. `busy` says why a running bot is not idle now; `services` is the restart list with each service's state. |
| `bots.stop {botId}` | `{stopped: true}`. The next tool call starts the container again. |
| `bots.rebuild {botId}` | `{rebuilt: true}`. A clean container from the current image and helper; storage, restart list and browser profile stay. |
| `previews.list {botId?}` | `{previews: [{botId, port, url}]}` for one bot or all (`port` is the container port). |
| `previews.stop {botId, port}` | `{stopped: boolean}`. |
| `runtime.update {botIds?}` | `{started: true}` at once; the update runs for all bots (or the listed ones), one at a time. |
| `runtime.status` | `{version, environment, bots}`. |

Added pushes:

- `{type: "runtime.update", botId?, phase, error?}` with `phase` `stopping`,
  `updating`, then `updated`, `rolledBack` or `skipped` per bot, and one final
  `done` (with `error` if the run itself failed).
- `{type: "bots.environment.changed", botId, state}` after stop, rebuild and
  update.

Bot tools added by the runtime: `keep_running {name, command, cwd?}`,
`keep_running_list`, `keep_running_remove {name}`, `keep_running_logs {name,
lines?}`, `browser {action: navigate|read|screenshot|click|type|tabs|new_tab|
close_tab, url?, tab?, selector?, text?, label?, value?, submit?, fullPage?,
maxChars?}`, `share_preview {port}`, `stop_preview {port}`, `list_previews`.
Pi Bot's Admin Bot config tools (`read_config`, `update_config`,
`restart_server`) are gone; `settings_status` reports connections and models.

#### Container layout

- Container `woven-bot-<botId>`, storage volume `woven-bot-<botId>-workspace`
  at `/workspace`, snapshot `woven-bot-<botId>-snapshot` (volume) and
  `woven-bot-snapshot:<botId>` (image). Labels `woven.bot=<botId>`,
  `woven.bots.machine=<deviceID>` and `woven.bots.helper=<helper volume>`; the
  runtime only ever touches containers with its own machine label.
- User `bot` (passwordless sudo), `tini` as PID 1, the supervisor as its
  child, restart policy `no` (the runtime decides when bots run), 512 MiB
  `/dev/shm` for Chromium, no published ports, no host mounts, no Docker
  socket.
- Bot state the runtime owns lives in the storage volume under
  `/workspace/.woven/`: `services.json` (restart list), `logs/<name>.log`,
  `browser/profile/` (Chromium profile) and `browser/tabs.json` (open tabs,
  saved on every change and on stop).

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
  tailnet (CGNAT 100.64/10, fd7a:115c:a1e0::/48), private and link-local ranges
  and the host is blocked by the engine host: iptables on the Woven bridge on
  Linux, and inside the guest on a Mac. No container port is published, not
  even for previews (see Previews). The Docker socket is never mounted into a
  bot.

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
  - "No command running": no tool call in flight and no process in the
    container besides PID 1, the supervisor and everything under it (the
    restart list and the browser, which come back on wake), env agents and
    preview forwarders. Children of an env agent and orphaned background jobs
    count. A process check that fails counts as busy.
  - "No timer due soon": none of the bot's Woven timers (`woven_timers_list`
    through its own MCP key) fires within 5 minutes. When that can't be told
    (no timer tool, Woven unreachable) it doesn't block the stop: a due timer
    reaches the bot as `message.send`, which wakes it anyway.
  - Activity that restarts the period: a tool call, `conversation.open`,
    `message.send`, and each preview connection or byte.
  - Stopping sends SIGTERM with 20 seconds' grace: the supervisor saves open
    tabs, closes the browser profile and stops the restart list.
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

- The bot asks to share a container port (`share_preview`). The runtime runs
  a small activity-counting TCP proxy on a loopback port of the engine's host
  machine and asks the host API to publish that proxy with Tailscale Serve on
  the host's tailnet name using its own HTTPS port. The bot gets back the URL
  to give the user. HTTP and WebSockets pass through unchanged.
- The proxy reaches the container port over the Engine API: each connection
  is a Docker exec of the helper's forwarder (`/opt/woven-bot/forward.mjs
  <port>`) with the bytes on its hijacked stdio. Docker cannot add a port
  binding to an existing container without recreating it, and this works
  the same through a Mac VM's forwarded socket, so no container port is ever
  published and the Mac VM needs no port forwarding. A preview connection
  starts a stopped container. The transport is a replaceable hook
  (`PreviewTransport` in `bots/src/environment/previews.ts`, passed as
  `previewTransport` to `startRuntime`) should a host integration want a
  direct path.
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
- In the runtime (`runtime.update`): running turns are aborted first, then for
  each bot, one at a time: stop the container, commit it to
  `woven-bot-snapshot:<botId>` and copy its storage volume into
  `woven-bot-<botId>-snapshot` (replacing the previous snapshot), recreate the
  container from that commit with the current helper and limits, start it,
  run `apt-get update && apt-get -y upgrade` as root, and health-check it
  (`node --version`, `sudo -n true`, writable `/workspace`, the supervisor
  answering). On any failure the container is recreated from the snapshot
  with its previous helper and the storage copied back. The supervisor starts
  the restart list and the browser on every start. Each conversation whose
  turn was aborted then gets a message saying the environment was updated and
  the last turn stopped part-way, so the bot can continue.

### Discovery and UI

- **Discover devices**, on the Bots page and on Mac connections, lists every
  online Linux and macOS tailnet peer and its state:
  - a Linux machine with no server: install bots (sudo once);
  - a Mac without the app: "Install Woven Matter on this Mac first", with the
    steps (download, open, connect on Mac connections, finish the setup card);
  - ready.
- The native SwiftUI bot UI and settings come from PR #226, adapted to this
  runtime and to Woven's provider connections.

### Woven servers and apps

The runtime's config, host API and protocol are above (Runtime). These are the
other interfaces between Woven servers and apps.

**Supervision on a Mac.** The background server writes the runtime config to
`<support>/Bots/runtime.json` with `dataDir` `<support>/Bots/data`,
`engine.kind` `mac-vm`, `image.tag` `wovenmatter-bots` and `limits.botMemoryBytes`
from the machine's per-bot RAM, and runs the runtime with the Node the app ships
(`<Resources>/default-agent/bin/node <Resources>/bots/src/cli.ts`). It serves the host
API on its own loopback port. Previews are published from the runtime's loopback
proxy port with Tailscale Serve, path `/`, on their own HTTPS port. Inference
credentials are the coordinator snapshot Pi Durable gets; `claude-subscription`
returns the default agent's native directories (`~/.wovenmatter/default-agent/claude-runtime`
and `claude-keychain`) once they exist. `DELETE /v1/bots-host/mcp-keys/{botID}` also
marks that bot's library conversations deleted.

**Bot conversations in the library** are two paired-library tables, not chats:
`bot_conversations(id = "<machine>:<bot>:<conversationId>", machine_id, bot_id,
bot_name, conversation_id, kind, parent_conversation_id, forked_at, title, pinned,
created_at, updated_at, deleted_at)` and `bot_conversation_entries(id =
"<machine>:<bot>:<entryId>", conversation, entry_id, role, text, error, stopped,
created_at)`. A resent row that has not changed is not rewritten, so it adds no sync
traffic. Regular chat lists never show them. The Swift entry point is
`WorkspaceDatabase.recordBotConversation(machineID:_:)`, which a Linux library daemon
can call with the same batch.

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
Docker socket once the VM answers, `apply(resources:)`, `diskUsedByBots()`, `status()` and
`stop()`. Previews need no VM port forward: the runtime carries them over Engine API exec
streams. `BotEngineHostFactory.make` returns the implementation.

## Out of scope

- TestFlight preparation (its own PR).
- The `wovenmatter/pi-bot` repository and its workstation preview, which stay
  untouched.
- Outside-agent MCP on Linux or the iPhone.
