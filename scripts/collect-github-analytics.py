#!/usr/bin/env python3
"""Preserve aggregate GitHub traffic and installer download counters. Never derives app users."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def collect(history, repository, fetch=api, now=None):
    now = now or datetime.now(timezone.utc).isoformat()
    history = json.loads(json.dumps(history))  # Never partially modify the previous snapshot on API failure.
    if history and (history.get("schema_version") != 1 or history.get("repository") != repository):
        raise ValueError("History belongs to another repository or schema")
    history.setdefault("schema_version", 1)
    history.setdefault("repository", repository)
    traffic = history.setdefault("traffic_days", {})
    for metric in ("views", "clones"):
        response = fetch(f"repos/{repository}/traffic/{metric}?per=day")
        for row in response[metric]:
            day = row["timestamp"][:10]
            traffic.setdefault(day, {})[metric] = {"count": row["count"], "uniques": row["uniques"], "observed_at": now}
    # Older archives may contain supporting release files. Keep installer history only.
    for observation in history.get("download_observations", {}).values():
        observation["assets"] = [asset for asset in observation.get("assets", [])
                                 if str(asset.get("name", "")).lower().endswith(".dmg")]
    assets = []
    page = 1
    while True:
        releases = fetch(f"repos/{repository}/releases?per_page=100&page={page}")
        for release in releases:
            if release["draft"]:
                continue
            for asset in release["assets"]:
                if not asset["name"].lower().endswith(".dmg"):
                    continue
                assets.append({"asset_id": asset["id"], "release": release["tag_name"], "name": asset["name"], "download_count": asset["download_count"]})
        if len(releases) < 100:
            break
        page += 1
    # Daily snapshots retain asset IDs and cumulative counters. Replaced/deleted
    # assets remain in earlier observations; missing days are never synthesized.
    observations = history.setdefault("download_observations", {})
    day = now[:10]
    # A rerun can see a replacement on the same UTC day. Preserve the last known
    # counters for assets that disappeared between observations, too.
    daily_assets = {asset["asset_id"]: asset for asset in observations.get(day, {}).get("assets", [])}
    daily_assets.update({asset["asset_id"]: asset for asset in assets})
    observations[day] = {"observed_at": now, "assets": list(daily_assets.values())}
    history["last_collected_at"] = now
    return history


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="wovenmatter/wovenmatter")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    result = collect(previous, args.repository)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    temporary.replace(args.output)
    print(f"Preserved {len(result['traffic_days'])} traffic days and {len(result['download_observations'])} download observations.")


if __name__ == "__main__":
    main()
