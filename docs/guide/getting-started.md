# Getting started

Woven Matter runs on Apple silicon Macs with macOS 26 or later. Download the
DMG from [GitHub Releases](https://github.com/wovenmatter/wovenmatter/releases/latest),
open it, and move the app into Applications.

No Woven Matter account is required. Start with a harness you already use and
have provider access for. If you already use Codex, for example, choose it for
your first task; the app finds an existing installation.

## Set up your first agent

The first time you open the app, the **Set up Woven Matter** window lists the
harnesses already on your Mac and offers to install others. Pi Durable is
included, and the same window can take you to its provider sign-ins. Both steps are
optional. To open it again, choose **Set up harnesses** in **Settings →
Agents**.

1. Open **Settings → Agents** and choose a harness. If it is missing, choose
   **Install**. Woven Matter runs the vendor's official installer, so the same
   CLI works in Terminal.
2. If the harness is not signed in, choose **Sign in** on its page and follow
   the steps shown there. Installed harnesses appear in the sidebar on their
   own.
3. Optionally choose **New Folder** in the sidebar to create a project or link
   an existing directory. See [Folders and storage](workspaces.md).
4. Choose **New Chat** or the plus beside a folder, choose the agent, and check
   the folder in the composer before sending.

Installing a harness and signing in are separate steps. See
[Agent setup](agents.md) if a harness is unavailable.

## Try a small task

Ask your agent to research a question, draft a plan, or summarize a file you
choose. Agent actions use that harness's permissions and your provider account.

You can also write notes and pages without an agent. Keep them in folders
beside your chats as your work grows.

## Add more machines

Woven Matter works on one Mac by itself. Any other Mac or Linux computer on
your Tailscale network that runs Woven Matter joins your machines by itself,
and Woven Matter can install its server on a Linux computer for you over SSH.
See [Your machines](machines.md).

Next: [Conversations](conversations.md).
