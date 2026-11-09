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
- **Authentication between members: signed requests.** Every request from
  one member to another is signed with the caller's device key. Nothing is
  issued, cached or renewed, and nothing expires on a timer. Revoking a member
  takes effect as soon as the revocation syncs.
  - Headers:
    - `X-Woven-Member-Device`: the caller's device ID.
    - `X-Woven-Member-Time`: Unix time in milliseconds.
    - `X-Woven-Member-Nonce`: 16 random bytes, base64url without padding.
    - `X-Woven-Member-Signature`: an Ed25519 signature, base64url without
      padding.
  - The signed message is the UTF-8 string
    `woven-member-v1\n<METHOD>\n<path with query>\n<time>\n<nonce>\n<hex SHA-256 of body>`.
    An empty body hashes the empty string. A WebSocket upgrade signs its
    `GET` request. The path is the request target as sent, without a leading
    `/wovenmatter` mount (Tailscale Serve strips it before a Linux host sees
    the request; a Mac receives it intact). The Linux Node server, which Serve
    reaches through `/wovenmatter-execution/<id>`, accepts a signature over
    the path with or without that prefix.
  - The verifier accepts a request when:
    - the device is on the current member list and not revoked;
    - the time is within 300 seconds of its own clock;
    - it has not seen the nonce in that window;
    - the signature verifies with the member's raw 32-byte Ed25519 public key.
      That key is CryptoKit `Curve25519.Signing` compatible, and Node verifies
      it with `crypto.verify(null, …)`.
  - The shared test vectors in
    `shared/Tests/WovenMatterCompanionTests/MemberSignatureVectors.json` are
    checked by Swift and by Node (`remote/test/member-auth.test.mjs`).
- Pairing a new device still uses the existing pairing link and confirmation
  UI on a Mac. Its result is a signed member entry instead of a bearer grant.
- The Linux Node server verifies member signatures itself. It reads the member
  list from its local library host (`GET /v1/members` on the library socket),
  which returns each member's `deviceID`, `kind`, `name`, `publicKey`
  (base64), `endpoints` and `revoked`, plus a `revision`.
  The list is cached by `revision`, reloaded every 15 seconds and, at most
  every 2 seconds, when an unknown device signs.
- On the Linux server (`remote/src/server.mjs`, `member-auth.mjs`), a signed
  request from any member gets what a device grant had: execution and
  inference routes, `GET /v1/bots/status|resources` and `GET /v1/bots/ws`. A
  `mac` member is also an administrator, like the installing Mac's bearer:
  every administrator route, the bots changes and `/v1/host/*`. During the
  transition the installer's API bearer and existing device grants keep
  working beside signatures; the runtime host API (`/v1/bots-host/*`) and
  session MCP (`/mcp`) keep their own bearers.
- Remote host administration (status, logs, restart, update) is available to
  every Mac member, as signed requests to the Linux server:
  `GET /v1/host/status` (remote-host.sh `status` plus `library` and
  `memberIdentity`), `GET /v1/host/logs?lines=N`, `POST /v1/host/restart`
  (202), `POST /v1/host/bots-configure {poolBytes, diskBytes}` (bytes or
  `null`), and `POST /v1/host/update?fingerprint=<sha256>[&roles=…]` whose body
  is the host bundle (202; `GET /v1/host/update` reports `running`,
  `succeeded` with the status, or `failed` with the error). Restart and update
  run in a transient systemd user unit, because they stop the server. First
  install still runs over Tailscale SSH from the Mac that adds the machine.
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

Routes the membership workstream adds to the local API, which the Node server
already calls (`remote/src/library-host.mjs`):

- `GET /v1/identity` → `{deviceID, kind: "linux", name, publicKey, endpoints}`,
  this machine's member identity. Until it exists the server uses the health
  `deviceID` with no key.
- `GET /v1/members` → `{revision, members: [...]}` (see "Membership").
- `POST /v1/publisher/{journal,retained/settle,association,artifacts/register,artifacts/chunk,artifacts/commit}`:
  the bodies and replies of a Mac's `/v1/federation/publisher/*`. The caller is
  named by headers instead of a publisher bearer: `X-Woven-Workspace` (library
  ID), `X-Woven-Workspace-ID` and `X-Woven-Execution-Device-ID`.
- `POST /v1/bots/{botID}/entries`: a runtime conversation batch (`{bot,
  conversations, entries}`, see "Runtime host API"), upserted as described there.

**Node server supervision** (`remote/src/library-host.mjs`, wired in
`server.mjs`). On native Linux hosts the server starts
`<release>/host/library/linux-<arch>/wovenmatter-library --data-root <Woven data
root> --port P --socket <root>/run/library.sock --token-file
<root>/run/library-api.token --harness-catalog <release>/harnesses/catalog.json`,
so the library lives at `<data root>/library/workspace.sqlite`. It creates the
token first, keeps the loopback port in `<state>/library/host.json` so the
Serve route stays valid, waits for the ready line (or `library.json`),
restarts a crash with backoff up to 30 s and stops it on SIGTERM. After each
start it publishes the loopback port with `tailscale serve --bg --https=<port>
--set-path=/wovenmatter` (the first of 8443, 10000, 8444, 8445 with no TCP
route, as a Mac chooses; the recorded route is updated in place, never
Funnel; recorded in `<state>/library/serve.json`, removed by uninstall), and
writes `<state>/library/identity.json` (`{deviceID, kind, name, publicKey,
endpoints, libraryEndpoint, updatedAt}`, 0600), which `remote-host.sh inspect`
and `status` return as `memberIdentity` for the Mac that creates this
machine's member entry; `/v1/health` reports it too. `remote-host.sh
install|update` runs `--migrate-only` after stopping the old service and
before switching releases; a failed migration, or any later failure, restores
the database files and the previous release. Isolated tests use
`WOVENMATTER_LIBRARY_BINARY`, `WOVENMATTER_LIBRARY_DATA_ROOT`,
`WOVENMATTER_LIBRARY_SERVE=0` or `WOVENMATTER_LIBRARY_HTTPS_PORT`;
`WOVENMATTER_LIBRARY=0` turns it off.

The server sends a session's notes, history, calendar and library tools to
`POST /v1/mcp` (registering it with `POST /v1/callers` first), so they work
with every Mac offline and no single-Mac library grant. History the caller may
read only through its managed sessions, and all history while the library host
is down, comes from the Node journal. Databases, `woven_context` and
`woven_html_render` stay in Node; timers, usage, `woven_sessions_folders`,
sessions on other workspaces and bot callers still use the Mac grant until
their own workstreams move them. Session history is published to the local
publisher routes (the Mac grant is only a fallback without a library host),
and bot conversation batches go to `/v1/bots/{botID}/entries`, waiting in the
outbox while the host is down.

Tool execution is `WorkspaceToolExecutor` in `WovenMatterDashboardStore`, the
same code the Mac app's `WorkspaceAgentToolsModel` now delegates to. Note edits
go to `WorkspaceDatabase.readNoteForEditing` / `applyNoteEdits`, so a Linux
edit stores the same `NoteDocument` bytes a Mac stores for the same edit.

**Linux build.** `scripts/build-linux-library.sh` builds
`remote/host/library/linux-{x86_64,aarch64}/wovenmatter-library` (static musl,
any distribution) in the pinned Swift image with the pinned Static Linux SDK
and SQLite amalgamation (`remote/library/build-version.json`) and packs it as
`wovenmatter-library.gz` (`gzip -9 -n`) beside `wovenmatter-library.sha256`, the
uncompressed binary's SHA-256 (`--uncompressed` also keeps the binary for local
runs). Anything under `remote/host/` is a host bundle input, so a Mac app built
with those files present ships them to every host install and update; the bundle
manifest verifies the `.gz`, and `remote-host.sh` unpacks it to
`<release>/host/library/linux-<arch>/wovenmatter-library` (0700) and checks the
recorded SHA-256 before the migration runs (`library_verification_failed`
otherwise; a release with a plain binary is used as is). Starting and
supervising it is the Node server's job. `scripts/test-linux-library.sh` builds
and tests the portable targets on Linux; the manual validation workflow
(`linux` scope) runs both and keeps the binaries as an artifact. The release
workflow's `linux-library` job (ubuntu, Docker) builds both architectures and
hands them to the macOS job, which checks them with
`scripts/verify-linux-library.sh` before `xcodebuild`.

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
  and it returns unused memory to the Mac through the balloon (see Mac VM:
  Virtualization offers no free page reporting, so the balloon follows the
  guest's demand instead).

#### Mac VM

The VM belongs to `WovenMatterVMHelper`, a per-user launch agent bundled at
`Contents/Helpers/WovenMatterVMHelper` (Apple silicon only; signed with
`com.apple.security.virtualization`, built by `scripts/build-vm-helper.sh`).
Its job is `~/Library/LaunchAgents/<bundle id>.vm.plist`, label
`<bundle id>.vm`, with `KeepAlive: {SuccessfulExit: false}`: a crash or kill
restarts it, a clean stop leaves it stopped. Killing the helper reboots the
guest, like a power cut: containers, images and volumes survive, containers
with a restart policy come back, and writes not yet synced in the last few
seconds may be lost (the guest writes back dirty data within about 2 s and
commits the data disk's journal every 2 s; fsync'd data is durable). The helper is started on demand by the app; it then also starts at
login until `stop()`.

- **Files.** Everything lives in `<support directory>/WovenVM`, where the
  support directory is the app's workspace folder (`Woven Matter`, or the
  Dev instance's folder): `disk.img` (16 GB sparse root), `data.img` (sparse
  data disk as large as the volume, holding `/var/lib/docker` and
  `/var/lib/containerd`), `efi-vars.fd`, `seed.iso`, `config.json`,
  `state.json`, `console.log`, `helper.log` and `snapshot/`. Sockets are
  `docker.sock` and `control.sock` in the same folder (0600, folder 0700),
  or in `/private/tmp/wovenmatter-vm-<uid>-<digest>/` when that path would
  exceed `sun_path`. Always read the socket path from the API, never build it.
- **Guest.** The pinned Ubuntu 26.04 LTS arm64 cloud image
  (`app/VMHelper/guest-version.json`), converted from QCOW2 to a raw disk on
  first run, EFI boot, cloud-init NoCloud seed. First boot purges
  unattended-upgrades, snapd and SSH, masks the apt timers, formats the data
  disk and installs the pinned Docker Engine from Docker's signed apt
  repository (packages held). The guest changes only through Woven's update.
  It has no user, password or SSH key; the Mac reaches it over vsock only,
  and the guest agent accepts only the host CID.
- **Engine socket.** `docker.sock` carries the Docker Engine API to the
  guest's dockerd (vsock 2375). It is byte-transparent: HTTP upgrade and
  hijack (attach, exec) work, and each direction ends independently, so an
  exec whose stdin closed still returns all its output. Before the VM is
  ready it answers `503 {"message": ...}`.
- **Egress.** Inside the guest, `WOVEN-EGRESS` (from `DOCKER-USER`, all
  Docker bridges) rejects container traffic to 100.64/10,
  fd7a:115c:a1e0::/48, RFC 1918, link-local, ULA, loopback, multicast and
  every address of the Mac (pushed by the helper), and `WOVEN-INPUT` rejects
  container traffic to the guest itself. DNS to the NAT gateway is the one
  exception. Containers have no `CAP_NET_ADMIN` in the guest namespace and
  cannot open vsock sockets. The bots runtime must never create
  privileged or host-network containers, or mount the socket.
- **Resources.** The VM boots with the RAM pool (no cap: all RAM), which is
  the hard limit. A change applies fully at the next VM restart, which the
  helper performs by itself when no container runs; until then a lower pool
  is applied through the balloon, which the guest may deflate under memory
  pressure (Virtualization's balloon offers deflate-on-OOM). Unused guest
  memory returns to the Mac through the balloon. Virtualization offers no
  free page reporting, and it frees ballooned pages on the Mac only while
  they stay in the balloon (deflating re-commits them), so the balloon
  follows demand: every second the helper reads guest memory and sets the
  target to what the guest uses (page cache counts as free) plus headroom
  (the larger of 1 GiB and a quarter of the pool). It grows back at once
  when the guest needs more, opens fully when guest available memory falls
  below half the headroom or the guest agent does not answer within a
  second, and shrinks only after demand stayed lower for 30 seconds. An
  allocation faster than the headroom can stall for about a second until the
  balloon opens; it is not killed. Ballooned pages become clean at once and
  leave the VM process within about 20 seconds; `vmMemoryFootprintBytes` is
  the process's `phys_footprint` (what Activity Monitor shows) and can lag.
  Per-container memory limits (`Memory`, `MemorySwap`) are enforced by the
  guest kernel (cgroup v2). The disk cap is enforced inside the guest by a
  reserve file of unwritten extents on the data disk, so raising and lowering both apply at
  once while running; lowering stops at what is used. Freed blocks are
  trimmed back to the Mac every ten minutes.
- **Time.** The helper sets the guest clock on wake
  (`NSWorkspace.didWakeNotification`) and every minute.
- **Updates.** `update()` shuts the guest down, saves APFS clones of the
  disks to `snapshot/` (one kept), boots, upgrades guest packages and the
  pinned Docker Engine (also delivering the bundle's current guest files),
  reboots and health-checks Docker. On failure it restores the clones and
  reports `updateFailure`. A new image pin affects new installs only.

**Swift API** (`WovenMatterClient`, `WovenVMController`):

| Call | Meaning |
| --- | --- |
| `WovenVMController.forApp(supportDirectory:)` | Nil on Intel or without the helper |
| `ensureRunning()` | Install/refresh the launch agent, start the helper, return status |
| `status()`, `waitUntilReady(timeout:progress:)` | `WovenVMStatus`: `phase` (`stopped`, `downloading`, `preparing`, `booting`, `provisioning`, `ready`, `updating`, `failed`), `detail`, `failure`, `progress`, `engineSocket`, `resources`, `guest`, `forwards`, `updateFailure`, `snapshotAvailable` |
| `engineSocket` | Docker Engine API Unix socket for the bots runtime |
| `applyResources(WovenVMResources(memoryBytes:diskBytes:))` | `nil` means no cap |
| `forwardPreview(WovenVMForwardRequest(container:port:hostPort:))` | Optional; the runtime carries previews over Engine API exec streams and does not use it. Returns `WovenVMForward` with the `127.0.0.1` `hostPort`; idempotent; resolved by container name at connect time; survives restarts |
| `unforwardPreview(id:)`, `forwards()` | |
| `update()`, `restart()` | |
| `stop()` | Shut down, stop the helper, remove the launch agent |
| `uninstall()` | `stop()`, then delete every VM file |

`resources` (`WovenVMResourceReport`) gives the Mac's total RAM, disk total
and free, the VM's boot memory, physical footprint, guest memory in use,
balloon target, the effective disk cap, the disk images' real allocation,
guest disk use, and `restartPending`.

**Control API** for other processes: HTTP/1.1, JSON,
one request per connection on `control.sock` (e.g.
`curl --unix-socket <control.sock> http://vm/v1/status`):
`GET /v1/status`; `PUT /v1/resources`; (optional forwards) `GET /v1/forwards`;
`POST /v1/forwards` with `{"container": "<name or id>", "port": 3000}` (or
`"address"` instead of `"container"`, optional `"hostPort"`) returning
`{"id", "hostPort", ...}` with 201; `DELETE /v1/forwards/<id>`;
`POST /v1/update`, `/v1/restart`, `/v1/stop` (202). Errors are
`{"error": "..."}`.

- **Image:** Ubuntu 26.04 LTS with Chromium and Playwright, git, Node, Python,
  build tools and tini. A bot runs as a user with passwordless sudo, which
  gives it full root inside its container.
- **Network:** the container has internet access. Outbound traffic to the
  tailnet (CGNAT 100.64/10, fd7a:115c:a1e0::/48), private and link-local ranges
  and the host is blocked by the engine host: iptables on the Woven bridge on
  Linux, and inside the guest on a Mac. No container port is published, not
  even for previews (see Previews). The Docker socket is never mounted into a
  bot.

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
  Containers use Cloudflare's and Google's public resolvers. Bots use only the
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
  installed. `image.tag` is `wovenmatter-bots`; `machine.deviceID` is the
  library host's member identity, or, without a library host,
  `WOVENMATTER_DEVICE_ID` or `<data root>/identity/device-id` (0600, created
  once).
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
  by entry and conversation id. The library adapter posts each batch to the
  library host's `POST /v1/bots/{botID}/entries`; while the host is down or
  refuses, it appends the batch as one JSON line to
  `<data root>/bots/library-outbox/<botID>.jsonl` (0600) and replays that
  outbox, in order, when the host is ready again.
- App-facing routes, authenticated as a member (or, during the transition,
  administrator bearer or device grant; `authorizeClient` in
  `remote/src/bots-service.mjs`):
  `GET /v1/bots/status`, `GET /v1/bots/resources` (`memory {totalBytes,
  poolBytes, botBytes, usedBytes}`, `disk {path, totalBytes, freeBytes,
  capBytes, imageBytes, usedBytes}`, `warnings`), and `GET /v1/bots/ws`
  (WebSocket, proxied to the runtime's `/ws` with the runtime token; any
  `Origin` header is refused, since only native apps connect: the Mac's
  `URLSessionWebSocketTask` sends none, which `PiBotHandshakeTests` checks).
  Administrator only: `POST /v1/bots/resources {resources: {poolBytes?,
  perBotBytes?, diskBytes?}}` (a missing field stays; a pool below per-bot
  RAM lowers it), `GET|POST /v1/bots/mcp {isEnabled?, groups?}` and
  `DELETE /v1/bots/mcp/keys/{botID}`. `GET /v1/bots/status` and the
  resources reply use the shape in "Woven server routes for bots" below,
  plus `workspaceEnabled`, `runtimeAvailable`, `engine`, `runtime` and
  `settings`. On Linux `versions.app` is the Woven Matter version that shipped
  the host release (the bundle manifest's `releaseVersion`, which
  `remote-host.sh` passes as `WOVENMATTER_RELEASE_VERSION`; `null` for older
  releases), `versions.fingerprint` is the release fingerprint,
  `versions.librarySchema` is the library host's paired-library schema hash
  once its ready line carries `schema` (`null` until then), `versions.runtime`
  is the bots package version and `paused` is `botMCP.isEnabled == false`.
  `GET /v1/health` carries the same as `release {version, fingerprint,
  librarySchema}`. A Mac treats a Linux host whose fingerprint differs from the
  host release it would install (`RemoteWorkspaceSSHClient.bundledHostFingerprint()`)
  as `needsUpdate`, whatever version it names.
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
| `GET /v1/bots/status` | `{ machine: { deviceID, name, kind }, enabled, state, message?, versions: { app, runtime, protocol, fingerprint?, librarySchema? }, resources, capacity: { memoryBytes, diskTotalBytes, diskFreeBytes, diskUsedByBotsBytes? }, paused, updating?, engineUpdateFailure? }` (`updating` and `engineUpdateFailure`: a Mac's VM update) |
| `POST /v1/bots/engine/update` (Macs) | starts the Mac's VM update and returns the status at once; follow `updating`, then `engineUpdateFailure` |
| `POST /v1/bots/resources` `{ resources: { poolBytes, perBotBytes, diskBytes } }` | the status after applying; `null` is no cap (Linux also leaves a missing field as it is) |
| `GET /v1/bots/ws` (WebSocket upgrade) | proxied to the runtime's `/ws` with the runtime's own bearer |

Until member auth lands, a Mac's server accepts any current execution grant
(`CompanionExecutionAuthentication`) for these routes, and a Linux server accepts its
workspace API token through the SSH tunnel. On the Mac, `ApplicationModel.botsAccess`
is the one function member auth replaces.

**Linux bots-only install.** The Mac runs `remote-host.sh prepare AUTHORIZED
<access-mode> bots`, then `remote-host.sh install <workspace-id> <port> <access-mode>
<fingerprint> bots` with the same stdin as any install (token line, then bundle); see
"One server, roles". Both use the SSH account's existing noninteractive sudo. The
Mac records a bots-only host with workspace id `bots`. Adding the workspace later
keeps that record (its id, token, port and access level) and runs `remote-host.sh
install <real-id> … workspace` (`RemoteHostInstallMode.addWorkspace`): the script lets
the first workspace install take over a bots-only `bots` record once, on the same
server and data root with bots kept, and records `previousIDs: ["bots"]` so uninstall
also removes routes published under the old id. Any other id change is still
`host_workspace_conflict`.

**Mac engine.** The bots host codes against `BotEngineHost`
(`app/App/Services/BotEngineHost.swift`): `ensureRunning(resources:)` returns the
Docker socket once the VM answers, `apply(resources:)`, `diskUsedByBots()`, `status()`,
`update()` (the VM's update; returns when it is ready again, throws if it was rolled
back), `stop()` and `onStatusChange` (download, first-boot and update progress, and
failures with their reason). Previews need no VM port forward: the runtime carries them
over Engine API exec streams. `BotEngineHostFactory.make(<support directory>)` returns
`WovenVMBotEngineHost` over `WovenVMController.forApp(supportDirectory:)`: the RAM pool
is the VM's memory and the disk cap its disk cap (at least 1 GB and 10 GB; no cap stays no
cap), and per-bot RAM stays in the runtime config. Where the VM cannot run (Intel, or no
helper) it returns an engine that says why. "Update everything" updates each Mac's VM
before its bots (`BotUpdatePlan.Step.engine`, `BotsCommand.updateEngine`).

## Out of scope

- TestFlight preparation (its own PR).
- The `wovenmatter/pi-bot` repository and its workstation preview, which stay
  untouched.
- Outside-agent MCP on Linux or the iPhone.
