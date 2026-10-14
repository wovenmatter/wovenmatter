# Troubleshooting

| Problem | Start here |
| --- | --- |
| No agent in New chat | Check the correct workspace's runtime row; install, enable, and show the agent, then complete sign-in or connection setup. |
| Installed but not ready | Installation, transport readiness, and authentication are separate; inspect the agent's Settings. |
| A project folder cannot be created | Connect its owning workspace, choose a valid unused directory name, and check the reported filesystem error. For a local existing project, choose Link Existing. |
| A draft cannot use a folder | Choose a folder owned by the selected agent's execution workspace or Ungrouped. After the first message, start a new chat to use another folder. |
| An earlier chat cannot resume | Sessions from the former workspace layout are archived history. Their messages remain readable; start a new chat for further work. |
| Remote workspace unavailable | Confirm the host is reachable with your existing SSH configuration, then inspect its container and service status. |
| Runtime update blocked | Finish active conversations or stop the relevant service before retrying. |
| OpenCode cannot connect | Check the supported v2 installation and service status; a different OpenCode version may be incompatible. |
| Linked data is stale or offline | Reconnect the owning workspace and refresh Databases. Views use the last complete synced snapshot while the owner is unavailable. |
| A database query or schema link fails | Ask your agent to fix the query or link, and check the size/query limits. Broken links are not automatically repaired. |
| Scheduled output is missing | Check the job, delivery destination, and owning agent service; stopped infrastructure cannot execute jobs. |
| Usage is missing | Enable the provider's usage tracking and check its account access; unknown data does not imply no usage. |

After a connection failure, review the last turn before sending it again; the
agent may have accepted work even if the app did not receive confirmation.

For a bug report, include your app version, macOS version, agent/runtime,
local or remote location, steps, and the visible error. Use **Copy diagnostic**
when a runtime row offers it. Remove credentials and private content from any
extra logs or screenshots before posting a [GitHub issue](https://github.com/wovenmatter/wovenmatter/issues).
Report vulnerabilities through the [security policy](../../SECURITY.md).
