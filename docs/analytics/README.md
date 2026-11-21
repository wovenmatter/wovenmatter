# Analytics

## In the app

The app sends no product analytics and has no setting for them. The app-event tiles on the PostHog dashboard show only events from
earlier releases.

`country-only.hog` is the PostHog transformation that drops IP and precise
location fields, keeps only the country, and turns off person profiles.

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
