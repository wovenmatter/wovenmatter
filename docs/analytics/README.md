# Product analytics

The central Mac sends explicit events to PostHog Cloud US. One random analytics
ID belongs to the central library and is shared by its connected devices. It is
independent of operational device, workspace, provider, and account IDs. Separate
libraries count separately; these are active-library estimates, not identified
people. There is no analytics SDK, autocapture, person profile, or session replay.

## Six-hour signals

- `app_opened`: opening the interface (or foregrounding the mobile app) can send a signal.
- `app_active`: a deliberate content change, session creation, or message submission
  can send one generic activity signal. The action type is not recorded or sent.

Each signal has its own rolling six-hour limit, enforced by the central library
across all devices and restarts. A qualifying action at 9 am can send immediately;
more activity is suppressed until 3 pm. Nothing fires at 3 pm: another qualifying
action is required. Opens never consume the activity allowance, or vice versa.
Browsing, background synchronization, agent writes/outcomes, scheduled work, and
imports do not qualify. There are no per-feature or per-action usage counters.

DAU/WAU/MAU count distinct library IDs with `app_active` signals in the whole
rolling 24-hour/7-day/30-day UTC windows. Do not sum daily unique counts. Six-hour
sampling makes these approximate, especially at the daily window boundary.
App-open charts count sampled open signals, not every launch. Offline, opted-out,
and failed-send usage is excluded from all reports.

## Delivery and preferences

Signals are attempted immediately. There is no 30-second publisher, persistent
event queue, retry loop, or offline replay. Each request has a five-second timeout;
concurrent sends are bounded, and excess events are dropped. Six-hour timestamps
limit attempts as well as successful signals, so a failure does not cause every
subsequent edit to retry. Future eligible actions can make a new attempt.
Companion sends do not block content synchronization or user actions.

Privacy choices still persist and synchronize. Analytics default to on, with the toggle and explanation in General settings;
there is no launch disclosure or acknowledgement step. Opt-out stops local collection and
cancels outstanding requests; an already-sent request cannot be recalled. Offline
opt-out reaches other devices on reconnection. Old opt-ins cannot override newer
choices. Re-enabling collects only future activity, without resetting signal limits.

The toggle and policy link are at the bottom of General settings on Mac, iPhone,
and iPad. The policy lives at [wovenmatter.com/privacy](https://wovenmatter.com/privacy).
There is no user-facing analytics log. The central library retains bounded
receipts solely to deduplicate attempts, never for delivery. Companion acceptance
means the central library accepted the attempt, not that PostHog received it.

Only platform, app version, OS major version, and updater target version are
allowlisted. No action categories, agent outcomes, content, titles, messages,
files, paths, account identifiers, arbitrary errors, or model labels are sent.
The country-only transform in `country-only.hog` removes IP and precise location
fields and disables person profiles. Country describes the central Mac's network.
Verify that transform and IP discard in the live project before shipping.
Debug central builds never transmit to production PostHog.

## Updates

Updater metrics remain separate: manual check clicks, download/install starts,
completed downloads, installation failures, and verified replacement-app launches.
Lifecycle callbacks are starts, not button clicks. Older clients' `update_download_clicked`
and `update_install_clicked` events remain decodable and are grouped with the
corresponding started stages in the report. Expected installation cancellation is
not a failure, and telemetry never delays backend recovery.

A local install receipt is saved before installation can terminate the app,
including install-on-quit without Sparkle's optional relaunch callback. It verifies
the matching replacement version and build after restart; it is consumed on its
first reporting attempt, including failure. The library preference is rechecked
before delivery. It is not an analytics delivery backlog. Opt-out invalidates it.
Update stages never qualify for DAU/WAU/MAU and are never added to GitHub downloads.

## GitHub

One daily workflow collects repository totals: installer DMG downloads, stars,
forks, views, and clones. No GitHub account identities are collected. Stars/forks
start with the first observed snapshot; missing historical values are not invented.
Downloads include repeat, internal, direct, website, and updater transfers. They
are downloads, not installations or unique people. Supporting release files are
excluded from reporting. GitHub daily uniques are not weekly/monthly unique users.

`collect-github-analytics.py` preserves existing history, including traffic outside
GitHub's short API window and last-known counters for deleted/replaced installers.
`publish-github-analytics.py --history PATH --dry-run` previews aggregate publication.
The repository publisher retains deterministic snapshot IDs and acknowledgement
checkpoints to avoid double-counting revisions. This aggregate history is separate
from app telemetry and is intentionally preserved. Saved chart definitions live
in `product-dashboard-insights.json` (nine product/website insights) and
`github-dashboard-insights.json` (six GitHub insights). `dashboard-text.md` contains
the matching measurement notes. All insights include their live short IDs.

The daily workflow restores the complete previous main-branch workflow artifact
and archives a complete successor. It never silently starts over. First setup or
recovery requires the complete existing JSON backup as `bootstrap_history`.
Keep durable backups: Actions artifact retention is 90 days. Collection failure
must not renew stale history. Publication failure still preserves the new archive.
`ANALYTICS_GITHUB_TOKEN` requires repository Administration read permission for
traffic. The embedded PostHog token grants ingestion only, not administration.

## Daily email report

Use PostHog's native dashboard email subscription for the product-and-acquisition
dashboard (project `659360`, dashboard `2198735`). Configure one enabled report
for the account's chosen email recipient, every day at **12:00 UTC**, including
all 15 saved insights. Keep the timezone UTC so daylight saving does not shift
the reporting time. An AI summary is optional and is not required for statistics.
This is a scheduled report, independent of the account's billing plan.

The GitHub collector is scheduled at **03:17 UTC** to leave time before the noon
report. GitHub Actions may delay or skip scheduled runs; the email uses the latest
successfully published snapshot and includes the collection-time insight so its
freshness is visible. App and website events arrive independently. The email is
a statistics report, not a claim that a particular collection job succeeded.
Saving a dashboard definition or merging this repository does not create a
PostHog email subscription; configure and verify that separately in PostHog.

After editing live charts, read back every insight's name, description and full
query and synchronize these JSON files and measurement notes. Execute each saved
query to verify results; do not infer success from saving metadata. Check that the
report still includes all 15 insights after adding a tile. Before calling email
setup complete, verify its enabled state, recipient, daily UTC schedule, and a
test delivery record. A successful send record does not prove inbox receipt.

## Testing and rollout

Use existing repository validation and disposable local probes. No live provider
calls are needed for source tests. Before shipping, verify the public policy,
Release ingestion and stored country-only/IP-free metadata, two-device throttling,
offline dropping, opt-out/reconnection, and a signed updater round trip. Debug
checks cannot establish those live outcomes. After merge, initialize the history
workflow from the complete preserved backup and verify its first successor archive.
