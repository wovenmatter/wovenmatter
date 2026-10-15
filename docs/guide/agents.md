# Agent setup

WovenMatter has dedicated integrations for Pi Durable, Codex, Claude Code,
Grok Build, and OpenCode. Use your existing installations or
install harnesses in the settings page. Use your existing provider accounts
and/or API keys; models, authentication, and controls depend on the harness.

A **harness** is the software that runs the agent. Settings also calls it a
**runtime**. A **provider** supplies the model and account access.

## Set up a harness

1. Open **Settings → Local Agent Workspace**, or select a workspace under
   **Remote Agent Workspaces**.
2. Find the harness under **Runtimes**. If it is missing, select **Install**
   and review the installer before confirming.
3. Enable the harness and complete its sign-in or connection setup.
4. Choose **New chat** and select the agent in that workspace.

Start with a harness you already use and have provider access for. WovenMatter
can discover supported installations and account access. Installation, enabling,
and authentication are separate steps; completing one does not complete the others.
A remote workspace has its own installations and credentials.

## Harness settings

Open the harness's **Settings** for its connection and maintenance controls.
OpenCode includes model selection and server controls; configure its provider
accounts through OpenCode.

OpenCode uses stable v2 releases. Use the app's installation flow to
get a compatible version. Stopping a shared service can affect other clients
using that service.

## Updates and visibility

Use **Check for updates** or **Update** in the runtime row. A check reports
available updates without installing them. Finish active work before updating;
a busy runtime may block maintenance. Remote updates apply to the selected workspace.

**Hide** controls sidebar visibility. **Disable** turns off the integration
without uninstalling the software or deleting its data. For OpenCode, disabling
disconnects WovenMatter while leaving the shared server running; use **Stop server**
to stop it.

For adapter details, component versions, and update behavior, see
[Runtime installation and updates](../RUNTIME_MAINTENANCE.md).

## Goals

Goals keep a chat working toward an outcome across turns. They are available for
Pi Durable, Codex, Claude Code, Grok Build and OpenCode. Goals belong to the
chat’s execution owner: the Mac, an independent Linux workspace, or on-device
Pi Durable on iPhone/iPad. Controls on other clients route to that owner; goals
continue there when an observing client disconnects. On iOS, continuation runs
while the operating system grants execution time. An interrupted device goal
pauses and requires explicit resume. Archived chats remain read-only.

Goals are always available; there is no tool toggle to enable or disable them.
Tell the agent to set a goal, send `/goal` to ask it to establish an objective
from the current conversation, or send `/goal` followed by the outcome and how
to verify it. Each chat has one goal. Use `/goal show` to ask the agent for its
current status. These commands ask the agent to use the goal tools.

Once a goal exists, the compact bar above the composer shows its status and
elapsed pursuit time. Paused intervals do not count toward that time. Use
**Expand goal** to read the objective and progress details, **Pause** or **Resume**
to control pursuit, and **Delete** to remove the goal. Include an optional
token or turn budget when asking the agent to establish a goal.

Use `/goal pause`, `/goal resume`, or `/goal clear` to request those actions
through the agent. **Stop** pauses the goal before stopping the current run.
Goals also pause when the execution service restarts and require an explicit
resume afterward.

The agent marks a goal achieved only after verifying it. A stalled goal retains
its explanation so you can resolve the blocker and resume. After each automatic
turn, the agent must report new progress or completion; checking status alone
does not keep the goal running. Budgets are checked between turns; reaching a
budget does not mark the goal achieved. If token usage is unavailable, a token
budget prevents further continuation. A turn budget is available when you want
to limit iterations instead.

Normal messages retain their priority. A goal waits for active work, questions,
approvals and queued inputs before beginning another turn. Plan mode does not
start automatic goal work.
