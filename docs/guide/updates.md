# Updates

**Settings → Updates** shows the Woven Matter release each of your machines
runs and the harnesses installed on each, and updates them. The first row of
**Settings → General** shows this Mac's version; click it to open the page.

## What the page shows

- **This Mac**: its Woven Matter version and **Check for updates**, which looks
  up the newest release and each harness's newest version. When a newer
  release is out, **Update this Mac** updates Woven Matter on this Mac and
  restarts it, and its server with it.
- **Update everything**, **Update just Woven Matter** and **Update just the
  harnesses**, for all your machines at once.
- **Your machines**: each machine, this Mac first. Open one to update everything
  on it, just Woven Matter (the Woven server on a Linux machine), or a single
  harness. A machine that is offline shows the last version it reported.

## How machines are updated

- **This Mac** updates itself with the release you install from the window
  that opens.
- **A Linux machine** gets the server release this Mac carries. When a newer
  release is out, update this Mac first; then update the Linux machine.
- **Another Mac** is updated from here too. Woven Matter opens there if it is
  closed, downloads the newest release, installs it and relaunches, with
  nothing to click on that Mac. A Mac whose release can't be updated this way
  says so; update it on that Mac once, and from then on it can be.
- **Harnesses** are updated on each online machine.

Two machines on different releases do not sync until they match, so update
them all. Elsewhere in Settings, **Versions don't match** opens this page.

The bots are updated from **Settings → Bots → Manage → Update bots**; see
[Bots](bots.md).

## Before you update

Finish active chats before updating a harness they use. Updating Woven Matter
on a machine restarts its server, which stops the work running there.

Next: [Troubleshooting](troubleshooting.md).
