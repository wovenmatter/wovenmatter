# Updates

**Settings → Updates** shows the Woven Matter version and every installed
harness on this Mac and on your other devices, and updates any or all of them.
The first row of **Settings → General** shows this Mac's Woven Matter version;
click it to open the page.

## What the page shows

- **The top row:** this Mac's Woven Matter version and **Check for updates**,
  which looks up the newest release and every harness's newest version. When a
  newer release is out, **Update this Mac** updates just the Woven Matter app
  on this Mac.
- **Three rows for all your devices at once,** described below.
- **Your devices:** each device by its name on your tailnet, this Mac first,
  then your other Macs, then your remote workspaces. Each shows its Woven
  Matter or Woven server version, and **Bots** on the device that runs your
  bots. **Update** on a device updates everything on it. Open a device to see
  and update one part:
  - its Woven Matter or Woven server
  - its bots, showing the tools in their containers (Ubuntu, Node, and
    Playwright with Chromium). Bots are part of Woven Matter, so they have no
    version of their own.
  - each harness (Pi Durable SDK, Codex, Claude Code, Grok Build, OpenCode,
    and Executor) with its versions
  - on this Mac, **Included with Woven Matter**: what ships inside the app and
    updates with it (the Chromium browser, Playwright, Node, the Cua
    computer-use driver, the bots VM, and the updater)

  A device that is offline shows the last version it reported. A device running
  an older Woven Matter shows its harnesses once it's updated.

## Update all your devices at once

- **Update everything across all of your devices** updates Woven Matter on every device, then every
  harness.
- **Update just the Woven Matter apps across your devices** updates only the apps, the Linux servers, the bots VMs,
  and the bots. A Linux server update also brings its Node, Playwright with
  Chromium, and Docker Engine. Updating bots brings each bot's Node,
  Playwright, Chromium, and Ubuntu packages up to date. Each bot keeps its
  container, files, home folder, browser sign-ins, and everything it installed.
  Each bot is snapshotted first, and a failed update rolls back. When a release
  moves bots to a new container image, what they installed comes along; see
  [what a bot keeps through updates](bots.md#what-a-bot-keeps-through-updates).
- **Update just the harnesses across your devices** updates only the
  harnesses, Pi Durable SDKs, and Executor.

Devices update one at a time: Linux servers, then your other Macs, then each
machine's bots. A Linux server gets the server release that comes with this
Mac's Woven Matter. So when a newer release is out, this Mac updates first. Install it
in the window that opens. After Woven Matter restarts, the update carries on
with your other devices and harnesses.

Before a Linux workspace runs a harness installer, Woven Matter lists every
download in the update with its source and checksum. You confirm them once.
Each host downloads its source again and refuses to run it if it changed.

## When something is running

Updating a harness can't replace it while a chat is using it, and this Mac
restarts to update. If an update would interrupt chats or a running OpenCode
server, or move bots to a new container image, Woven Matter names them first. **Update now** stops them and updates;
**Cancel** leaves everything as it is. Another Mac reports its running chats
when its harness update starts; Woven Matter then names them and asks the same
way.

Next: [Apple devices](apple-devices.md) or [Troubleshooting](troubleshooting.md).
