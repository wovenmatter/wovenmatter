# Woven Matter

Woven Matter is one workspace for all of your coding agents. Run Pi Durable,
Codex, Claude Code, Grok Build, and OpenCode side by side in a Mac app, keep
notes and data beside the conversation, and hand work to Linux machines and
long-running bots that keep going while your Mac is closed.

Everything runs on your own devices. Your Macs and Linux hosts join your own
Tailscale network (tailnet) and share one synced library of conversations,
notes, calendar, and files. There is no Woven Matter account and no hosted
service in between.

[Download](https://github.com/wovenmatter/wovenmatter/releases/latest) ·
[Getting started](docs/guide/getting-started.md) ·
[Documentation](docs/README.md)

## What you can do

- **Use every harness in one place.** Pi Durable is built in. Codex, Claude
  Code, Grok Build, and OpenCode use the installations and provider accounts
  you already have, or Settings installs them. Choose the model, thinking
  level, and permissions for each conversation.
- **Work in parallel.** Run many sessions at once across harnesses and view up
  to five side by side in panels while the rest keep running. Agents can
  start, message, and check on other sessions, including sessions on your
  other machines.
- **Keep your work beside the chat.** Open notes, spreadsheets, HTML pages,
  browser tabs, and document previews next to a conversation and work on them
  with the agent. **Library** collects the files, links, and photos exchanged
  in your conversations. Notes keep a version history you can restore from.
- **Give agents a browser and your desktop.** Browser Use drives a built-in
  Chromium browser. Computer Use operates Mac apps after you grant access in
  Settings → Permissions & Access.
- **Connect apps through Executor.** One managed Executor runtime gives every
  agent the same API, MCP, and code-backed app capabilities, with approvals
  in the conversation.
- **Schedule work.** Create scheduled tasks, put them on the calendar, and let
  agents set timers and follow-ups in their own conversations.
- **See what you use.** Usage shows tokens and estimated cost across harnesses
  and devices, plus each provider account's current limits.
- **Talk instead of type.** Dictation uses Apple's on-device speech
  recognition. Pi Durable can also use local model servers on your network.
- **Hand work to Linux.** Add a Linux machine from your Mac and its agents keep
  running, with their own files and sign-ins, while your Mac sleeps.
- **Run bots.** Bots are long-running agents, each with its own isolated Linux
  container, on the Mac or Linux host you choose.

## Requirements

- **Mac app:** an Apple silicon Mac with macOS 26 or later. Download the DMG
  from [Releases](https://github.com/wovenmatter/wovenmatter/releases/latest).
  The app updates itself.
- **Linux host (optional):** an amd64 or arm64 machine on your tailnet with
  OpenSSH, Python 3, and a systemd user manager. You add it from the Mac.
- **Tailscale** on every device that should reach another.
- **Provider access** for the harnesses you use: a subscription account or an
  API key.

## How it fits together

| Device | Role |
| --- | --- |
| Mac | The full interface. A background server holds a library copy, runs agents, and serves Woven MCP. Closing the window leaves that server running. |
| Linux host | Headless. One Woven server runs an optional agent workspace, a library copy, Woven MCP and, when enabled, bots. A Mac installs it over Tailscale SSH. |

Each Mac or Linux machine runs one Woven server. A Linux machine can run bots
without a workspace; adding the workspace later reuses the same server.

### Devices and pairing

- Every device has its own long-lived signing key: in the Keychain on a Mac,
  and in a `0600` file on Linux. The member list is a signed record set that
  syncs to every device.
- Macs pair with each other in **Settings → Apple Devices**, by link or nearby
  request. Linux hosts are added from a Mac in **Settings → Workspaces**.
- Every request between devices is signed with the caller's device key and
  travels directly over tailnet HTTPS (`*.ts.net`). No single Mac is required.
- Removing a device is a signed revocation. It takes effect on each device as
  soon as that device syncs.

### Library

- Every Mac and Linux host keeps a full copy of the library in SQLite: notes,
  conversations, calendar, artifacts, and files. Linux runs the same Swift
  library code as the Mac, as the `wovenmatter-library` executable.
- Sync is peer-to-peer between every online Mac and Linux member. It runs on
  changes, not on a timer, and a device catches up when it comes back online.
  Conflicting edits are kept as conflict copies.
- Peers must have matching library schemas to sync. When versions differ, each
  device shows which part needs updating and offers **Update everything**.

### Sessions across machines

- A session on another machine opens in the same conversation view as a local
  one. While it is open, its live state (the streaming reply, questions,
  approvals, and settings) and your commands travel on that machine's stream,
  a WebSocket signed with the device key. Nothing polls.
- Sessions you don't have open reach every device through library sync, so a
  machine that is offline still shows its saved history, marked offline.
- Through Woven MCP, an agent on any Mac or Linux host can create, message,
  inspect, stop, and answer sessions on any other Mac or Linux workspace. The
  request goes straight to that workspace. Woven MCP also covers notes,
  calendar, history, the library, timers, the browser, and more.
- New conversations start in **Full access** on every workspace, including
  sessions started by other agents. You can choose a stricter policy per
  conversation where the harness offers one.

### Bots

- One Node runtime per machine (`bots/`) runs every bot's agent loop on Pi
  Durable. Each bot's tools run inside its own Ubuntu container.
- Linux hosts use a Woven-owned Docker Engine, separate from any Docker you run
  yourself; installing it needs `sudo` once. Macs use a Woven-managed Ubuntu VM
  through Apple's Virtualization framework.
- Provider credentials never enter a container. Each bot gets its own Woven MCP
  key, which you can revoke per bot.
- Containers have internet access but cannot reach the tailnet, private
  networks, the host, or each other. A bot can share a preview of a container
  port at a tailnet HTTPS address.
- A bot stops after 15 minutes idle and starts again on its next tool call. Its
  browser profile and registered long-running services come back on restart.
- Manage bots on any Mac or Linux member from **Settings → Bots**. **Find
  devices** lists the Macs and Linux machines on your tailnet and what each one
  needs before it can run bots.

## Repository layout

| Path | Contents |
| --- | --- |
| `app/` | macOS app (`WovenMatter.xcodeproj`) and Swift package: core, library store, library host and daemon, client, automation, browser (CEF), VM helper, power helper, updater records |
| `remote/` | Linux Woven server (Node), host install and engine scripts, Executor image |
| `bots/` | Bots runtime, in-container helper, and container image |
| `default-agent/` | Pi Durable runtime that the Mac app and Linux hosts run |
| `harnesses/` | Harness catalog, adapter installation, and the bridge that connects harnesses to Woven MCP |
| `shared/` | Foundation-only package of note models and wire contracts shared by the Mac and iPhone apps |
| `ios/` | iPhone app (beta), its on-device Pi Durable runtime, and tests |
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
[development builds](docs/DEVELOPMENT_BUILDS.md) for details. The iPhone app
builds with `scripts/build-ios.sh`; see [ios/README.md](ios/README.md).

### Validate

```sh
scripts/test-changes.sh          # suites chosen from files changed against origin/main
scripts/test-changes.sh --all    # changes that span components
scripts/test-changes.sh --ci     # the portable Linux check that PR CI runs
```

Narrower options are `--desktop`, `--macos`, `--native`, `--cross-device`,
`--cross-device-desktop`, `--remote`, and `--linux`. Tests never call provider
services.

`scripts/with-pinned-node.sh COMMAND` runs a command with the pinned Node first
on `PATH`. The bots runtime requires it.

## Documentation

- [User guides and references](docs/README.md)
- [Woven everywhere](docs/architecture/WOVEN_EVERYWHERE.md): devices, membership, library sync, sessions, and bots
- [Development builds](docs/DEVELOPMENT_BUILDS.md)
- [Dependency policy](docs/DEPENDENCIES.md)
- [UI style guide](docs/STYLE_GUIDE.md)
- [Agent guidance](AGENTS.md)

## iPhone app (beta)

An iPhone app is in beta testing through TestFlight and is not yet generally
available. It runs Quick Chat on the phone and works with the sessions on your
own Macs and Linux hosts over your own tailnet. If you're interested in trying
it, email [trey@wovenmatter.com](mailto:trey@wovenmatter.com) with the email
address you'd like to use, and I'll happily add you as a tester.

## Security, license, and trademarks

See the [security policy](SECURITY.md) for how to report a problem. Woven
Matter is [MIT licensed](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md)
and [trademarks](TRADEMARKS.md).
