# Getting started

Woven Matter runs on Apple silicon Macs with macOS 26 or later. An iOS app is
coming soon. Download the
DMG from [GitHub Releases](https://github.com/wovenmatter/wovenmatter/releases/latest),
open it, and move the app into Applications.

No Woven Matter account is required. Start with a harness you already use and
have provider access for. If you already use Codex, for example, choose it for
your first task; the app can discover an existing installation. Otherwise,
choose a harness supported by an account or API key you have.

## Set up your first agent

For the included default agent, open **Settings → Pi Durable** to connect a
provider and choose a model. See [Pi Durable](default-agent.md).

For another harness:

1. Open **Settings → Local Workspace** and check that the workspace is
   ready; use **Retry setup** if it is unavailable.
2. Choose **New folder** in the sidebar to create a blank project or link an
   existing directory on your Mac.
3. Choose a runtime under **Runtimes**; if it is missing, select **Install** and
   review the installer source before confirming.
4. Installed harnesses appear in the sidebar automatically. Use **Sign in…** in setup or local runtime settings to connect a missing native account.
5. Open its **Settings** to complete the sign-in or connection steps offered
   for that agent.
6. Choose **New chat** or the plus beside your folder, select the agent, and
   check the folder in the composer before sending. The first message fixes
   that chat's folder and working directory.

Installation and authentication are separate steps. A downloaded
runtime is not necessarily signed in or ready to send a message. See
[Agent setup](agents.md) if a runtime is unavailable.

## Try a small task

Ask your agent to research a question, draft a plan, or summarize a file you
choose. Check the selected agent and workspace before sending.
Agent actions use that runtime's permissions and your provider account.

You can also create a note without connecting an agent. Organize notes and
conversations in folders as your work grows.

Next: [Conversations](conversations.md) or [Remote workspaces](remote-workspaces.md).
