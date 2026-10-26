# Remote workspaces

Run agents on a Linux machine while using Woven Matter on your Mac. Every remote
workspace runs Woven Matter directly as a native Linux service, using the SSH
account's existing tools and sign-ins. Execution and SQLite state remain on Linux
while the Mac is disconnected.

Remote container workspaces are deprecated and no longer offered or reconnected.
Native Linux hosts replace that workflow. The separate Docker Executor feature
is unchanged.

## What you need

- An online amd64 or arm64 Linux host in your Tailnet.
- Connected Tailscale on both machines, plus working OpenSSH authentication and trusted host keys.
- A regular SSH account, Python 3 and a working systemd user
  manager. Full root access uses that account's existing passwordless sudo.
- Enough host disk space for workspace files, harnesses, and caches.

Tailscale is required for every remote connection. Select an online Tailnet
machine or enter its Tailscale name, MagicDNS name, or Tailscale IP. SSH uses the
local Tailscale daemon for the transport and your existing SSH configuration
and agent for authentication. Arbitrary SSH aliases, LAN addresses, and public
hosts are unsupported. Existing configurations must name an online Tailnet peer;
there is no fallback connection mode.

## Create a workspace

1. Open **Settings → Remote Workspaces** and select or enter a Linux host.
   Choose Full root or Normal user permissions for the whole workspace.
2. Selecting a discovered machine checks it automatically. For a hostname entered
   manually, choose **Inspect host**. Inspection does not install software.
3. If the host needs setup, choose **Prepare host** and authorize the listed
   changes. Native setup installs missing browser dependencies and enables
   background service startup.
   Preparation does not create a workspace.
4. Once that host is ready, the workspace form appears. Give the workspace a name
   and ID, acknowledge the host permission notice where shown, and create it.
   Native hosts reuse existing signed-in tools; install any missing adapters or
   harnesses from setup or Settings. Changing the host, SSH user or access
   choice requires a matching host check.
5. Choose its agent in **New chat**. Installed harnesses appear automatically;
   there is no separate enable or sidebar visibility setting. Complete sign-in
   when required before starting a chat.

Native installation stages a verified service bundle, pinned Node runtime and
Chromium, then proves the browser sandbox works. Failed activation restores the
previous service. Native host workspaces do not require Docker. See
[Native Linux hosts](../reference/REMOTE_HOSTS.md) for permissions and details.

If preparation is blocked, resolve the reported requirement on the host and
inspect again.

## Browse inside a workspace

Native hosts install matching Chromium and Playwright with a verified browser
sandbox. Separate browser profiles keep website logins and storage apart; choose
a profile in the viewer when more than one exists. Agents can pass `profile`
to `woven_browser`. Host browsing is headless and runs directly on Linux.

### See the agent's tabs in Woven Matter

Right-click a remote workspace heading in the sidebar and choose **View browser**,
or open **Settings → Remote Workspaces → Manage → View browser**. Select a
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
connection. The browser-control endpoint is execution-host-loopback-only and is never
forwarded to the Mac or published on the host.

Use `woven_browser` for the shared native browser, including local development
servers on the host. Woven installs the matching browser runtime under its
managed data directory; use **Update server** to refresh that installation.

## Manage ongoing work

Use the workspace's Start, Stop, Restart, Update server and Logs controls to
manage its native service. Workspace storage uses the host's available disk
space. The host operating system controls memory and swap.

Closing the Mac app does not stop the remote service. Supported scheduling keeps
running while the Linux host, agent service and provider access remain available.
Updates preserve the workspace's durable data. Uninstall and removal of workspace
data are separate explicit actions.

Connections use an authenticated service over a Tailscale SSH tunnel to a host
loopback port. See [Native Linux hosts](../reference/REMOTE_HOSTS.md) for
permissions, browser verification, storage and service lifecycle details.
