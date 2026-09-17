# Scheduled work and usage

## Cron Jobs

**Cron Jobs** brings supported Hermes and OpenClaw schedules into the app.
Connect the relevant agent in Settings first. Available editing and run controls
differ between the integrations.

Choose whether results stay in the job history, start a new chat for each result,
or arrive in an existing conversation for that agent. Hermes creates new jobs
paused so you can choose delivery before resuming them. **Continue in chat**
opens a draft for review; sending it is a separate action.

Scheduling belongs to the agent service. A remote service can continue while
Woven Matter is closed, but it cannot run on a stopped host or container. Local
work depends on the Mac and the relevant service staying available. Hermes
result delivery currently supports text; if another Hermes Gateway owns the
scheduler, its operator must restart it after first enabling delivery.

## Calendar

Use **Calendar** to add and view workspace events. A calendar event is separate
from a Cron Job; adding an event does not schedule an agent run.

## Usage

**Usage** shows recorded activity and supported provider usage. Configure account
access under **Settings → Usage**. Some information comes from local activity,
and some requires a provider account check; unavailable data is not zero usage.

Review the credential-access disclosure before enabling account checks. OpenRouter
keys saved through these settings use the Mac's Keychain; Cursor usage can read
its local account session after you enable that tracking.

Treat this view as an aid to understanding your work; provider records remain
the place to confirm billing and account limits.
