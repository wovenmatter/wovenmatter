# Woven Matter

Woven Matter runs and manages coding agents across your own devices. It has a
Mac app, an iPhone app, and a headless Linux host. All of them join one
Tailscale network (tailnet) and share one synced library of notes,
conversations, calendar, and artifacts.

Supported harnesses are Pi Durable (built in), Codex, Claude Code, Grok Build,
and OpenCode. Third-party harness CLIs are not bundled. Settings can install
them, or use the installations and provider accounts you already have.

[Releases](https://github.com/wovenmatter/wovenmatter/releases) ·
[Documentation](docs/README.md) ·
[Getting started](docs/guide/getting-started.md)

## Surfaces

| Surface | Role |
| --- | --- |
| Mac | The full interface. It runs a background server that holds a library copy, runs agents, and serves Woven MCP. Closing the window leaves that server running. |
| Linux host | Headless. It runs one Woven server: an optional workspace for agents, a library copy, Woven MCP and, when enabled, bots. A Mac installs it over Tailscale SSH. |
| iPhone | A focused interface. It runs Quick Chat on the device and works with sessions on every Mac and Linux workspace. |

Each Mac or Linux machine runs one Woven server. A Linux machine can run bots
without a workspace. Adding the workspace later reuses the same server.

## How devices reach each other

- **Members.** Every device has its own long-lived signing key: in the Keychain
  on a Mac or iPhone, and in a `0600` file on Linux. The member list is a
  signed record set that syncs to every device. Any Mac can add a device.
  Removing a device is a signed revocation. It takes effect on each device as
  soon as that device syncs.
- **Signed requests.** Every request from one member to another is signed
  with the caller's device key. No tokens are issued, cached, or renewed.
- **Direct reach.** Once paired, each device talks directly to every other
  online device over tailnet HTTPS (`*.ts.net`). No single Mac is required.
  The iPhone has no home Mac. It syncs with whichever Mac or Linux host
  answers first.
- **Pairing.** Macs pair with each other on the Mac connections page, by link
  or nearby request. An iPhone pairs with any Mac. Linux hosts are added from
  a Mac, under Settings > Remote workspaces.

## Library

- Every Mac and Linux host keeps a full copy of the library in SQLite. Linux
  runs the same Swift library code as the Mac, as the `wovenmatter-library`
  executable, so agents read and edit notes, calendar, history, and artifacts
  the same way on both.
- Sync is peer-to-peer between every online Mac and Linux member. It runs on
  changes, not on a polling loop, and a device catches up when it comes back
  online. Conflicts are kept as conflict copies.
- Peers must have matching library schemas to sync. When versions differ, each device
  shows which part needs updating and offers **Update everything**.
- The iPhone keeps full copies of notes, Quick Chats, calendar, and timers and
  reminders. It also keeps the list of every session on every device, plus
  transcripts of recent or opened sessions. Large files download when opened.
  Writing that exists only on the phone is included in iCloud and computer
  backups. Caches the library can supply again are excluded. Credentials stay
  in device-only Keychain items.

## Agents and sessions

- Every harness runs in full access by default on every workspace, including
  sessions started by other agents. Each harness's full mode is labeled
  "Full access".
- Through Woven MCP, an agent on any Mac or Linux host can create, message,
  inspect, stop, and answer sessions on any other Mac or Linux workspace. The
  request goes straight to that workspace, so it works while other Macs are
  offline. Woven MCP also covers notes, calendar, history, the library,
  timers, the browser, and more.
- iPhone Quick Chat runs Pi Durable on the phone in full access. Its tools
  are notes, web search and read (Exa, Brave, or Firecrawl), questions to you,
  timers and reminders, and calendar. It has no shell or file tools and no
  background execution. Other devices see Quick Chats as read-only history.

## Bots

Bots are long-running agents, each with its own Linux container.

- One Node runtime per machine (`bots/`) runs every bot's agent loop on
  Pi Durable. Each bot's tools run inside its own Ubuntu container.
- Linux hosts use a Woven-owned Docker Engine, separate from any Docker you
  run yourself. Installing it needs `sudo` once. Macs use a Woven-managed
  Ubuntu VM through Apple's Virtualization framework, on Apple silicon only.
- Provider credentials never enter a container. Each bot gets its own Woven
  MCP key, which can be revoked per bot.
- Containers have internet access but cannot reach the tailnet, private
  networks, the host, or each other. A bot can share a preview of a container
  port at a tailnet HTTPS address.
- A bot stops after 15 minutes idle and starts again on its next tool call.
  Its browser profile and its registered long-running services come back on
  restart.
- Bot conversations sync to every device through the library. You can manage
  bots on any Mac or Linux member from the Bots page in the Mac app.
  **Discover devices** lists the Macs and Linux machines on your tailnet and
  what each one needs before it can run bots.

## Repository layout

| Path | Contents |
| --- | --- |
| `app/` | macOS app (`WovenMatter.xcodeproj`) and Swift package: core, library store, library host and daemon, client, automation, browser (CEF), VM helper, power helper, updater records |
| `ios/` | iPhone and iPad app, its on-device Pi Durable runtime, and tests |
| `shared/` | Foundation-only package of note models and wire contracts used by both apps |
| `remote/` | Linux Woven server (Node), host install and engine scripts, container workspace images |
| `bots/` | Bots runtime, in-container helper, and container image |
| `default-agent/` | Pi Durable runtime that the Mac app and Linux hosts run |
| `harnesses/` | Harness catalog, adapter installation, and the bridge that connects harnesses to Woven MCP |
| `integration/` | End-to-end checks between the iPhone client and the Mac library API |
| `scripts/` | Build, launch, test, and release tooling |
| `docs/` | User guides, architecture contracts, and references |

## Development

Development needs macOS 26, Xcode 26, the Node release in
`default-agent/.node-version`, and `jq`. Building and testing need no provider
credentials. See [Contributing](CONTRIBUTING.md).

### Build and run

`scripts/build_and_run.sh` is the only development launcher. Each worktree
gets its own instance, bundle ID, caches, and data.

```sh
scripts/build_and_run.sh                    # snapshot (the default)
scripts/build_and_run.sh --mode snapshot
scripts/build_and_run.sh --mode client
scripts/build_and_run.sh --mode live
scripts/build_and_run.sh --mode snapshot --instance NAME
scripts/build_and_run.sh --plan             # print the resolved profile only
```

- **snapshot** (default): the full desktop app with its own background server,
  backed by an isolated copy of the library. It never syncs back to
  production.
- **client**: the full app as a connected client of the production library on
  the same Mac. Use it only when testing a connected client.
- **live**: the branch hosts the production library directly. Use it only when
  asked explicitly. Stop the production host first. An exclusive lease blocks
  a second owner.

`debug`, `logs`, and `verify` replace the default `run` action. See
[development builds](docs/DEVELOPMENT_BUILDS.md) for details.

The iPhone app builds with `scripts/build-ios.sh`. See [ios/README.md](ios/README.md).

### Validate

```sh
scripts/test-changes.sh          # suites chosen from files changed against origin/main
scripts/test-changes.sh --all    # changes that span components
scripts/test-changes.sh --ci     # the portable Linux check that PR CI runs
```

Narrower options are `--desktop`, `--macos`, `--native`, `--companion`,
`--companion-desktop`, `--remote`, and `--linux`. Use `scripts/test-container.sh`
for container lifecycle changes when Docker is available. Tests never call
provider services.

`scripts/with-pinned-node.sh COMMAND` runs a command with the pinned Node first
on `PATH`. The bots runtime requires it.

## Documentation

- [Woven everywhere](docs/architecture/WOVEN_EVERYWHERE.md): devices, membership, library sync, sessions, and bots
- [Development builds](docs/DEVELOPMENT_BUILDS.md)
- [Dependency policy](docs/DEPENDENCIES.md)
- [UI style guide](docs/STYLE_GUIDE.md)
- [Background execution](docs/architecture/BACKGROUND_EXECUTION.md)
- [Default agent credentials](docs/architecture/DEFAULT_AGENT_CREDENTIALS.md)
- [Documentation index](docs/README.md)
- [Agent guidance](AGENTS.md)

Report vulnerabilities through the [security policy](SECURITY.md). Woven
Matter is [MIT licensed](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md)
and [trademarks](TRADEMARKS.md).
