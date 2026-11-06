# Pi Bot integration

Pi Bot ([`wovenmatter/pi-bot`](https://github.com/wovenmatter/pi-bot)) stays its own
repository and owns the bots: server, storage, sign-ins, profiles, chat UI and thread
behavior. Woven Matter consumes a recorded revision of it as a dependency and owns the
native sidebar, the side-area tabs, device selection, process lifecycle and Woven MCP
authorization.

Provider sign-ins, keys and bot data never pass through Woven Matter. Nothing here
changes a standalone Pi Bot deployment, which keeps working without this app.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Dependency form | `pi-bot/selection.json` records a repository and full commit SHA. No submodule, no `main` resolution at build time. | The commit hash pins the whole tree. Pi Bot has no npm release and changes daily. Submodules complicate this repository's worktrees and CI. |
| Chat, threads, settings UI | Embed Pi Bot's React client in a `WKWebView` | Trey asked for its UI and keeps iterating on it; a SwiftUI copy would drift. |
| Sidebar, side area | Native | They must behave as the rest of Woven Matter does. |
| Sidebar groups | Stored by the Pi Bot server, separate from teams | Groups belong with the bots and appear on every client. Teams carry authority and messaging rules; groups are only placement. |
| Device choice | One Pi Bot server on one device, chosen in Settings → Bots | A deployment hosts many bots. Changing devices connects to that device's own bots; it does not move data. |
| Local process owner | The Woven background server | Closing the window must not stop bots. |
| Remote process owner | systemd user service (Linux) or launchd agent (Mac), installed over existing Tailnet SSH | Same transport and trust as remote workspaces and Apple device setup. No Woven Matter install is needed on the target. |
| Reaching a remote server | One SSH command running `pi-bot-relay.mjs`, from the background server | Pi Bot has no app-level auth and stays bound to loopback on the target. Like remote workspaces, it needs only SSH command execution, so it works on servers that turn off port forwarding, as hardened Macs do. |
| Bots reaching Woven MCP | Bearer grant to a dedicated bot principal. Local: loopback `/mcp`. Remote: a loopback port the relay opens on the device, carried back to that same endpoint. | Keeps MCP loopback-only with no new Tailscale Serve route. |
| Where bots' tools run | Apple's `container` on Apple silicon Macs with macOS 26 or later; Docker elsewhere, when it is installed | See [below](#bot-tools-on-a-mac). |

## Layout on a device

`scripts/pi-bot-host.sh` owns this layout on every target, local or remote.

```
<root>/
  releases/<commit>/     extracted bundle plus target-installed node_modules
  current -> releases/<commit>
  node/<version>/        checksum-verified Node
  tooling/               locked pnpm, installed with npm ci
  pnpm-store/
  data/                  pi-bot.sqlite, credentials.key
  config.toml            written once if missing, then owned by Pi Bot settings
```

`<root>` is:

- This Mac: `<application support>/PiBot`, so every Dev profile is isolated
- Remote Linux: `~/.local/share/wovenmatter/pi-bot/<instance>`
- Remote Mac: `~/Library/Application Support/Woven Matter Pi Bot/<instance>`

`<instance>` is `default` in production and the Dev instance name in Dev builds. The
service is `wovenmatter-pi-bot-<instance>.service` or the launchd label
`io.wovenmatter.pi-bot.<instance>`.

An install never touches `pi-bot.service`, `~/.config/pi-bot`, `~/.local/share/pi-bot`,
port 4317, or another instance's files. Managed configs use `backend = "encrypted-sqlite"`,
because the Keychain store uses one global service name that would cross instances.

## Bot tools on a Mac

Each bot's `bash`, `read`, `write` and `edit` tools run in its own Linux container, from the image
in Pi Bot's `packages/server/docker`. On a Mac, Docker Desktop and Apple's
[`container`](https://github.com/apple/container) were measured with that image on a Mac mini
(12 cores, 32 GB, macOS 27.2). Memory is the physical footprint of the runtime and its VMs.

| | Docker Desktop 29.9 | Apple `container` 1.6 |
| --- | --- | --- |
| Started, no containers | 3.8 GB | 22 MB |
| After building the image, no containers | 6.9 GB, until it quits | 22 MB, once the builder is removed |
| One idle bot | 6.9 GB, shared | 0.5 GB |
| After a bot's npm install, 2 GB of files and 2 GB of allocations | 8.7 GB, shared | 3.2 GB, until it stops |
| All bots stopped | 8.7 GB | 22 MB |
| Container start to first command | 0.49 s | 0.64 s |
| Each later command | 31 ms | 64 ms |
| 20,000 small files, write / read / delete | 0.36 / 0.18 / 0.14 s | 0.28 / 0.16 / 0.10 s |
| 2 GB sequential write | 1.04 s | 0.94 s |
| SHA-256, 4 CPUs | 13.5 GB/s | 13.4 GB/s |
| Needs | An app to install and keep running, with its own license terms | Nothing: it runs from a user folder, with no administrator |

So a Mac uses Apple's. The speeds are about equal, and the memory decides it: Docker Desktop's
shared VM holds 4 to 9 GB whether or not a bot is working, which a 16 GB Mac can't spare. Apple's VMs keep the memory
they have touched until they stop, so Pi Bot starts them on first use and stops them when idle;
see Pi Bot's `docs/environments.md`. Docker stays the choice on Linux, where it needs no VM.

Woven Matter installs Apple's signed package with no administrator, after checking its SHA-256 and
that Apple signed it. It doesn't touch an installed `container`, which is used as it is. Otherwise
the copy goes in `~/Library/Application Support/Woven Matter Pi Bot/runtime`, outside any one
installation, because Apple's services are per user and can't run twice: every installation on a Mac
shares them. Each records its use in `runtime/instances/`.

Removing an installation deletes only its own bots' containers and volumes, named from its database.
If they can't be removed, nothing is deleted, so the database can name them next time. The shared
runtime goes only when no installation uses it and no containers remain. An SSH session can't see
services started by a launchd agent, so this runs as a one-shot job in that agent's domain.

## Selection record and bundle

`pi-bot/selection.json`:

```json
{
  "schema": 1,
  "repository": "https://github.com/wovenmatter/pi-bot.git",
  "commit": "<40 hex>",
  "protocol": 1,
  "pnpm": "12.16.1",
  "node": {
    "version": "26.13.0",
    "sha256": { "darwin-arm64": "…", "darwin-x64": "…", "linux-x64": "…", "linux-arm64": "…" }
  }
}
```

The Node record must match `default-agent/.node-version`, `remote/host/runtime-versions.json`
and the checksums in `scripts/prepare-default-agent.sh`. A test rejects drift.
`pi-bot/tooling/{package.json,package-lock.json}` locks pnpm itself.

`scripts/prepare-pi-bot.sh <output>` fetches the recorded commit into a cache keyed by
commit and toolchain, runs the frozen install and `pnpm package:woven`, and writes
`pi-bot-bundle.tar.gz`, `selection.json`, `pi-bot-host.sh` and the pnpm tooling lock to
`<output>`. Xcode's resource phase calls it with `<Resources>/pi-bot`. Setting
`WOVENMATTER_PI_BOT_SOURCE=<checkout>` builds from a local checkout in Debug only; Release
configurations refuse it.

The bundle is source-only: built `dist` output plus manifests and lockfile. Dependencies
install on the target, as the Linux host bundle does, because the Claude Agent SDK ships
per-OS, per-CPU and per-libc executables.

`pnpm package:woven --out <file>` lives in Pi Bot and writes a deterministic gzip tar with
`manifest.json` (`commit`, `version`, `protocol`, `lockSha256`), root `package.json`,
`pnpm-workspace.yaml`, `pnpm-lock.yaml`, `LICENSE`, `packages/server/{package.json,dist,docker}`,
`apps/web/{package.json,dist}`. It must not advance `.preview-build-number`.

## Host script

`pi-bot-host.sh` is plain bash plus curl, tar and sha256sum or shasum, so it runs on a stock
Mac or Linux box. It may arrive through `ssh host bash -s -- <args>`. Progress goes to stderr
as `WM_PROGRESS <phase>`. Results go to stdout as one JSON object. Failures exit nonzero and
print `{"error":"code","detail":"message"}` to stderr.

```
inspect   --instance NAME [--root DIR]
install   --instance NAME [--root DIR] --commit SHA --node-version V --node-sha256 H
          --pnpm-version V --bundle FILE|- --tooling-lock-dir DIR|- [--service|--no-service]
          [--port P] [--container-version V --container-sha256 H]
cancel-install | start | stop | restart | status   --instance NAME [--root DIR]
uninstall --instance NAME [--root DIR] [--delete-data]
```

`inspect` returns:

```json
{
  "schema": 1,
  "os": "linux", "arch": "x64", "libc": "glibc",
  "serviceManager": "systemd", "environment": "docker", "docker": true,
  "managed": { "installed": true, "commit": "…", "running": true, "port": 47310, "root": "…" },
  "existing": [{ "port": 4317, "version": "0.1.0", "protocol": null, "installationId": null, "service": "pi-bot.service" }]
}
```

`existing` lists standalone Pi Bot servers answering on loopback, probing only port 4317 and
the port in `~/.config/pi-bot/config.toml`. Other ports on a host belong to other apps.
`inspect` never reads credentials, config secrets or conversations.

`install` is atomic: it stages `releases/<commit>`, installs, health-checks on a scratch port
against scratch data, backs up the database with `VACUUM INTO` when updating, swaps `current`,
starts the service, and restores the previous `current` on failure. It returns
`{"schema":1,"commit":"…","port":47310,"root":"…","node":"<path>","entry":"<path>","config":"<path>"}`.

## Protocol additions

Every addition is capability-gated. The embedded client needs `host.embed`, so Woven Matter
asks the user to update an older attached instance rather than show a broken page.

`hello` and `GET /health` gain `protocol: 1`, `installationId` (a UUID stored once in the
database) and `capabilities`: `host.embed`, `groups`, `woven.mcp`, `message.context`.

Sidebar groups:

```
groups.list                         → { groups: [{ id, name, position }] }
groups.create  { name }             → { group }
groups.rename  { groupId, name }    → { group }
groups.delete  { groupId }          → { deleted: true }   members become ungrouped
groups.reorder { groupIds }         → { groups }
bots.setGroup  { botId, groupId }   → { bot }             groupId null clears it; Admin Bot refused
```

`BotSummary` gains `groupId?`. Changes push `groups.changed`; membership changes also push
`bots.changed`. `thread.setPinned` pushes `threads.changed`. Groups never affect teams, roles
or messaging.

Woven MCP connection. These are user or host requests only, never bot tools:

```
woven.status                                → { state, endpointURL?, toolCount, error? }
woven.connect { endpointURL, bearerToken }  → status
woven.disconnect                            → status
```

`state` is `disconnected`, `connecting`, `ready` or `unavailable`. The endpoint must be HTTPS or
loopback HTTP. The token goes into the encrypted credential store and is never returned.

Message context: `message.send` gains optional `context` (max 4000 characters), set only by the
host. The model sees it ahead of that user turn. The transcript and chat strip it, using the
same approach as the fallback note.

Bot notifications from Woven Matter arrive through ordinary `message.send` to the bot's main
channel, with an optional `deliveryId`. Pi Bot remembers it, so a retry after a lost
acknowledgement cannot submit the same work twice. Delivery is at-least-once: a crash between
submitting and recording acceptance repeats a notification rather than losing it.

## Host bridge

Woven loads `<base>/?host=woven&theme=<green|cognac|dark>` plus the normal hash route. In that
mode the client renders no sidebar, sidebar toggle or brand, and its settings render one section
with no tab row, because Woven provides that navigation. The standalone client is unchanged.

Native to web, on `window.wovenPiBotHost`:

```
setTheme(theme)        navigate(hashRoute, token)        setContext(string | null)        focusComposer()
setHeaderInsets(left, right)
```

Web to native, through `window.webkit.messageHandlers.wovenBots.postMessage`, each with `v: 1`:

```
{ kind: "ready", protocol, installationId }
{ kind: "route", hash, navigation, botId?, conversationId?, threadView?, settings?, section? }
{ kind: "connection", state }
{ kind: "openExternal", url }
```

`navigation` echoes the latest `navigate` token. A report carrying an older token describes a
route from before the host's newest selection, so the host ignores it.

Native code validates the main frame and origin on every message. The bridge exposes no RPC,
files or credentials. Drafts survive bot switches, keyed by bot and conversation.

## Bot MCP principal

`WovenMCPCaller.bot(installationID:botID:)` is `woven:bot:<installation>:<bot>`, and
`WovenMCPCaller.isAppWide(_:)` is true for it and for `outside`. It is not a conversation and no
dummy chat is created for it. Policy is `WorkspaceToolSettings.botMCP`, shaped like
`externalMCP` but on by default, with Computer Use and Executor off by default. It is independent
of **Expose Woven MCP**: outside access can stay off while bots keep working.

The bearer grant identifies an installation. Woven persists only its SHA-256 digest, in
`mcp-access.json`, and rotates the grant whenever it needs to resend it, so plaintext never rests
on the Woven side. Calls carry `x-woven-bot-id` (a UUID) and `x-woven-bot-name` (percent-encoded).
Those headers attribute a call; they are not an authorization boundary, because every bot in an
installation shares one trust domain.

Unlike outside callers, bots keep a live runtime:

- Sessions they create are coordinated by them unless `independent` is set
- Completion, failure and needs-input events become deliveries to the bot's main channel
- A bot may address `sessionID` targets for goals, timers and HTML, as outside callers do

Host API:

```swift
struct WovenBotMCPGrant: Sendable { let endpointURL: String; let bearerToken: String }
struct WovenBotNotification: Sendable { let id: String; let installationID: String; let botID: String; let text: String }

// WovenMCPHost, via WorkspaceAgentToolsModel
func issueBotGrant(installationID: String) async throws -> WovenBotMCPGrant   // rotates
func revokeBotGrants(installationID: String)
var botNotificationSink: (@MainActor (WovenBotNotification) async throws -> Void)?

// WovenMCPAccessAction / WovenMCPAccessSnapshot
case setBotsEnabled(Bool), setBotsGroup(WorkspaceToolGroup, enabled: Bool)
var botSettings: WorkspaceExternalMCPSettings
```

## Native surfaces

- **Sidebar:** a **Bots** disclosure section sits above New chat, with a New bot row. Admin Bot
  stays first and the orchestrator second, then groups, then ungrouped bots. A bot's row opens its
  main channel and shows only its name. A chevron reveals its threads: pinned first, then newest
  created first, matching Pi Bot's `sortThreads`.
- **Selection:** a chat panel holds either a conversation or a `DashboardBotTarget`. Bots stay on
  `destination == .workspace`, so the side-area tabs, splitter, focus mode and compact layout all
  apply unchanged. Pi Bot's own Main and thread split lives inside its web view.
- **Links:** http(s) links from a bot open in a side-area browser tab.
- **Settings:** a **Bots** row follows Agents. It holds device choice and lifecycle, Woven MCP
  access, and drill-downs into Pi Bot's own settings sections.

## Known limits

- Provider sign-ins are the user's to perform, in Pi Bot's own settings.
- Without a container runtime, bots have messaging, web and Woven MCP tools, and do coding work
  by launching Woven sessions. That means Linux without Docker, and Intel Macs or Macs before
  macOS 26 without Docker.
- Apple's `container` has no restart policy, so a bot's background job ends if its server restarts
  or the Mac does. Docker's containers come back on their own.
- Woven dictation is not bridged into the embedded composer.
- iPhone and iPad do not show bots.
