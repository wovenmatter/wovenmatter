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

#### Linux engine and host wiring

- **Install.** `scripts/remote-host.sh` runs `remote/host/bots-engine.py` with
  the account's existing `sudo -n` once (`install` with the `bots` role, or
  `bots-enable`). It copies itself to `/usr/local/lib/wovenmatter-bots/bots-engine`
  (root-owned) and installs Docker's official static binaries, pinned with
  SHA-256 in `remote/host/runtime-versions.json`. No distribution package and
  no sudoers rule is added. Everything is named from one instance
  (`wovenmatter`; isolated tests set `WOVENMATTER_BOTS_INSTANCE`).
- **Units.** `wovenmatter-docker.service` (`dockerd --config-file
  /etc/wovenmatter-bots/daemon.json`, socket `/run/wovenmatter/docker.sock`,
  root `0660`, group = the account's primary group, which must have no other
  members), `wovenmatter-containerd.service` (its own containerd at
  `/run/wovenmatter/containerd/containerd.sock`; dockerd would otherwise join
  a system containerd and share the user's Docker `moby` namespace),
  `wovenmatter-bots-firewall.service`, `wovenmatter-bots-apply.path`/`.service`,
  and `wovenmatter-bots.slice` (`MemoryMax` = RAM pool, `infinity` for no cap).
  The engine and every container (`cgroup-parent`) run in the slice. Data root
  `/var/lib/wovenmatter-bots/docker`: a sparse ext4 image (`disk.img`) mounted
  by `var-lib-wovenmatter\x2dbots-docker.mount` when there is a disk cap, a
  plain directory when there is none.
- **Network.** Bridge `br-wovenbots` on a free private /16 (first of
  `10.237–251.0.0/16`). dockerd runs with `iptables`/`ip6tables`/`ip-forward`
  off and never touches the user's chains. The Woven nftables table `inet
  wovenmatter_bots`, replaced atomically on every engine start and after
  `nftables.service` reloads, drops all IPv6, all traffic from the bridge to
  the host itself, new connections into the bridge, and forwarded traffic to
  0/8, 10/8, 100.64/10 (tailnet and MagicDNS), 127/8, 169.254/16, 172.16/12,
  192.168/16 and the other special-use ranges; it masquerades the rest. A
  Woven iptables chain (`WOVENMATTER-BOTS`, jumped first from `FORWARD`) only
  accepts what that table allowed, for hosts whose `FORWARD` policy is DROP.
  Containers use public resolvers (1.1.1.1, 8.8.8.8). Bots use only the
  default bridge: the runtime creates no networks, and the engine sets no
  `default-address-pools` (with them, dockerd deletes the host's `docker0` on
  every restart).
- **Settings.** The server, which has no sudo, writes
  `{revision, poolBytes, diskBytes}` (bytes or `null` for no cap) to
  `/var/lib/wovenmatter-bots/requests/settings.json`; the path unit applies it
  as root and records `appliedRevision` in `/var/lib/wovenmatter-bots/state/state.json`.
  Pool changes and disk growth are immediate; shrinking stops the engine and
  stops at the space in use; switching between a cap and no cap migrates the
  data. `remote-host.sh bots-configure ID POOL DISK` uses the same request.
- **Uninstall.** `bots-disable` (workspace kept) or `uninstall` removes the
  units, slice, mount, image, data, bridge, nftables table and iptables chain,
  and restores `ip_forward` if Woven turned it on.

#### One server, roles

- `remote-host.sh install|update ID PORT MODE FINGERPRINT [ROLES]` takes
  `workspace`, `bots` or `workspace,bots` (default: the recorded roles, or
  `workspace`). Roles only grow on update; a bots-only server skips the host
  Chromium. The installation record gains `roles`; the service environment
  gains `WOVENMATTER_WORKSPACE_ENABLED`, `WOVENMATTER_BOTS_ENABLED`,
  `WOVENMATTER_BOTS_INSTANCE`, `WOVENMATTER_BOTS_DATA` (`<data root>/bots`)
  and `WOVENMATTER_DATA_ROOT`. With the workspace off the server answers
  workspace routes (execution commands, schedules, projects, harnesses,
  browser, databases) with `409 workspace_disabled` and starts no scheduler.
- `remote-host.sh inspect [MODE] [ROLES]` adds `bots`: `state` (`no_server`,
  `server_without_bots`, `bots_ready`), `engine`, `memoryTotalBytes`,
  `diskTotalBytes`, `diskFreeBytes` (the filesystem holding
  `/var/lib/wovenmatter-bots`), `defaultPoolBytes`, `defaultDiskBytes` and
  `blockingIssues`. `status` adds `roles` and `botsState`.
- Host releases ship `bots/package.json`, `bots/package-lock.json`,
  `bots/src/**`, `bots/helper/**` and `bots/image/**` when the checkout or app
  has them, and run `npm ci --omit=dev --ignore-scripts` in `bots/` on the
  host. Nothing else under `bots/` ships.

#### Server side

- The server supervises `node bots/src/cli.ts serve --config
  <state>/bots/runtime.json` (0600), regenerating `runtimeToken`, the
  loopback port and the host bearer on every start, and restarting a crash
  with backoff up to 30 s. It starts the runtime once the engine is
  installed. `image.tag` is `wovenmatter-bots`; `machine.deviceID` comes from
  `WOVENMATTER_DEVICE_ID` or `<data root>/identity/device-id` (0600, created
  once), which the membership identity replaces.
- It implements the runtime host API under `/v1/bots-host/` with that bearer.
  Previews publish `http://127.0.0.1:<port>` (the runtime's proxy) with
  `tailscale serve --bg --https=<17000–17999>`, never Funnel, verify the
  route, and remove only routes they recorded (`<state>/bots/previews.json`).
  Credentials come from the default agent's store, access-only. Bot MCP keys
  are stored as digests; bot callers get only library-delegated tools, with
  `x-woven-caller`, `x-woven-bot-id` and `x-woven-bot-name` attribution.
  Pause-all is `botMCP.isEnabled = false`.
- Conversation batches go through `library.writeBotEntries(botID, {bot,
  conversations, entries})` (`remote/src/bots-library.mjs`). Adapters upsert
  by entry and conversation id. Until the server supervises
  `wovenmatter-library`, the adapter appends each batch as one JSON line to
  `<data root>/bots/library-outbox/<botID>.jsonl` (0600); the library adapter
  replaces it and imports that outbox.
- App-facing routes, authenticated as administrator or device grant (member
  auth replaces `authorizeClient` in `remote/src/bots-service.mjs`):
  `GET /v1/bots/status`, `GET /v1/bots/resources` (`memory {totalBytes,
  poolBytes, botBytes, usedBytes}`, `disk {path, totalBytes, freeBytes,
  capBytes, imageBytes, usedBytes}`, `warnings`), and `GET /v1/bots/ws`
  (WebSocket, proxied to the runtime's `/ws` with the runtime token).
  Administrator only: `POST /v1/bots/resources {poolBytes?, diskBytes?,
  botMemoryBytes?}` (a pool below per-bot RAM lowers it), `GET|POST
  /v1/bots/mcp {isEnabled?, groups?}` and `DELETE /v1/bots/mcp/keys/{botID}`.
  `/v1/execution/mcp-settings` also carries `botMCP {isEnabled, groups}`.

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
