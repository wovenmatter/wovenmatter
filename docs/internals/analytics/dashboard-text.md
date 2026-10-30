## Measurement definitions
Headline DAU, WAU and MAU count distinct central-library IDs with generic app_active signals in the last 24 hours, 7 days and 30 days. Qualifying human creation, editing, session creation or message submission can trigger a signal, at most once per six hours per library. The action type and content are never sent. These are whole rolling windows using UTC timestamps; daily unique counts are never summed. Opens, updates and background work do not qualify. Offline, opted-out and failed-send usage is excluded.

App-open signals have a separate six-hour limit per central library, triggered by opening the interface. Each of the same three rolling windows shows received signals and distinct opening libraries. These sampled signals are not a count of every launch. Daily activity charts show generic activity signals and active libraries by UTC date, without a feature or action breakdown.

Installer downloads count DMGs from website, direct GitHub and updater traffic, including repeats and internal downloads. Supporting-file downloads are excluded. Website clicks and redirects measure intent. In-app update reporting separately shows manual check clicks, download/install starts, completed downloads, verified replacement-app launches and failures. Updater downloads overlap with GitHub totals and are never added to them.

Country reflects the central Mac network and can be affected by VPNs. Website browser identities remain separate. App and website data appears after release/deployment; empty charts are not adoption measurements. The collection-time tile shows GitHub freshness.

Schedule daily statistics emails separately in PostHog for 12:00 UTC. App and website counts use received events. GitHub figures use the latest successful collection, shown in the collection-time tile; collection delays do not determine the email schedule.
