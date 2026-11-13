# Troubleshooting

| Problem | Start here |
| --- | --- |
| No agent in New chat | Check the agent in Settings → Agents or the remote workspace in Settings → Workspaces; install it, then complete sign-in or connection setup. **Set up harnesses** in Settings → Agents reopens the guided setup. |
| Installed but not ready | Installation, transport readiness, and sign-in are separate; inspect the agent's page in Settings → Agents. |
| A project folder cannot be created | Connect its owning workspace, choose a valid unused directory name, and check the reported filesystem error. For a local existing project, choose Link Existing. |
| A draft cannot use a folder | Choose a folder owned by the selected agent's workspace or All Workspaces. After the first message, start a new chat to use another folder. |
| An earlier chat cannot resume | Sessions from the former workspace layout are archived history. Their messages remain readable; start a new chat for further work. |
| Remote workspace unavailable | Its chats show their saved history, marked offline, and go live again on their own when the host is back. Confirm Tailscale is connected on both machines, then check the host's status and logs from its **Manage** menu in Settings → Workspaces. |
| An agent can't use files, the microphone, or other apps on a Mac | Open **Settings → Permissions & Access** on the Mac that runs the session and choose **Allow** on each item that is not allowed yet, or **Allow all**. Full Disk Access, Accessibility, and Screen Recording are switched on in System Settings; if a row offers **Reopen**, reopen the app after switching it on. |
| Saved keys or website passwords are unavailable | Allow **Keychain** in Settings → Permissions & Access. |
| A Mac can't be found or paired | In Settings → Apple Devices, **Find devices** lists only Macs on your Tailscale network; an offline Mac needs Tailscale connected. If pairing asks to update, update both Macs to the current version. A pairing link must be current; create a new one on the other Mac. See [Apple devices](apple-devices.md). |
| "Versions don't match" or library sync stopped | Your devices run different versions, and they synchronize only when their libraries match. Choose **Update everything** in Settings → Bots, or update the app or host that is behind. |
| Bots won't start | Check the machine's status in Settings → Bots. On a Mac, the first start downloads and sets up the bots VM, which takes a while; if the VM failed, turn bots off and on to try again. Bots on a Mac need Apple silicon. Installing bots on Linux needs the SSH account's passwordless sudo once. See [Bots](bots.md). |
| Runtime update blocked | Finish active conversations or stop the relevant service before retrying. |
| OpenCode cannot connect | Check the supported v2 installation and service status; a different OpenCode version may be incompatible. |
| Linked data is stale or offline | Reconnect the owning workspace and refresh Databases. Views use the last complete synced snapshot while the owner is unavailable. |
| A database query or schema link fails | Ask your agent to fix the query or link, and check the size/query limits. Broken links are not automatically repaired. |
| Scheduled output is missing | Check the job, delivery destination, and owning agent service; stopped infrastructure cannot execute jobs. |
| Usage is missing | Enable the provider's usage tracking and check its account access; unknown data does not imply no usage. |

After a connection failure, review the last turn before sending it again; the
agent may have accepted work even if the app did not receive confirmation.

## Get help

For a bug report, include your app version, macOS version, agent or harness,
local or remote location, steps, and the visible error. Use **Copy diagnostic**
when a harness row offers it. Remove credentials and private content from any
extra logs or screenshots, then open a
[GitHub issue](https://github.com/wovenmatter/wovenmatter/issues) or email
support@wovenmatter.com.

If you have a security issue, email [security@wovenmatter.com](mailto:security@wovenmatter.com).
