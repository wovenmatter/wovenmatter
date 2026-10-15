# Product analytics

This feature uses PostHog Cloud US project 659360. The public project write token
is embedded in the apps and website; it grants event ingestion, not project
administration. The Debug central publisher never transmits to production PostHog.
Client events can still relay to a Release central publisher; use a disposable
library with analytics disabled for development that must stay out of reports. No PostHog SDK,
autocapture, identify/alias/group calls, replay, or person properties are used.

## Identity and activity

`product_analytics_preference` owns one random analytics UUID per central SQLite
library. It survives reopen/restore and is unrelated to operational library,
device, workspace, provider, or account IDs. The central Mac is the only PostHog
publisher. Secondary Mac settings and updater events use the connected library,
including durable launch receipts; their execution workspace has no independent
analytics identity in reports. Secondary Macs, iPhones and iPads submit bounded events through the
existing authenticated, library-bound companion API. Separate libraries count
separately; a shared library counts once. This is a user proxy, not a census of
individual people. Opted-out usage is excluded.

| Event | Qualifies as active | Trigger |
| --- | --- | --- |
| `app_opened` | No | First interface opening in a process, after disclosure |
| `content_changed` | Yes | Explicit human content/folder/database/calendar creation or edit, move, trash, restore, or artifact save |
| `session_created` | Yes | Explicit session creation or locally journaled new-session request |
| `message_submitted` | Yes | Explicit locally accepted/journaled message request, regardless of eventual provider outcome |
| `agent_run_completed` | No | Live central-owner terminal notification, with coarse outcome and duration |
| `update_check_clicked` | No | User clicks Check for updates |
| `update_download_clicked` | No | User clicks Download update or retries it |
| `update_download_completed` | No | A fresh in-app DMG transfer passes size/checksum verification and is saved; cache reuse is excluded |
| `update_download_failed` | No | In-app download fails transfer or verification |
| `update_install_clicked` | No | User clicks Install and restart |
| `update_install_completed` | No | Replacement app launches through the matching updater transaction at the exact target version/build |
| `update_install_failed` | No | Preparation fails or the user cancels before handoff; later helper crashes are not falsely reported as success |

Browsing, opening Settings, autosync, agent content writes, scheduled tasks,
history replay and background imports do not independently qualify. Consecutive
note edits are coalesced to at most one edit event per 30 seconds per process.
Command retries reuse existing journals and do not generate fresh activity.

App opens mean the first interface opening per process, after disclosure, not
page navigation, polling, or background service starts. Open reporting uses the
whole rolling 24-hour, 7-day and 30-day windows up to now, showing both total
open events and distinct opening library IDs. Opens and updater actions never
independently qualify for DAU/WAU/MAU.
Update completion uses a local bounded receipt and stable event UUID. Retries do
not create another installation; the original preference epoch/library must still
allow collection. Opt-out invalidates it. A successful install here means the
replacement version launched, not a guarantee of later application health.
Mac clients without the Software updates controls and App Store updates are not
measured by this in-app updater funnel.

Headline DAU is `COUNT(DISTINCT distinct_id)` for qualifying app events over the
whole rolling 24 hours. WAU and MAU use distinct IDs over the whole rolling 7-day
and 30-day windows respectively, up to now. All timestamps use UTC. Opens use the
same three windows but never qualify as active use. The supplemental historical
activity chart groups events by UTC calendar date and is not the headline DAU. Never sum daily unique counts. Event
UUIDs and original timestamps survive central upload retries. Delayed events are
attributed to their original activity date.

The configured [dashboard](https://us.posthog.com/project/659360/dashboard/2198735)
contains DAU/WAU/MAU, daily activity, opens, feature usage, countries, website
visits/conversions and aggregate GitHub traffic/downloads. App opens and the
in-app update stages have separate reporting definitions, saved alongside DAU/WAU/MAU
and website measurements in [product-dashboard-insights.json](product-dashboard-insights.json). GitHub data is loaded; app and website
data appears after release/deployment. Do not interpret their initial empty state
as an adoption measurement.

## Disclosure, preferences, and privacy

Analytics default to on, but no activity is collected before the local disclosure
and central disclosure acknowledgement. The General Settings choice is library-wide.
Disabling stops local recording immediately, cancels an in-flight central upload,
and discards pending events. An already-transmitted HTTP request cannot be recalled.
Offline changes reach the central library on reconnection; other disconnected
clients receive the setting on their next successful synchronization. Stale opt-in
requests cannot overwrite a newer choice; stale opt-out requests are honored.
Re-enabling advances the preference epoch and collects future activity only.

Central ingestion revalidates timestamps, UUIDs, preference epochs and metadata.
It consumes rejected events so clients do not replay disabled-period activity.
Queues are bounded to 1,000 events, and events older than seven days cannot be
uploaded. Inspectable logs show up to 500 records and the exact pre-enrichment
PostHog event payload. Client logs distinguish central acceptance from PostHog
delivery. Companion telemetry runs separately from content synchronization; slow
or unsupported analytics endpoints do not delay the content lanes. Changes to a library identity discard the old local queue.

Metadata is a strict allowlist: app version, OS major version, platform, coarse
item category/action, known harness/provider categories, bounded outcome, duration,
token range, error category, and a validated semantic target app version. Current hooks emit only available approved fields;
they do not infer provider or token data from strings. Custom model names and
endpoints are omitted. Never add titles, text, content, paths, resource/run/command
IDs, account identifiers, raw exceptions, hostnames or private model labels.

PostHog settings verified on October 11, 2026:

- Discard client IP data: enabled (`anonymize_ips: true`).
- Project timezone: UTC. Autocapture, heatmaps, web vitals and replay: disabled.
- GeoIP transformation replaced with [country-only.hog](country-only.hog).
  Its successful test returned only country code/name and disabled person profiles.
  It removes supplied precise GeoIP/initial GeoIP fields, IPs and person setters.
  A live synthetic validation event separately verified stored country US, no IP,
  city, coordinates or location time zone, and person profiles false. Its source
  is `validation`, so it is excluded from product and acquisition metrics.
- Every app and website event sets `$process_person_profile: false`.

The token-free Privacy and transformation interfaces reverified IP discard and
the active country-only rule on October 12, 2026. Stored GitHub snapshots also
verified `propertyless` person mode, profiles false, qualifying activity false,
and no IP or GeoIP fields. GitHub aggregates disable location enrichment entirely.

Country describes the central publisher network, not each connected device's
physical location. VPNs and proxies can alter it. Do not add a location lookup on
phones or retain more precise geography.

## Website and GitHub acquisition

The companion website PR adds `/privacy` and a small explicit analytics module.
Analytics disclosure and the library-wide opt-in/opt-out controls are in the app;
the website has no analytics preference control. It excludes query strings/fragments and sends only public route,
referrer domain and named download/GitHub-link events. It respects DNT and GPC.
Random browser/session IDs are separate from the app UUID. Development/preview
hosts do not send analytics. Download click/redirect events measure intent,
not installation. Installer DMG counters measure downloads, not unique users. Website and direct
GitHub downloads share the same counter, including repeat/internal downloads and
the in-app updater's network transfers. These totals cannot be split by source or
added to the updater count without double counting. Website clicks/redirects are
intent, not confirmed file transfer; an in-app download completion is verified
locally. Manifest/checksum downloads and other supporting release-file counters
are excluded from collection, archives, publishing and reporting. A website or
GitHub installer download fetches one DMG; supporting files are not downloaded
alongside it. Do not label GitHub download counts as installs or in-app-only
update downloads.

`python3 scripts/collect-github-analytics.py --output PATH/history.json` preserves
GitHub's daily views/clones and cumulative installer DMG counters. Existing rows
outside GitHub's 14-day traffic window remain in the output. Daily download
observations retain asset IDs, including replaced/deleted assets in older snapshots
and assets replaced between reruns on the same UTC day.
Missing dates and historical download deltas are never invented. GitHub daily
uniques cannot be summed to produce weekly/monthly unique people.

`python3 scripts/publish-github-analytics.py --history PATH/history.json` sends
only aggregate snapshots to the existing PostHog project. `--dry-run` reports
pending event counts without transmitting. `POSTHOG_PROJECT_TOKEN` is the public
write token already shipped in the app, not an administrative API credential.
No additional GitHub permission or PostHog administrative secret is needed.

| Event | Aggregate fields |
| --- | --- |
| `github_traffic_snapshot` | UTC reporting day, observation time, views/clones, total and daily unique counts |
| `github_download_snapshot` | Observation day/time, cumulative installer DMG download count, known DMG count |

Both use one repository aggregate ID, `source: github`, profiles false,
qualifying activity false and `$geoip_disable: true`. No GitHub visitor IDs,
locations, release tags or asset filenames are sent to PostHog. App and browser
identities remain independent. Never add these counts to DAU/WAU/MAU or infer
cross-source unique people.

The publisher checkpoints each acknowledged batch in `posthog_accepted`. Failed
batches retry with the same deterministic event UUID. Changed observations produce
new revisions. The collector preserves these checkpoints with the archive.
HTTP acknowledgement means accepted for processing; verify stored events separately.

The dashboard takes the latest observed snapshot per reporting day and traffic
metric, so revisions and retries do not add to totals. Download charts preserve
last known installer counters across replaced/deleted DMGs. Supporting files are
filtered out of older archives during collection and are never published. Installer
download counts are not installs,
unique users or historical daily download deltas. Missing observation days are
not synthesized. The collection-time tile shows freshness. The saved SQL/chart
configurations are in [github-dashboard-insights.json](github-dashboard-insights.json).

The daily `Analytics history` workflow restores the full previous artifact and
uploads a complete successor, so the artifact's 90-day retention does not trim
rows from the history while daily collection continues. Download durable backups
periodically: an outage longer than artifact retention can lose the latest archive.
The workflow fails visibly if its credential or prior archive cannot be read,
including when every prior artifact has expired. It restores only main-branch
archives from this workflow, and never silently starts an empty history. Only a
successful new collection renews the archive, so repeated credential/API failures
do not make stale data appear newly collected.

For the first manual run (or recovery after artifact expiry), pass the **complete**
existing `history.json` as the `bootstrap_history` dispatch input. Preserve the
local bootstrap archive and its PostHog checkpoints; do not substitute a fresh
snapshot, which would lose older traffic and deleted-asset counters. The input is
ignored when a valid retained archive exists. GitHub dispatch payloads are bounded;
if the complete backup exceeds that limit, stop and arrange an artifact-based
migration rather than truncating the backup.
If PostHog publication fails, the complete history and acknowledged checkpoints
are still uploaded as an artifact so the next run can retry.
Artifact access follows repository Actions permissions; only aggregate counts
and public release asset metadata are retained.

`ANALYTICS_GITHUB_TOKEN` has been added to repository Actions secrets. After the
workflow reaches main, run it once manually and verify its traffic permission,
PostHog ingestion and complete artifact before relying on the nightly schedule.
GitHub requires repository **Administration: read** for traffic; the
default workflow token cannot supply it. Use a repository-scoped fine-grained
credential with that read permission. Account authentication and credential setup
must be completed by the human operator; never extract an existing CLI token.
See [GitHub's traffic API permissions](https://docs.github.com/en/rest/metrics/traffic).

## Rollout and acceptance

Keep app PR #115 and website PR #18 separate and based on current main. The
companion architecture from PR #37 is now on main. Review the two PRs together;
no stacked-branch CI exception is needed.

Before shipping app telemetry, deploy the expanded website policy. This change
does not authorize a release, installation, merge or deployment. Verify separately:
first-upgrade disclosure, live Release ingestion with a disposable library,
stored country-only/IP-free event fields and absence of person profiles, two-device
library identity, offline opt-out/reconnection, and no transmission after opt-out.
Provider-free local/CI checks do not replace those named live/device gates.
