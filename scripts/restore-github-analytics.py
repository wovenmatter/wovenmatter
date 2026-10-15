#!/usr/bin/env python3
"""Restore complete analytics history, failing closed instead of resetting counters."""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import zipfile


def api(path):
    return subprocess.check_output(["gh", "api", path])


def restore(repository, fetch=api, bootstrap=None):
    artifacts = []
    page = 1
    while True:
        response = json.loads(fetch(f"repos/{repository}/actions/artifacts?name=analytics-history&per_page=100&page={page}"))
        rows = response["artifacts"]
        artifacts.extend(row for row in rows if row["name"] == "analytics-history"
                         and not row["expired"] and row.get("workflow_run", {}).get("head_branch") == "main")
        if len(rows) < 100:
            break
        page += 1
    history = None
    for artifact in sorted(artifacts, key=lambda row: row["id"], reverse=True):
        run = json.loads(fetch(f"repos/{repository}/actions/runs/{artifact['workflow_run']['id']}"))
        if (run.get("path") != ".github/workflows/analytics-history.yml"
                or run.get("event") not in ("schedule", "workflow_dispatch")
                or run.get("head_repository", {}).get("full_name") != repository):
            continue
        # An unreadable newest archive is an error, never permission to fall
        # back to an older, incomplete history or to overwrite it with a seed.
        with zipfile.ZipFile(io.BytesIO(fetch(f"repos/{repository}/actions/artifacts/{artifact['id']}/zip"))) as archive:
            history = json.loads(archive.read("history.json"))
        break
    if history is None:
        if not bootstrap:
            raise ValueError("No retained analytics history. Restore a complete backup through the bootstrap_history input; refusing to reset history.")
        history = json.loads(bootstrap)
    if (history.get("schema_version") != 1 or history.get("repository") != repository
            or not isinstance(history.get("traffic_days"), dict)
            or not isinstance(history.get("download_observations"), dict)
            or not history["download_observations"]):
        raise ValueError("Invalid or incomplete analytics history backup")
    return history


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    history = restore(args.repository, bootstrap=os.environ.get("ANALYTICS_BOOTSTRAP_HISTORY"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(history, indent=2, sort_keys=True) + "\n")
    print("Restored complete analytics history.")


if __name__ == "__main__":
    main()
