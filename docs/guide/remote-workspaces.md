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
2. Inspect the host and review the result; inspection does not install software.
3. If preparation is offered, review and authorize the listed changes; the app
   verifies the host again before creating the workspace.
4. Create the workspace, then install and authenticate the harnesses you want
   inside it.
5. Choose its agent in **New chat**.

If preparation is blocked, resolve the reported requirement on the host and
inspect again. The app does not remove conflicting container packages or change
your SSH account's Docker group membership for you.

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
