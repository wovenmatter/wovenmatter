# Analytics

## In the app

Servers send anonymous usage statistics to PostHog Cloud US
(`server/Sources/WovenServerKit/Analytics.swift`). The UI never talks to
PostHog; it tells its own Mac's server about what only it sees, with
`analytics.record`. There is no SDK, autocapture, person profile or replay.

- **Identity.** One random identifier per library, not tied to any machine,
  session or account ID, so the counts are of libraries, not people. Each
  Mac may write its own candidate, the synced setting
  `analytics.id.<machine>`. The earliest one is the library's, so a Mac that
  joins later and made its own first ends up with the others'. A Mac makes
  one only when its app opens, the statistics are on and the library has
  none. It first waits for its first sync with the other machines, so it
  hears the library's identifier and choice; if that takes over a minute,
  that launch sends nothing. Linux servers never make one. Nothing is sent
  without one.
- **Choice.** On by default. **Settings › General › Privacy** writes the
  synced setting `analytics.enabled`, so it applies to every machine. Each
  server reads it before every send.
- **Only release servers send.** Never a debug build, a development instance
  (`--instance`), or a server without a release version. Tests use a stand-in.
- **Delivery.** One attempt, five-second timeout, at most four at once.
  Nothing is queued or retried.

Every event has `distinct_id`, `source: app`, `platform` (`macos` or
`linux`), `app_version`, `os_major` (Mac only), `qualifying_activity` and
`$process_person_profile: false`. Nothing else is sent: no content, names,
paths, accounts, errors, models, or which action it was.

| Event | Sent by | When |
| --- | --- | --- |
| `app_opened` | Mac | The app opened. |
| `app_active` | Mac or Linux | A deliberate request from a person's UI succeeded: creating a session, sending or answering in one, setting a goal, creating, editing, renaming, moving, trashing or restoring a note, page, sheet or app, dispatching a page task, adding a folder or schedule, saving dictation, or messaging, posting to or creating bots. Reading, browsing, settings and agents' own work never count. `qualifying_activity: true`. |
| `update_check_clicked` | Mac | Update was clicked in Settings › Updates. |
| `update_download_started`, `_completed`, `_failed` | Mac | Sparkle's download steps, with `target_version`. |
| `update_install_started`, `_failed` | Mac | Sparkle began installing, or failed to (not cancelled), with `target_version`. Both happen as the app quits, so they often do not arrive; `update_install_completed` is the reliable end of an update. |
| `update_install_completed` | Mac | The server started on a release other than the one it ran before, however it was installed. It carries `from_version` and `target_version`. |

`app_opened` and `app_active` are each attempted at most once per machine
every six hours. The attempt counts even if delivery fails, so a failure does
not make every later action retry. Six-hour sampling makes DAU approximate at
the window's edge. Several machines of one library can each send within the
same window; distinct-ID counts are unaffected. Each server keeps its own
throttle times and the release it last ran in its library's local
`analytics` table, which never syncs.

`country-only.hog` is the PostHog transformation that drops IP and precise
location fields, keeps only the country, and turns off person profiles.
Country is the sending machine's network, so a Linux server elsewhere can add
a second country for one library.

## GitHub

One daily workflow, `.github/workflows/analytics-history.yml`, collects
repository totals: installer DMG downloads, stars, forks, views and clones. No
GitHub account identities are collected. Stars and forks start with the first
observed snapshot; missing history is not invented. Downloads include repeat,
internal, direct, website and updater transfers, so they are downloads, not
installations or people. Other release files are excluded. GitHub's daily
uniques are not weekly or monthly unique users.

The workflow runs on `main` at **03:17 UTC**, or by hand:

1. `scripts/restore-github-analytics.py` restores the complete previous history
   from the last workflow artifact. It never silently starts over: first setup
   or recovery needs the complete existing JSON backup as the
   `bootstrap_history` input.
2. `scripts/collect-github-analytics.py` adds today's totals, keeping traffic
   older than GitHub's short API window and last-known counts for deleted or
   replaced installers. It needs `ANALYTICS_GITHUB_TOKEN` with repository
   Administration read access for traffic.
3. `scripts/publish-github-analytics.py` publishes aggregate snapshots to
   PostHog with deterministic snapshot IDs, so revisions are not counted twice.
   `--history PATH --dry-run` previews it. The project token it uses allows
   ingestion only.
4. The new history is uploaded as an artifact whenever collection succeeded,
   even if publication failed. Artifacts are kept 90 days, so keep durable
   backups.

## Dashboard and daily email

Saved chart definitions are in `product-dashboard-insights.json` (nine product
and website insights) and `github-dashboard-insights.json` (six GitHub
insights), each with its live short ID. `dashboard-text.md` holds the
dashboard's measurement notes.

The daily email is PostHog's own dashboard subscription for the
product-and-acquisition dashboard (project `659360`, dashboard `2198735`): one
enabled report to the chosen recipient, every day at **12:00 UTC**, with all 15
insights. Keep it in UTC so daylight saving does not move it. GitHub Actions may
delay or skip a scheduled run; the email uses the latest published snapshot and
includes the collection-time tile so its freshness shows. Merging this
repository does not create or change the subscription; set it up in PostHog.

After editing live charts, read back every insight's name, description and
query, update these files to match, and run each saved query to check its
results. Check the report still includes every insight after adding a tile.
Before calling the email set up, check its enabled state, recipient, schedule
and a test delivery record.
