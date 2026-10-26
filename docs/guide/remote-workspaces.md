# Remote workspaces

Run agents on a Linux machine while using WovenMatter on your Mac. Each
workspace gets a container with its own persistent home, files, installed
harnesses, and credentials. You can create several workspaces on one host.

## What you need

- An online amd64 or arm64 Linux host in your Tailnet.
- Connected Tailscale on both machines, plus working OpenSSH authentication and trusted host keys.
- Docker Engine 28 or newer, or a supported Ubuntu/Debian host that the app can prepare
  with root access or existing passwordless sudo.
- Enough host disk space for workspace files, harnesses, and caches.

Tailscale is required for every remote connection. Select an online Tailnet
machine or enter its Tailscale name, MagicDNS name, or Tailscale IP. SSH uses the
local Tailscale daemon for the transport and your existing SSH configuration
and agent for authentication. Arbitrary SSH aliases, LAN addresses, and public
hosts are unsupported. Existing configurations must name an online Tailnet peer;
there is no fallback connection mode.

## Create a workspace

1. Open **Settings → Remote Agent Workspaces** and select or enter a host.
2. Selecting a discovered machine checks it automatically. For a hostname entered
   manually, choose **Inspect host**. Inspection does not install software.
3. If the host needs setup, choose **Prepare host** and authorize the listed
   changes. The app installs Docker on supported Ubuntu/Debian hosts or starts
   an existing Docker service, then verifies the result. Preparation does not
   create a workspace.
4. Once that host is ready, the workspace form appears. Give the workspace a name
   and ID, create it, then install and authenticate the harnesses you want inside
   it. Changing the hostname or SSH username requires a matching host check.
5. Choose its agent in **New chat**. Installed harnesses appear automatically;
   there is no separate enable or sidebar visibility setting. Complete sign-in
   when required before starting a chat.

The first workspace on a host builds its image and shows each build phase.
Later creations reuse a matching image built within the last 24 hours, skipping
that download and build. Changed or older images rebuild automatically. The
workspace's **Update** action always builds a fresh image.

If preparation is blocked, resolve the reported requirement on the host and
inspect again. The app does not remove conflicting container packages or change
your SSH account's Docker group membership for you. Existing Docker Engine
installations on other Linux distributions, including Arch and Omarchy, work
without host preparation. Inspection identifies the Engine component even when
the distribution omits Docker's display name; an old API, a remote Docker
endpoint, or an unsupported runtime gets its own explanation.

## Browse inside a workspace

Every workspace image includes Chromium, the Playwright CLI, and the Playwright
JavaScript library. Agents can run headless browsing from their shell without
installing packages or downloading a browser.

### See the agent's tabs in Woven Matter

Right-click a remote workspace heading in the sidebar and choose **View browser**,
or open **Settings → Remote Agent Workspaces → Manage → View browser**. Select a
tab to interact with its live page. Click, type, scroll, select text or drag on the
page while the agent keeps the same tab open. Use the address field and Back,
Forward and Reload controls to navigate. Mac shortcuts include Command-A,
Command-C, Command-V and Command-Z; committed text from input methods is sent
to the remote page. **Done** closes the window without closing the agent's tabs.
There is no Pause/Resume control: changes from either participant appear live.

The page is shared, so coordinate in chat when taking over from the agent.
Input is ordered and is discarded if the tab closes or the agent navigates to a
new document before it arrives. Uncertain input is never automatically repeated.
Images refresh while the app is active and are not saved in the library or history.
This controls the remote webpage; OS file pickers and local-file uploads are not
forwarded from the Mac.

Agents use `woven_browser` through the workspace's authenticated Woven MCP
connection to create and control tabs you can watch. Start with an `open` call:

```json
{"action":"open","url":"https://example.com"}
```

Use its returned `tabId` for snapshots, screenshots, navigation, and input. A
`tabs` call lists the shared tabs. These tools use the workspace browser's shared
profile and default context; the same pages appear in **View browser**. The
browser-control endpoint remains private to the execution service and is not
exposed as a model argument or a shell helper.

Agents can still use the bundled Playwright library for isolated headless
browsing. Independent `chromium.launch()` instances and private contexts are not
shown in the shared viewer. For example, `playwright screenshot URL
/home/example.png` uses a separate browser instance.

The shared profile, cookies, and site storage stay in the workspace's persistent
home. Open tabs are runtime state and may close on a workspace restart or update.
The live image stream captures changed pages at up to about 60 updates per second
and keeps the latest image when the connection is slow. Static pages do not run
a repeated screenshot loop. Input is sent immediately, with queued gestures
batched in order. Closing the viewer stops image capture and leaves agent tabs
open. See [performance validation](../reference/REMOTE_BROWSER_PERFORMANCE.md)
for measurements and limits.

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

Connections use an authenticated service over an SSH tunnel carried exclusively
by Tailscale to a host-loopback port. Run **Update container** for existing
workspaces to apply the private network and image hardening before starting them. For isolation, rollback, storage measurement, and host preparation details,
see the [technical reference](../reference/REMOTE_WORKSPACES.md).
