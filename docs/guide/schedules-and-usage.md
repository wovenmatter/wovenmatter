# Scheduled work and usage

## Scheduled Tasks

**Scheduled Tasks** has four tabs: **Scheduled Tasks**, **Calendar Tasks**, **Hermes**,
and **OpenClaw**. Use **New task** in the first two tabs to choose the same agent,
workspace, folder, model, thinking level, permissions, tools, prompt, and repeat
schedule available in Calendar. Standalone tasks stay off the calendar by default.
Use **Add to calendar**, **Remove from calendar**, or **Show on calendar** in the
editor to change where a task appears without changing its runs or session.

The **Hermes** and **OpenClaw** tabs manage their agent-service schedules.
Connect the relevant agent in Settings first. Available editing and run controls
differ between the integrations.

Choose whether results stay in the job history, start a new chat for each result,
or arrive in an existing conversation for that agent. Hermes creates new jobs
paused so you can choose delivery before resuming them. **Continue in chat**
opens a draft for review; sending it is a separate action.

Scheduling belongs to the agent service. A remote service can continue while
WovenMatter is closed, but it cannot run on a stopped host or container. Local
work depends on the Mac and the relevant service staying available. Hermes
result delivery supports text; if another Hermes Gateway owns the
scheduler, its operator must restart it after first enabling delivery.

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
access setting, and enabled tools. Choose the session's folder (or **All
Workspace**), local or remote workspace, and working directory. Model and
session options come from the selected agent. The agent must be connected to
load its available options and run the task. Normal session permission requests
still apply.

Events and tasks can repeat every chosen number of days, weeks, or months in
their saved time zone. Recurring events have a distinct color and repeat label.
Recurring tasks use the same session by default; choose **New session each
time** for independent conversations. Editing a recurring event offers two
choices: change the **Entire series**, or **Detach this occurrence** into an
independent one-time event. Detaching retains its settings and removes that
occurrence from the series.

Calendar tasks run while Woven Matter is open. When the app returns, every
overdue independent task runs, while each recurring task catches up once.
Tasks wait when their session is busy or the running-session limit is reached;
an unavailable connection is retried. A send whose acceptance cannot be
confirmed is marked for inspection rather than automatically sent again.
Future recurring occurrences continue on their schedule. These app-owned
tasks are separate from the **Hermes** and **OpenClaw** agent-service schedules.

After a task sends, click its event and choose **Open session**. If a later edit
moves the schedule, the original **Past run** keeps its saved prompt and session
link; choose **View event** to edit the current schedule. Deleting an event or
occurrence removes its calendar entry without deleting its sessions. Each event shows who created it and who
last edited it, including the agent for changes made through Calendar tools.

## Usage

**Usage** shows recorded activity and supported provider usage. Configure account
access under **Settings → Usage**. Some information comes from local activity,
and some requires a provider account check; unavailable data is not zero usage.

Review the credential-access disclosure before enabling account checks. OpenRouter
keys saved through these settings use the Mac's Keychain; Cursor usage can read
its local account session after you enable that tracking.

Use this view to follow usage across your work. Check provider records to
confirm billing and account limits.
