# Woven Matter

Woven Matter is one workspace for all of your coding agents. Run Pi Durable,
Codex, Claude Code, Grok Build, and OpenCode side by side in a single Mac app.

Any Mac or Linux machine on your Tailscale network (tailnet) can be a Woven
Matter host: a host for your agents, the host for your bots, or both. All of
them share one synced library, and you manage every one of them from the Mac
app. There is no Woven Matter account and no hosted service in between.

[Download for Mac](https://github.com/wovenmatter/wovenmatter/releases/latest) ·
[Getting started](docs/guide/getting-started.md) ·
[Documentation](docs/README.md)

## What you can do

- **Run every harness from your Mac.** Pi Durable is built in. Codex, Claude
  Code, Grok Build, and OpenCode use the installations and provider accounts
  you already have, or Settings installs them. Pi Durable can also use local
  model servers on your network. Run as many sessions at once as you like,
  across harnesses, and choose the model for each one.
- **Run bots.** Bots are long-running agents that keep their own files,
  memory, browser sign-ins, and services between conversations. Hand them
  ongoing work: watching a project, running a dev server, or coming back to a
  task on a timer. Your bots run together on one machine you choose (this
  Mac, another Mac, or a Linux host), each in its own isolated Linux
  container. Admin Bot creates and organizes the rest, and bots can work in
  teams with a manager that hands out the work.
- **Connect all of your machines.** Run Woven Matter on as many Macs and Linux
  machines on your tailnet as you want. Each one can host agents, your bots,
  or both. They all work at the same time, and you manage all of them from
  the Mac app. A session on another machine opens just like a local one.
- **Keep one library everywhere.** Every host keeps a full copy of your
  conversations, notes, calendar, and files, and syncs it with the others.
  **Library** collects the files, links, and photos exchanged in your
  conversations.
- **Drive it all with Woven MCP.** Every agent on every host gets Woven MCP.
  With it, agents start, message, and check on sessions on any of your
  machines, and work with your notes, calendar, history, library, timers, and
  browser. Bots get their own Woven MCP keys, which you can revoke per bot.
- **Keep your work beside the chat.** Open Notes, Sheets, Artifacts, Pages,
  browser tabs, and document previews next to a conversation and work on them
  with the agent. Pages are flowing documents you and your agents edit together,
  on a Mac, iPhone, or iPad. Notes keep a version history you can restore from.
- **Give agents a browser and your desktop.** Browser Use drives a built-in
  Chromium browser. Computer Use operates Mac apps after you grant access in
  Settings.
- **Schedule work.** Create scheduled tasks, put them on the calendar, and let
  agents set timers and follow-ups in their own conversations.
- **See what you use.** Usage shows tokens and estimated cost across harnesses
  and machines, plus each provider account's current limits.
- **Talk instead of type.** Dictation uses Apple's on-device speech
  recognition, so your voice stays on your Mac.
- **Connect other apps.** Agents can use MCP servers and APIs through the
  built-in Executor runtime, with approvals in the conversation.

## Requirements

- **Mac app:** an Apple silicon Mac with macOS 26 or later. The app updates
  itself.
- **Linux hosts (optional):** amd64 or arm64 machines on your tailnet with
  OpenSSH, Python 3, and a systemd user manager. You set them up from the Mac
  app.
- **Tailscale (only for more than one machine):** a single Mac needs nothing
  else. To use more machines, put each one on your tailnet.
- **Provider access** for the harnesses you use: a subscription account or an
  API key.

## How it fits together

| Machine | Role |
| --- | --- |
| Mac | The full interface. A background server holds a library copy, runs agents, serves Woven MCP, and runs your bots if you choose this Mac for them. Closing the window leaves that server running. |
| Linux host | Headless. One Woven server hosts agents, your bots, or both, along with a library copy and Woven MCP. The Mac app installs and updates it over Tailscale SSH. |

You can have as many Macs and Linux hosts as you want, and they all work in
parallel. Every host is an equal member with a complete library: any of them
can be offline, and the rest keep working.

### Devices and pairing

- Every device has its own long-lived signing key: in the Keychain on a Mac,
  and in a `0600` file on Linux. The member list is a signed record set that
  syncs to every device.
- Macs pair with each other in **Settings → Apple Devices**, by link or nearby
  request. Linux hosts are added from any Mac in **Settings → Workspaces**.
- Every request between devices is signed with the caller's device key and
  travels directly over tailnet HTTPS (`*.ts.net`).
- Removing a device is a signed revocation. It takes effect on each device as
  soon as that device syncs.

### Library

- Every Mac and Linux host keeps a full copy of the library in SQLite: notes,
  conversations, calendar, artifacts, and files.
- Sync is peer-to-peer between every online host. It runs on changes, not on a
  timer, and a host catches up when it comes back online. Conflicting edits
  are kept as conflict copies.
- Hosts must run matching versions to sync. When versions differ, each one
  shows which part needs updating and offers **Update everything**.

### Sessions across machines

- A session on another machine opens in the same conversation view as a local
  one. While it is open, its live state (the streaming reply, questions,
  approvals, and settings) and your commands travel on that machine's stream,
  a WebSocket signed with the device key. Nothing polls.
- Sessions you don't have open reach every device through library sync, so a
  machine that is offline still shows its saved history, marked offline.
- Through Woven MCP, an agent on any host can create, message, inspect, stop,
  and answer sessions on any other host. The request goes straight to that
  host.

### Bots

- All of your bots run on one machine at a time, chosen in **Settings →
  Bots**. A Node runtime there runs every bot's agent loop on Pi Durable, and
  each bot's tools run inside its own Ubuntu container.
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
- **Find devices** in Settings → Bots lists the Macs and Linux machines on
  your tailnet and what each one needs before it can run your bots.

## Documentation

- [User guides and references](docs/README.md)
- [Woven everywhere](docs/architecture/WOVEN_EVERYWHERE.md): devices, membership, library sync, sessions, and bots

## iPhone app (beta)

An iPhone app is in beta testing through TestFlight and is not yet generally
available. It runs Quick Chat on the phone and works with the sessions on your
own Macs and Linux hosts over your own tailnet. If you're interested in trying
it, email [trey@wovenmatter.com](mailto:trey@wovenmatter.com) with the email
address you'd like to use, and I'll happily add you as a tester.

## Security, license, and trademarks

If you have a security issue, email
[security@wovenmatter.com](mailto:security@wovenmatter.com). Woven Matter is
[MIT licensed](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md)
and [trademarks](TRADEMARKS.md). To work on Woven Matter itself, see
[Contributing](CONTRIBUTING.md).
