# Updates

**Settings → Updates** shows the Woven Matter version and every installed
harness on this Mac and on your other devices, and updates any or all of them.
The first row of **Settings → General** shows this Mac's version with
**Check for updates** and an **Updates** button that opens the page.

## What the page shows

- **The top row:** this Mac's Woven Matter version and **Check for updates**,
  which looks up the newest release and every harness's newest version. When a
  newer release is out, **Update this Mac** updates the Woven Matter app on this
  Mac, and only that.
- **Your other devices:** every other device and the version it runs.
- **Across your fleet:** the three buttons described below.
- **This Mac:** its Woven Matter version, its bots, and a **Harnesses** row that
  opens to list Pi Durable SDK, Codex, Claude Code, Grok Build, OpenCode, and
  Executor with their versions. **Included with Woven Matter** lists what ships
  inside the app and updates with it: the Chromium browser, Playwright, Node, the
  Cua computer-use driver, the bots VM, and the updater.
- **Bots:** each machine's bots row shows the tools in their containers (Ubuntu,
  Node, and Playwright with Chromium) and how many bots have an update waiting.
  Bots are part of Woven Matter, so they have no version of their own.
- **Each other Mac and Linux machine:** its Woven Matter or Woven server version,
  its bots, and a **Harnesses** row with every harness installed there. A device
  that is offline shows the last version it reported. A device running an older
  Woven Matter shows its harnesses once it's updated.
Anything with a newer version shows **Update available** and its own
**Update** button.

## Update everything at once

- **Update everything everywhere** updates Woven Matter on every device, then
  every harness.
- **Update Woven Matter across your fleet** updates only the apps, the Linux servers, the bots VMs,
  and the bots. A Linux server update also brings its Node, Playwright with
  Chromium, and Docker Engine. Updating bots brings each bot's Node,
  Playwright, Chromium, and Ubuntu packages up to date. Each bot keeps its
  container, files, home folder, browser sign-ins, and everything it installed.
  Each bot is snapshotted first, and a failed update rolls back. When a release
  moves bots to a new container image, what they installed comes along; see
  [what a bot keeps through updates](bots.md#what-a-bot-keeps-through-updates).
- **Update harnesses across your fleet** updates only the harnesses, Pi Durable
  SDKs, and Executor.

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
