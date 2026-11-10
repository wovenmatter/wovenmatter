# Scheduled work and usage

## Scheduled Tasks

**Scheduled Tasks** has **Scheduled Tasks** and **Calendar Tasks** tabs.
Use **New task** to choose an agent, execution workspace, folder, model, thinking
level, permissions, tools, prompt, and repeat schedule. Standalone tasks stay off
the calendar by default. Use **Add to calendar**, **Remove from calendar**, or
**Show on calendar** to change where a task appears without changing its runs.

Scheduling belongs to the execution workspace. A remote service can continue
while WovenMatter is closed or the Mac is disconnected; its host and container
must keep running. Remote agents can update their managed databases through
owner-local Woven MCP tools, and the Mac displays the last complete synced data.

## Session timers

With **Timers** enabled, ask an agent to schedule a one-time or recurring follow-up
in its conversation. Timers persist across app restarts, but fire only while
WovenMatter is running. Missed recurring firings coalesce into one follow-up.
Use the session controls to edit, pause, or remove a timer. Disabling Timers asks
you to confirm pausing active timers.

## Calendar

Use **Calendar** for ordinary events and scheduled tasks. Click **Add event**,
choose a day and time, and optionally add a description. Ordinary events can be
all-day or span several days. Click an event to inspect, edit, copy, or delete it.
Copy an event, select another day, then choose **Paste event** to make an
independent copy.

Choose **Scheduled task** to save a prompt with an agent, model, thinking level,
access setting, and enabled tools. Choose a folder owned by the selected
execution workspace, or use its default directory for an ungrouped session.
The folder's root supplies its working directory. Model and session options
come from the selected agent. The agent must be connected to load its available
options and run the task. Normal session permission requests
still apply.

Events and tasks can repeat every chosen number of days, weeks, or months in
their saved time zone. Recurring events have a distinct color and repeat label.
Recurring tasks use the same session by default; choose **New session each
time** for independent conversations. Editing a recurring event offers two
choices: change the **Entire series**, or **Detach this occurrence** into an
independent one-time event. Detaching retains its settings and removes that
occurrence from the series.

Local tasks run in the background server on this Mac, which you can check in
**Settings → Background Server**.
Remote workspaces run their own tasks with background execution enabled by
default; the remote host and workspace service must remain running. Pi Durable may
wait for the Mac to reconnect and unlock credentials after a remote restart.
When execution resumes, every overdue independent task runs, while each recurring
task catches up once.
Tasks wait when their session is busy or the running-session limit is reached;
an unavailable connection is retried. A send whose acceptance cannot be
confirmed is marked for inspection rather than automatically sent again.
Future recurring occurrences continue on their schedule. Unattended remote tasks
that need approval stop for inspection; open their session before continuing.

After a task sends, click its event and choose **Open session**. If a later edit
moves the schedule, the original **Past run** keeps its saved prompt and session
link; choose **View event** to edit the current schedule. Deleting an event or
occurrence removes its calendar entry without deleting its sessions. Each event shows who created it and who
last edited it, including the agent for changes made through Calendar tools.

## Usage

**Usage** has two pages. **Analytics** covers all your history from every linked
device. It needs no account setup or provider switches. OpenCode activity includes
all billing routes; account-wide API activity is excluded from device totals.

Each device reads every supported harness it has run, inside or outside Woven Matter:
Codex (including archived chats and compressed archives), Claude Code, Grok Build,
OpenCode, the Pi CLI, and Pi Durable, which also covers bots and Pi Durable's earlier
session files. Woven Matter keeps its own lasting record, so history stays even after
a harness deletes old transcripts. The first full import can take a few minutes and
runs in the background, newest usage first: the last 24 hours appear within moments,
followed by 7, 30, and 90 days, then the rest.

Each reply counts once. A turn you run in Woven Matter appears right away and is
replaced by the harness's own record of it once that is read. A reply found in more
than one place, such as an archived Codex chat or a Pi Durable session and its backup
file, keeps one record. Older rows saved under **Built-in** show as Pi Durable.

Other Macs, every Linux machine in your library (workspace hosts and bots-only
machines, whichever Mac added them), and iPhones and iPads appear under **Devices**.
Click a device to show or hide its usage. Devices share only token counts, model and
billing labels, session IDs, folder names, and bot names, never prompts, responses, or
file paths. A Linux machine is one device however many Macs added it, and reports all
usage for its account there, including command line runs outside Woven Matter. It
needs a service update in **Settings** before its usage can appear, other Macs need
this version, and a device that can't report says so rather than showing zero.

Use the column on the left to search, choose a time range up to **All**, and narrow by
model, harness, or reasoning level. Click a provider to show or hide it.
**Clear filters** resets everything except the range. The graph shows lines or bars.
Long ranges scroll sideways and open on the latest days; use the arrows below the
graph or scroll to see earlier ones. Hover over the graph for each provider's figures.

Switch the graph from **Tokens** to **API estimate** to see what the same usage would
cost at public API list prices. This is an estimate for comparison, not your bill, and
it applies even when a subscription pays for the usage. Turning it on downloads
[LiteLLM's public price list](https://github.com/BerriAI/litellm) and keeps a copy
for a day. No usage, account, or device data is sent. Models with no known price show
as **Unpriced**. Direct spend from OpenRouter and OpenCode Go stays separate.

**Limits** shows each saved account, its sign-in state, and the limits the provider
makes available. Bars show what is left, and the tick marks where even spending would
be. A bar shorter than its tick means you are ahead of pace. Providers without an
account share one line. Use **Manage subscriptions and keys** to add or manage
accounts in **Settings → Subscriptions & API Keys**. These accounts are shared with Pi Durable. Providers without a
supported limits response link to their usage dashboard; unavailable data is never
shown as zero usage or a full allowance.

Saved keys use Apple Keychain. Allow access under Saved sign-ins in
**Settings → Permissions & Access**.
