# Getting started

Woven Matter runs on Apple silicon Macs with macOS 26 or later. Download the
DMG from [GitHub Releases](https://github.com/wovenmatter/wovenmatter/releases/latest),
open it, and move the app into Applications.

No Woven Matter account is required. Start with a harness you already use and
have provider access for. If you already use Codex, for example, choose it for
your first task; the app finds an existing installation. Otherwise, choose a
harness supported by an account or API key you have.

## Set up your first agent

The first time you open the app, the **Set up Woven Matter** window lists the
harnesses already on your Mac and offers to install others. Pi Durable is
included, and the same window can take you to its provider connections. Both
steps are optional. To open the guide again, choose **Set up harnesses** in
**Settings → Agents**.

1. Open **Settings → Workspaces** and check that the local workspace is ready.
2. Choose **New folder** in the sidebar to create a blank project or link an
   existing directory on your Mac.
3. Open **Settings → Agents** and choose a harness. If it is missing, select
   **Install** and review the installer source before confirming.
4. If the harness is not signed in, choose **Sign in** on its page and finish
   the steps shown there. Installed harnesses appear in the sidebar
   automatically.
5. Choose **New chat** or the plus beside your folder, select the agent, and
   check the folder in the composer before sending. The first message fixes
   that chat's folder and working directory.

Installing a harness and signing in are separate steps. A harness that is
installed is not necessarily signed in or ready to send a message. See
[Agent setup](agents.md) if a harness is unavailable.

## Try a small task

Ask your agent to research a question, draft a plan, or summarize a file you
choose. Check the selected agent and folder before sending.
Agent actions use that harness's permissions and your provider account.

You can also create a note without connecting an agent. Organize notes and
conversations in folders as your work grows.

## Add more devices

Woven Matter works on one Mac by itself. When you are ready to add more devices:

- Pair your other Macs in **Settings → Apple Devices**. Each Mac keeps a full
  copy of your library. See [Apple devices](apple-devices.md).
- Add a Linux machine in **Settings → Workspaces** to run agents there. See
  [Remote workspaces](remote-workspaces.md).

Your devices reach each other over your own Tailscale network.

Next: [Conversations](conversations.md) or [Remote workspaces](remote-workspaces.md).
