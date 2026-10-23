# Remote workspaces

Run agents on a Linux machine while using WovenMatter on your Mac. Each
workspace gets a container with its own persistent home, files, installed
harnesses, and credentials. You can create several workspaces on one host.

## What you need

- A reachable amd64 or arm64 Linux host.
- Working OpenSSH configuration and authentication from your Mac.
- Docker Engine, or a supported Ubuntu/Debian host that the app can prepare
  with root access or existing passwordless sudo.
- Enough host disk space for workspace files, harnesses, and caches.

Tailscale is optional. If available, the app can list reachable Tailnet machines;
you can also enter a hostname. The app uses your SSH configuration and agent
rather than maintaining a separate SSH key store.

## Create a workspace

1. Open **Settings → Remote Agent Workspaces** and select or enter a host.
2. Inspect the host and review the result; inspection does not install software.
3. If preparation is offered, review and authorize the listed changes; the app
   verifies the host again before creating the workspace.
4. Create the workspace, then install and authenticate the harnesses you want
   inside it.
5. Choose its agent in **New chat**.

If preparation is blocked, resolve the reported requirement on the host and
inspect again. The app does not remove conflicting container packages or change
your SSH account's Docker group membership for you.

## Browse inside a workspace

Every workspace image includes Chromium, the Playwright CLI, and the Playwright
JavaScript library. Agents can run headless browsing from their shell without
installing packages or downloading a browser.

### See the agent's tabs in Woven Matter

Right-click a remote workspace heading in the sidebar and choose **View browser**,
or open **Settings → Remote Agent Workspaces → Manage → View browser**. Select a
tab to watch its live viewport. **Pause** holds the current image; **Done** closes
the viewer without closing the agent's tabs. Viewing does not send clicks or
keystrokes to the remote page. Images refresh roughly once a second while the
app is active, and are not saved in the library or history.

Agents use the shared workspace browser for tabs you can watch. For example,
run this inside the remote workspace:

```sh
node <<'JS'
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
(async () => {
  const endpoint = execFileSync('woven-browser', ['endpoint'], { encoding: 'utf8' }).trim();
  const browser = await chromium.connectOverCDP(endpoint);
  try {
    const page = await browser.contexts()[0].newPage();
    await page.goto('https://example.com');
    console.log(await page.title());
  } finally {
    await browser.close(); // Disconnect; leave the shared tab open for viewing.
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
```

`woven-browser endpoint` starts the browser on demand or reuses the running one.
`woven-browser tabs` lists its tabs without starting it. Use the existing default
context (`browser.contexts()[0]`) for shared pages. Independent `chromium.launch()`
instances and private contexts are not shown. They remain available for isolated
automation, including `playwright screenshot URL /home/example.png`.

The shared profile, cookies, and site storage stay in the workspace's persistent
home. Open tabs are runtime state and may close on a workspace restart or update.
Each workspace has its own browser; viewing uses the existing authenticated SSH
connection. The browser-control endpoint is container-loopback-only and is never
forwarded to the Mac or published on the host.

CommonJS scripts can use `require("playwright")` from any workspace directory.
ES modules can import from `/usr/local/lib/node_modules/playwright/index.mjs`.
For a different project-installed Playwright version, set `PLAYWRIGHT_BROWSERS_PATH`
to a writable project cache before installing and launching its matching browsers,
or use the embedded version above. Only Chromium is preinstalled; interactive
headed browsing requires a display server.

The matching Playwright browsers live in the image at `/opt/ms-playwright`, so
an existing persistent home cannot hide the browser supplied by an image update.
Use the workspace's **Update** control to apply this support to an existing
workspace. System Chromium also remains available as `chromium`.

This browser runs on the remote host. The agent's **Browser Use** tool controls
the embedded browser on your Mac; use shell commands for browsing within the
remote workspace, including access to its local development servers.

## Manage ongoing work

Use the workspace's controls to start, stop, and update it, maintain its
harnesses, and set resource limits. RAM and additional swap are separate settings. Workspace
storage uses the host's available capacity; it has no fixed per-workspace quota.
A stopped workspace may show storage usage as unavailable.

Closing the Mac app is different from stopping a remote container. Supported
remote scheduling can keep running while the app is closed, provided the host,
container, agent service, and provider access remain available.

Updates preserve the persistent home. When deleting a workspace, read the data
removal choice carefully: deleting that volume removes its files and credentials.

Connections use an authenticated service over an SSH tunnel to a host-loopback
port. For isolation, rollback, storage measurement, and host preparation details,
see the [technical reference](../reference/REMOTE_WORKSPACES.md).
