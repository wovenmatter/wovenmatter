# Getting started

WovenMatter runs on Apple silicon Macs with macOS 26 or later. Download the
DMG from [GitHub Releases](https://github.com/wovenmatter/wovenmatter/releases/latest),
open it, and move the app into Applications.

No WovenMatter account is required. Start with a harness you already use and
have provider access for. If you already use Codex, for example, choose it for
your first task; the app can discover an existing installation. Otherwise,
choose a harness supported by an account or API key you have.

## Set up your first agent

1. Open **Settings → Local agent workspace** and check that the workspace is
   ready; use **Retry setup** if it is unavailable.
2. Choose **New folder** in the sidebar to create a blank project or link an
   existing directory on your Mac.
3. Choose a runtime under **Runtimes**; if it is missing, select **Install** and
   review the installer source before confirming.
4. Enable the runtime and review the credential-access disclosure when shown.
5. Open its **Settings** to complete the sign-in or connection steps offered
   for that agent.
6. Choose **New chat** or the plus beside your folder, select the agent, and
   check the folder in the composer before sending. The first message fixes
   that chat's folder and working directory.

Installation, enabling, and authentication are separate steps. A downloaded
runtime is not necessarily signed in or ready to send a message. See
[Agent setup](agents.md) if a runtime is unavailable.

## Try a small task

Ask your agent to research a question, draft a plan, or summarize a file you
choose. Check the selected agent and workspace before sending.
Agent actions use that runtime's permissions and your provider account.

You can also create a note without connecting an agent. Organize notes and
conversations in folders as your work grows.

Next: [Conversations](conversations.md) or [Remote workspaces](remote-workspaces.md).
