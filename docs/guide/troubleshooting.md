# Troubleshooting

| Problem | Start here |
| --- | --- |
| No agent in New chat | Check the correct workspace's **Runtimes** list. Install the harness if it is missing, then complete sign-in or connection setup. Installed harnesses appear automatically. |
| Installed but not ready | Installation, transport readiness, and authentication are separate; inspect the agent's Settings. |
| A project folder cannot be created | Connect its owning workspace, choose a valid unused directory name, and check the reported filesystem error. For a local existing project, choose Link Existing. |
| A draft cannot use a folder | Choose a folder owned by the selected agent's execution workspace or All Workspaces. After the first message, start a new chat to use another folder. |
| An earlier chat cannot resume | Sessions from the former workspace layout are archived history. Their messages remain readable; start a new chat for further work. |
| Remote workspace unavailable | Confirm Tailscale is connected on both machines and the host is online in your Tailnet. Woven Matter connects through `tailscale nc` to the host's Tailscale address, so `~/.ssh/config` host aliases, `HostName`, `ProxyJump`, and `ProxyCommand` do not apply; a plain `ssh` test that works through them proves nothing. Check SSH key authentication and the trusted host key for the Tailscale name, then use the workspace's **Logs** and service controls. |
| Remote Claude subscription signed out | Claude's sign-in on a Linux host is kept in memory-backed storage and clears when the host reboots. Sign in again from **Settings → Pi Durable** with that workspace selected. |
| Container workspace no longer connects | Container workspaces are deprecated. Create a native Linux host workspace in **Settings → Remote Workspaces**. |
| Runtime update blocked | Finish active conversations or stop the relevant service before retrying. |
| OpenCode cannot connect | Check the supported v2 installation and service status; a different OpenCode version may be incompatible. |
| Linked data is stale or offline | Reconnect the owning workspace and refresh Databases. Views use the last complete synced snapshot while the owner is unavailable. |
| A database query or schema link fails | Ask your agent to fix the query or link, and check the size/query limits. Broken links are not automatically repaired. |
| Scheduled output is missing | Check the job, delivery destination, and owning agent service; stopped infrastructure cannot execute jobs. |
| Usage limits are missing | Usage analytics needs no setup. For limits, add or reconnect the account in **Settings → Usage**. Some providers offer no limits response and link to their own dashboard instead. Unknown data does not mean no usage. |
| An agent tool is unavailable | Check **Tools** in the conversation's composer. Settings defaults apply only to new conversations. See [Agent tools](agent-tools.md). |

After a connection failure, review the last turn before sending it again; the
agent may have accepted work even if the app did not receive confirmation.

For a bug report, include your app version, macOS version, agent/runtime,
local or remote location, steps, and the visible error. Use **Copy diagnostic**
when a runtime row offers it. Remove credentials and private content from any
extra logs or screenshots before posting a [GitHub issue](https://github.com/wovenmatter/wovenmatter/issues).
Report vulnerabilities through the [security policy](../../SECURITY.md).
