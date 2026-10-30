#!/usr/bin/env python3
"""Development profiles and consistent, disconnected library snapshots."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid


def choose_mode(root):
    """Default to the complete, independent app; clients are explicit opt-in."""
    return "snapshot"


def profile(root, instance, mode):
    root = root.resolve()
    instance = instance or (re.sub(r"[^a-z0-9-]", "-", root.parent.name.lower())[:40].strip("-") or "dev") + "-" + hashlib.sha256(os.fsencode(root)).hexdigest()[:10]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", instance):
        raise ValueError("Use a lowercase instance name of up to 64 letters, digits, and hyphens.")
    selected = choose_mode(root) if mode == "auto" else mode
    support = Path.home() / "Library/Application Support"
    support = support / "Woven Matter" if selected == "live" else support / "Woven Matter Dev" / instance / selected
    return dict(instance=instance, mode=selected,
                support=str(support),
                product=f"Woven Matter {instance} {selected} Dev",
                bundle=f"wovenmatter.desktop.dev.{instance}.{selected}")


def backend_running(executable, commands=None):
    """Compare executable identities, including macOS /tmp -> /private/tmp aliases."""
    if commands is None:
        found = subprocess.run(["pgrep", "-u", str(os.getuid()), "-f", " --backend$"],
                               capture_output=True, text=True)
        if found.returncode == 1:
            return False
        found.check_returncode()
        identifiers = found.stdout.split()
        if not identifiers or not all(value.isdigit() for value in identifiers):
            raise ValueError("Could not inspect the development backend processes.")
        processes = subprocess.run(["ps", "-p", ",".join(identifiers), "-o", "command="],
                                   capture_output=True, text=True)
        if processes.returncode == 1 and not processes.stdout.strip():
            return False  # The matched processes exited between the two reads.
        processes.check_returncode()
        commands = processes.stdout.splitlines()
    expected = executable.resolve()
    suffix = " --backend"
    return any(command.strip().endswith(suffix)
               and Path(command.strip()[:-len(suffix)]).resolve() == expected
               for command in commands)


def backup(source, destination):
    # SQLite's online backup includes committed WAL data without stopping the host.
    with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=10) as reader:
        with sqlite3.connect(destination) as writer:
            deadline = time.monotonic() + 60
            def progress(status, remaining, total):
                if time.monotonic() > deadline:
                    raise TimeoutError("The source remained busy; snapshot was not installed.")
            reader.backup(writer, pages=256, progress=progress, sleep=0.05)
            if writer.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("Snapshot integrity check failed.")


def copy_assets(source, target):
    if not source.exists():
        return
    if source.is_symlink():
        raise ValueError(f"Snapshot assets must not be symlinks: {source}")
    if source.is_dir():
        target.mkdir()
        for child in source.iterdir():
            if child.name.endswith(("-wal", "-shm")):
                continue
            copy_assets(child, target / child.name)
    elif source.is_file():
        with source.open("rb") as stream:
            is_sqlite = stream.read(16) == b"SQLite format 3\x00"
        if is_sqlite:
            backup(source, target)
        else:
            shutil.copy2(source, target)
    else:
        raise ValueError(f"Unsupported snapshot asset: {source}")


def disconnect_snapshot(file, *, device_id, execution_root, published_root):
    """Keep ownership/history; disable copied execution and isolate test projects."""
    with sqlite3.connect(file) as db:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        # Preserve triggers verbatim, but avoid firing application-specific SQLite
        # functions while clearing copied runtime metadata in the private copy.
        triggers = list(db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger'"))
        quote = lambda name: '"' + name.replace('"', '""') + '"'
        for name, _ in triggers:
            db.execute("DROP TRIGGER " + quote(name))
        source_device = (db.execute("SELECT device_id FROM desktop_local_identity WHERE singleton=1").fetchone()
                         if "desktop_local_identity" in tables else None)
        # Ownership is durable metadata. Availability is a separate history state;
        # copied conversations never acquire authority to resume against production.
        if "dashboard_conversations" in tables:
            columns = {r[1] for r in db.execute("PRAGMA table_info(dashboard_conversations)")}
            if {"desktop_owned", "is_archived"} <= columns:
                db.execute("CREATE TABLE IF NOT EXISTS retained_execution_history(conversation_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id) ON DELETE CASCADE)")
                db.execute("INSERT OR IGNORE INTO retained_execution_history SELECT id FROM dashboard_conversations WHERE desktop_owned=1 AND is_archived=0")
                db.execute("UPDATE dashboard_conversations SET is_archived=1 WHERE id IN (SELECT conversation_id FROM retained_execution_history)")
        if source_device and "folder_execution_roots" in tables:
            # Each source-local project keeps its folder identity and relationship,
            # with a new owner and blank directory inside this disposable instance.
            owner = "device:" + device_id
            for (folder_id,) in db.execute("SELECT folder_id FROM folder_execution_roots WHERE workspace_id=?", ("device:" + source_device[0],)).fetchall():
                directory = execution_root / str(uuid.UUID(folder_id))
                directory.mkdir(parents=True)
                db.execute("UPDATE folder_execution_roots SET workspace_id=?,root_path=?,managed=1,reference_paths='[]' WHERE folder_id=?",
                           (owner, str(published_root / str(uuid.UUID(folder_id))), folder_id))
        transient = {"desktop_local_identity", "desktop_local_acp_sessions", "desktop_local_acp_durable_runs",
                     "desktop_opencode_sessions", "desktop_opencode_submissions", "desktop_openclaw_gateway_links",
                     "desktop_openclaw_gateway_sessions", "desktop_openclaw_cron_jobs", "desktop_openclaw_cron_runs",
                     "desktop_scheduled_result_routes", "desktop_scheduled_result_receipts"}
        retained_content = {"companion_versions", "companion_changes", "companion_execution_workspaces",
                            "companion_execution_conversations", "companion_execution_runs", "companion_native_history",
                            "companion_native_history_parts", "companion_saved_artifacts", "companion_artifact_chunks",
                            "companion_message_provenance"}
        for name in tables:
            if name in transient or (name.startswith("companion_") and name not in retained_content):
                db.execute("DELETE FROM " + quote(name))
        # A new device identity seeds its own local harness catalog at startup.
        # Keep copied agent rows for history references, but retire them from the
        # active catalog so they cannot appear as duplicate runnable harnesses.
        if "dashboard_agents" in tables:
            db.execute("""UPDATE dashboard_agents
                SET deleted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), status='offline'
                WHERE governing_plane='wovenmatter_macos' AND authority_kind='device_owned'
                  AND runtime_device_id IS NULL AND deleted_at IS NULL""")
        # A snapshot is a new library. Keep materialized foreign history, but
        # discard the old synchronization stream and all routes to its owners.
        library_id = str(uuid.uuid4())
        if "companion_workspace" in tables:
            db.execute("INSERT INTO companion_workspace(singleton,workspace_id) VALUES(1,?)", (library_id,))
        for table, column in (("companion_execution_workspaces", "payload"),
                              ("companion_execution_conversations", "conversation")):
            if table not in tables:
                continue
            for identifier, raw in db.execute("SELECT id," + column + " FROM " + table).fetchall():
                value = json.loads(raw)
                value["libraryID"] = library_id
                if table == "companion_execution_workspaces":
                    value.pop("endpoint", None)
                    value["retainedHistory"] = True
                else:
                    value.pop("activeRunID", None)
                db.execute("UPDATE " + table + " SET " + column + "=? WHERE id=?",
                           (json.dumps(value).encode(), identifier))
        if "dashboard_runs" in tables:
            db.execute("UPDATE dashboard_runs SET status='interrupted' WHERE status IN ('running','queued','pending','accepted','cancelling','uncertain')")
        for name in ("workspace_session_deliveries", "workspace_calendar_runs"):
            if name in tables:
                db.execute("UPDATE " + quote(name) + " SET status='cancelled' WHERE status IN ('queued','pending','sending','running','accepted')")
        # Network exposure belongs to the source instance, not a new snapshot.
        # Keep tool selections, but require an explicit enable in this instance.
        if "workspace_tool_settings" in tables:
            for identifier, raw in db.execute("SELECT id,value FROM workspace_tool_settings").fetchall():
                value = json.loads(raw)
                if value.get("externalMCP"):
                    value["externalMCP"]["isEnabled"] = False
                    db.execute("UPDATE workspace_tool_settings SET value=? WHERE id=?", (json.dumps(value), identifier))
        if "workspace_session_timers" in tables:
            db.execute("UPDATE workspace_session_timers SET is_paused=1,pending_delivery_id=NULL")
        # Retain task definitions with an unreachable owner. New schedules use
        # this instance; copied occurrences cannot be admitted by its scheduler.
        if "dashboard_calendar_items" in tables:
            db.execute("CREATE TABLE IF NOT EXISTS companion_calendar_owners(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, tools_json TEXT)")
            db.execute("INSERT OR REPLACE INTO companion_calendar_owners(event_id,device_id) SELECT id,? FROM dashboard_calendar_items", (str(uuid.uuid4()),))
        # Retain goal history without scheduling a continuation from the copy.
        for name in tables:
            if name.startswith("workspace_goal"):
                columns = {r[1] for r in db.execute("PRAGMA table_info(" + quote(name) + ")")}
                if "status" in columns:
                    db.execute("UPDATE " + quote(name) + " SET status='paused' WHERE status='active'")
        if "workspace_session_goals" in tables:
            for session, raw in db.execute("SELECT session_id,value FROM workspace_session_goals").fetchall():
                value = json.loads(raw)
                if value.get("status") == "active":
                    value["status"] = "paused"; value["pendingDeliveryID"] = None
                    db.execute("UPDATE workspace_session_goals SET value=? WHERE session_id=?", (json.dumps(value), session))
        for _, sql in triggers:
            db.execute(sql)
        if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise ValueError("Disconnected snapshot failed its integrity check.")


def snapshot(source, destination):
    source = source.expanduser().resolve(strict=True)
    destination = destination.expanduser().resolve()
    if destination.exists():
        raise ValueError("Snapshot already exists. Use another instance name to take a fresh snapshot.")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Source and snapshot directories must be separate.")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = Path(tempfile.mkdtemp(prefix=".snapshot-", dir=destination.parent))
    try:
        backup(source / "workspace.sqlite", temporary / "workspace.sqlite")
        for name in ("library-files", "message-attachments", "ManagedDatabases"):
            copy_assets(source / name, temporary / name)
        catalog = temporary / "ManagedDatabases/catalog.json"
        if catalog.exists():
            rows = json.loads(catalog.read_text())
            for row in rows:
                identifier = str(uuid.UUID(row["id"]))
                row["url"] = (destination / "ManagedDatabases" / (identifier + ".sqlite")).as_uri()
                row["owner"] = "snapshot-history"
            catalog.write_text(json.dumps(rows))
        device_id = str(uuid.uuid4())
        execution_root = temporary / "ExecutionHome" / ".woven-matter"
        disconnect_snapshot(temporary / "workspace.sqlite", device_id=device_id, execution_root=execution_root,
                            published_root=destination / "ExecutionHome" / ".woven-matter")
        (temporary / "dashboard-device-id").write_text(device_id)
        (temporary / "dashboard-device-id").chmod(0o600)
        (temporary / "development-snapshot.json").write_text(json.dumps({"version": 1, "id": str(uuid.uuid4()), "source": str(source), "createdAt": time.time()}))
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("profile")
    plan.add_argument("--root", type=Path, required=True)
    plan.add_argument("--instance")
    plan.add_argument("--mode", choices=("auto", "client", "snapshot", "live"), default="auto")
    snap = sub.add_parser("snapshot")
    snap.add_argument("--source", type=Path, required=True)
    snap.add_argument("--destination", type=Path, required=True)
    running = sub.add_parser("backend-running")
    running.add_argument("--executable", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "profile":
        print(json.dumps(profile(args.root, args.instance, args.mode)))
    elif args.command == "snapshot":
        snapshot(args.source, args.destination)
    else:
        print("true" if backend_running(args.executable) else "false")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TimeoutError, sqlite3.Error, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
