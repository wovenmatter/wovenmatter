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
owner-local Woven Matter CLI tools, and the Mac displays the last complete synced data.

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

Local tasks run while Woven Matter is open, or in its background service when
**Background execution** is enabled in **Settings → Local agent workspace**.
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

**Usage analytics** combines Woven Matter records and local harness activity.
It needs no account setup or provider switches. OpenCode activity includes all
billing routes; account-wide API activity is excluded from device totals.

**Usage limits** shows each saved account, its sign-in state, and the limits the
provider makes available. Use **Go to Usage settings** to add or manage accounts
in **Settings → Usage**. These accounts are shared with Pi Durable. Providers
without a supported limits response link to their usage dashboard; unavailable
data is never shown as zero usage or a full allowance.

Saved keys use Apple Keychain. Enable or restore access in **Settings → General**.
