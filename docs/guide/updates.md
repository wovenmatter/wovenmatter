# Updates

**Settings → Updates** shows the Woven Matter version and every installed
harness on this Mac and on your other devices, and updates any or all of them.
**Settings → General** shows this Mac's version with its own **Check for
updates**, and an **Updates** row that opens the page.

## What the page shows

- **This Mac:** its Woven Matter version, its bots, and a **Harnesses** row that
  opens to list Pi Durable SDK, Codex, Claude Code, Grok Build, OpenCode, and
  Executor with their versions. **Included with Woven Matter** lists what ships
  inside the app and updates with it: the Chromium browser, Playwright, Node, the
  Cua computer-use driver, the bots VM, and the updater.
- **Bots:** each machine's bots row shows the tools in their containers (Ubuntu,
  Node, and Playwright with Chromium) and how many bots are still on an older
  container image.
- **Each other Mac and Linux machine:** its Woven Matter or Woven server version,
  its bots, and a **Harnesses** row with every harness installed there. A device
  that is offline shows the last version it reported. A device running an older
  Woven Matter shows its harnesses once it's updated.
- **Check now** looks up the newest release and every harness's newest version.

Anything with a newer version shows **Update available** and its own
**Update** button.

## Update everything at once

- **Update everything** updates Woven Matter on every device, then every
  harness.
- **Update Woven Matter** updates only the apps, the Linux servers, the bots VMs,
  and the bots. A Linux server update also brings its Node, Playwright with
  Chromium, and Docker Engine. Updating bots moves every bot to the current
  container image. Its files in `/workspace` stay, each bot is snapshotted
  first, and a failed update rolls back.
- **Update harnesses** updates only the harnesses, Pi Durable SDKs, and
  Executor.

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
