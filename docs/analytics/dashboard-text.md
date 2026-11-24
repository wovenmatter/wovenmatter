## Measurement definitions
DAU, WAU and MAU count distinct anonymous library IDs with `app_active` signals in whole rolling 24-hour, 7-day and 30-day UTC windows, never summed from daily counts. Each machine sends `app_opened` and `app_active` at most once every six hours, so app opens are sampled, not every launch. Releases 0.4.7 to 0.4.8 sent nothing.

Installer downloads count DMGs from website, direct GitHub and updater traffic, including repeats and internal downloads. Supporting-file downloads are excluded. Website clicks and redirects measure intent. Downloads are not installations or people.

Country comes from the sender's network and can be affected by VPNs. Website browser identities are separate. The collection-time tile shows how fresh the GitHub figures are.

The daily statistics email is a PostHog subscription at 12:00 UTC. GitHub figures use the latest successful collection, shown in the collection-time tile; collection delays do not move the email.
