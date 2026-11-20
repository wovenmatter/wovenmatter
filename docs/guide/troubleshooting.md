# Troubleshooting

| Problem | Start here |
| --- | --- |
| No agent in New Chat | Check the agent in Settings → Agents, or the machine in Settings → Workspaces; install it, then sign in. **Set up harnesses** in Settings → Agents reopens the guided setup. |
| Installed but not ready | Installing and signing in are separate; check the agent's page in Settings → Agents. |
| A folder cannot be created | The machine that will own it must be online. Choose an existing directory with **Link Existing**, or check the error shown. |
| A draft cannot use a folder | Choose a folder on the agent's machine, or **All Workspaces**. After the first message, start a new chat to use another folder. |
| A chat cannot continue | The harness no longer has its session. The chat stays readable; start a new session to go on. |
| Another machine is missing or offline | Confirm Tailscale is connected on both machines and on the same tailnet, and that Woven Matter (on a Mac) or its server (on Linux) is running there. Its chats show their saved messages until it is back. |
| A Linux install fails | Check that this Mac can reach the computer with SSH over Tailscale, that it runs systemd, and that it is x86_64 or arm64. The error says which step failed. |
| Machines stopped syncing | They run different releases. Open Settings → Updates and update the machine that is behind. See [Updates](updates.md). |
| An agent can't use the microphone or other apps on a Mac | Open **Settings → Permissions & Access** on the Mac that runs the chat and choose **Allow**, or **Allow all**. If a row offers **Reopen**, reopen the app after switching the permission on in System Settings. |
| Bots won't start | Check the status in Settings → Bots. On a Mac, the first start sets up the bots' virtual machine, which takes a while. On Linux, run the install command Settings → Bots shows, once, on that computer. See [Bots](bots.md). |
| Linked data is stale | The database's owning machine is offline; linked content shows the last copy until it is back. |
| A database query fails | Ask your agent to fix the query or link. |
| Usage is missing | Check the provider's account in Settings → Subscriptions & API Keys. Missing data does not mean no usage. |

After a connection failure, check the last message before sending it again; the
agent may have received it.

## Get help

For a bug report, include your app version, macOS version, the agent or
harness, which machine the chat runs on, the steps, and the visible error. Use
**Copy diagnostic** when a harness row offers it. Remove credentials and
private content from any logs or screenshots, then open a
[GitHub issue](https://github.com/wovenmatter/wovenmatter/issues) or email
support@wovenmatter.com.

If you have a security issue, email [security@wovenmatter.com](mailto:security@wovenmatter.com).
