#!/usr/bin/env python3
"""Publish aggregate GitHub history to PostHog without creating person profiles."""
import argparse
from datetime import date, datetime
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request
import uuid

ENDPOINT = "https://us.i.posthog.com/batch/"


def counter(value):
    if type(value) is not int or value < 0:
        raise ValueError("GitHub counters must be nonnegative integers")
    return value


def snapshot(repository, name, report_day, observed_at, properties):
    date.fromisoformat(report_day)
    observed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    if observed.tzinfo is None:
        raise ValueError("Snapshot timestamps must include a timezone")
    event = {
        "event": name,
        "timestamp": observed_at,
        "properties": {
            "distinct_id": "github-repository:" + repository,
            "source": "github",
            "repository": repository,
            "qualifying_activity": False,
            "$process_person_profile": False,
            "$geoip_disable": True,
            "report_day": report_day,
            "observed_at": observed_at,
            **properties,
        },
    }
    canonical = json.dumps(event, sort_keys=True, separators=(",", ":"))
    event["uuid"] = str(uuid.uuid5(uuid.NAMESPACE_URL, canonical))
    return event


def pending_snapshots(history):
    repository = history["repository"]
    if history.get("schema_version") != 1 or not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Unsupported GitHub history repository or schema")
    accepted = history.get("posthog_accepted", {})
    pending = []

    def add(key, event):
        if accepted.get(key) != event["uuid"]:
            pending.append((key, event))

    for day, metrics in sorted(history.get("traffic_days", {}).items()):
        for metric in ("views", "clones"):
            if metric not in metrics:
                continue
            row = metrics[metric]
            event = snapshot(repository, "github_traffic_snapshot", day, row["observed_at"], {
                "traffic_metric": metric,
                "total_count": counter(row["count"]),
                "daily_unique_count": counter(row["uniques"]),
            })
            add("traffic:" + day + ":" + metric, event)

    for day, row in sorted(history.get("repository_observations", {}).items()):
        add("repository:" + day, snapshot(repository, "github_repository_snapshot", day, row["observed_at"], {
            "stars": counter(row["stars"]), "forks": counter(row["forks"]),
        }))

    # Retain the last known counter for replaced/deleted assets. Filenames and
    # release tags stay in the archive; only the aggregate counters leave it.
    known_assets = {}
    for day, observation in sorted(history.get("download_observations", {}).items()):
        for asset in observation["assets"]:
            if not str(asset.get("name", "")).lower().endswith(".dmg"):
                continue
            asset_id = counter(asset["asset_id"])
            known_assets[asset_id] = counter(asset["download_count"])
        event = snapshot(repository, "github_download_snapshot", day, observation["observed_at"], {
            "cumulative_dmg_downloads": sum(known_assets.values()),
            "known_dmg_assets": len(known_assets),
        })
        add("downloads:" + day, event)
    return pending


def send_batch(payload):
    request = urllib.request.Request(ENDPOINT, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError("PostHog did not accept the batch")


def publish(history, project_token, send=send_batch, persist=lambda _: None, batch_size=100):
    if not project_token or not 1 <= batch_size <= 500:
        raise ValueError("A project ingestion token and batch size 1–500 are required")
    pending = pending_snapshots(history)
    accepted = history.setdefault("posthog_accepted", {})
    for start in range(0, len(pending), batch_size):
        batch = pending[start:start + batch_size]
        send({"api_key": project_token, "historical_migration": True,
              "batch": [event for _, event in batch]})
        for key, event in batch:
            accepted[key] = event["uuid"]
        # Save each acknowledged batch. A failed request stays eligible for retry
        # with the same UUID; the archive never depends on PostHog availability.
        persist(history)
    return len(pending)


def save(path, history):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(history, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    history = json.loads(args.history.read_text())
    if args.dry_run:
        pending = pending_snapshots(history)
        print(json.dumps({"pending_events": len(pending), "dry_run": True}))
        return
    try:
        total = publish(history, os.environ.get("POSTHOG_PROJECT_TOKEN", ""),
                        persist=lambda value: save(args.history, value))
    except urllib.error.HTTPError as error:
        raise SystemExit(f"PostHog publication failed: HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("PostHog publication failed: network error; archive retained for retry") from None
    print(f"PostHog accepted {total} aggregate GitHub snapshots.")


if __name__ == "__main__":
    main()
