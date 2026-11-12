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


def profile(root, instance, mode):
    root = root.resolve()
    instance = instance or (re.sub(r"[^a-z0-9-]", "-", root.parent.name.lower())[:40].strip("-") or "dev") + "-" + hashlib.sha256(os.fsencode(root)).hexdigest()[:10]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", instance):
        raise ValueError("Use a lowercase instance name of up to 64 letters, digits, and hyphens.")
    # Auto defaults to the complete, independent app; clients are explicit opt-in.
    selected = "snapshot" if mode == "auto" else mode
    support = Path.home() / "Library/Application Support"
    support = support / "Woven Matter" if selected == "live" else support / "Woven Matter Dev" / instance / selected
    return dict(instance=instance, mode=selected,
                support=str(support),
                product=f"Woven Matter {instance} {selected} Dev",
                bundle=f"wovenmatter.desktop.dev.{instance}.{selected}")


LINUX_LIBRARY_ARCHITECTURES = ("x86_64", "aarch64")


def missing_linux_libraries(root):
    """Architectures whose wovenmatter-library this checkout's host bundle lacks.

    Every Linux host holds a library copy, so a host bundle must carry the binary for
    the host's architecture: the packed one scripts/build-linux-library.sh writes, or a
    plain binary kept for local runs."""
    missing = []
    for arch in LINUX_LIBRARY_ARCHITECTURES:
        directory = Path(root) / "remote/host/library" / ("linux-" + arch)
        packed = (directory / "wovenmatter-library.gz").is_file() and (directory / "wovenmatter-library.sha256").is_file()
        if not packed and not (directory / "wovenmatter-library").is_file():
            missing.append(arch)
    return missing


def ensure_linux_library(root, *, environ=None, which=shutil.which, run=subprocess.run):
    """Builds the missing Linux library hosts with Docker (the pinned image, through
    scripts/build-linux-library.sh), or stops with how to build them. Returns the
    architectures that are still missing (only when skipping was asked for)."""
    environ = os.environ if environ is None else environ
    missing = missing_linux_libraries(root)
    if not missing:
        return []
    names = " and ".join(missing)
    if environ.get("WOVENMATTER_DEV_LINUX_LIBRARY") == "skip":
        print(f"Building without the Linux library host for {names}: this build will refuse to install or update Linux hosts of that architecture.")
        return missing
    docker = which("docker")
    try:
        ready = bool(docker) and run([docker, "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        ready = False
    if not ready:
        raise SystemExit(
            f"This checkout has no Linux library host for {names} (remote/host/library/), so Linux hosts this build installs "
            "could hold no library copy and never join your devices. Start Docker and run this again to build it, or build it "
            "with scripts/build-linux-library.sh. To build the app without it (it then refuses Linux installs), set "
            "WOVENMATTER_DEV_LINUX_LIBRARY=skip.")
    print(f"Building the Linux library host for {names} with Docker (scripts/build-linux-library.sh)…", flush=True)
    command = [str(Path(root) / "scripts/build-linux-library.sh"), "--docker"]
    # One container builds every architecture; name it only when one is missing.
    if len(missing) == 1:
        command += ["--arch", missing[0]]
    run(command, check=True)
    still = missing_linux_libraries(root)
    if still:
        raise SystemExit("scripts/build-linux-library.sh finished without the library host for " + " and ".join(still) + ".")
    return []


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


# Libraries from before November 2026 used these names. The app renames them
# in place on open (LegacyCompanionStorage.swift); a snapshot of such a library
# is renamed the same way first, so its isolation below sees current names.
LEGACY_TABLES = {
    "companion_library_identity": "library_identity", "companion_versions": "device_sync_revisions",
    "companion_changes": "device_sync_changes", "companion_mutation_receipts": "device_mutation_receipts",
    "companion_command_receipts": "device_command_receipts", "companion_draft_receipts": "device_draft_receipts",
    "companion_tool_receipts": "device_tool_receipts", "companion_workspace_mcp_grants": "device_workspace_mcp_grants",
    "companion_workspace_publishers": "device_workspace_publishers",
    "companion_scheduled_mcp_callers": "device_scheduled_mcp_callers",
    "companion_message_provenance": "device_message_provenance", "companion_saved_artifacts": "device_saved_artifacts",
    "companion_artifact_uploads": "device_artifact_uploads", "companion_artifact_chunks": "device_artifact_chunks",
    "companion_execution_workspaces": "execution_workspaces", "companion_execution_journal": "execution_journal",
    "companion_execution_conversations": "execution_conversations",
    "companion_execution_adoptions": "execution_adoptions", "companion_execution_runs": "execution_runs",
    "companion_execution_receipts": "execution_receipts",
    "companion_execution_replica_context": "execution_replica_context",
    "companion_retained_settlements": "execution_retained_settlements",
    "companion_native_history": "execution_native_history",
    "companion_native_history_parts": "execution_native_history_parts",
    "companion_calendar_owners": "calendar_task_executors", "companion_calendar_run_owners": "calendar_run_publishers",
    "companion_calendar_runs": "calendar_published_runs", "companion_calendar_receipts": "device_calendar_receipts",
    "companion_calendar_execution_context": "calendar_replica_context",
    "companion_calendar_execution_conflicts": "calendar_execution_conflicts",
}


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
        # Old-named triggers are not restored: the app recreates every trigger
        # under its current name.
        triggers = [(name, sql) for name, sql in triggers if "companion_" not in name and "companion_" not in (sql or "")]
        for old, new in LEGACY_TABLES.items():
            if old in tables:
                db.execute(("DROP TABLE " + quote(old)) if new in tables else ("ALTER TABLE " + quote(old) + " RENAME TO " + quote(new)))
                tables.discard(old); tables.add(new)
        tables.discard("companion_workspace")
        db.execute("DROP TABLE IF EXISTS companion_workspace")
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
        # State the library keeps about devices and execution belongs to the
        # source instance: its identity and library ID, receipts, journals,
        # uploads, grants, schedule executors and replica roles. What devices
        # produced (revisions, changes, projected history, artifacts) is kept.
        source_state = {"library_identity", "device_mutation_receipts", "device_command_receipts",
                        "device_draft_receipts", "device_tool_receipts", "device_workspace_publishers",
                        "device_workspace_mcp_grants", "device_scheduled_mcp_callers", "execution_journal",
                        "execution_adoptions", "execution_receipts", "execution_replica_context",
                        "execution_retained_settlements", "device_artifact_uploads", "calendar_task_executors",
                        "calendar_run_publishers", "calendar_published_runs", "device_calendar_receipts",
                        "calendar_replica_context", "calendar_execution_conflicts"}
        # Execution ownership is durable metadata, not sync state. Keep it so a
        # snapshot's new identity owns nothing it copied and never runs another
        # Mac's (or the source's) schedules; drop routes, cursors and journals.
        retained_paired = {"paired_conversation_owners", "paired_agent_owners", "paired_calendar_owners", "paired_library_state"}
        for name in tables:
            if name in transient or (name.startswith("paired_") and name not in retained_paired) or name in source_state:
                db.execute("DELETE FROM " + quote(name))
        if "paired_library_state" in tables:
            db.execute("DELETE FROM paired_library_state WHERE name<>'owners.bootstrap'")
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
        if "library_identity" in tables:
            if "library_id" not in {r[1] for r in db.execute("PRAGMA table_info(library_identity)")}:
                db.execute("ALTER TABLE library_identity ADD COLUMN library_id TEXT")
            db.execute("INSERT INTO library_identity(singleton,host_device_id,library_id) VALUES(1,?,?)",
                       (str(uuid.uuid4()), library_id))
        for table, column in (("execution_workspaces", "payload"),
                              ("execution_conversations", "conversation")):
            if table not in tables:
                continue
            for identifier, raw in db.execute("SELECT id," + column + " FROM " + table).fetchall():
                value = json.loads(raw)
                value["libraryID"] = library_id
                if table == "execution_workspaces":
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
        if "workspace_mcp_bot_machines" in tables:
            db.execute("UPDATE workspace_mcp_bot_machines SET active=0")
        if "workspace_session_relationships" in tables:
            db.execute("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id LIKE 'woven:bot:%'")
        if "workspace_session_grants" in tables:
            db.execute("DELETE FROM workspace_session_grants WHERE source_id LIKE 'woven:bot:%'")
        if "workspace_coordination_access_requests" in tables:
            db.execute("UPDATE workspace_coordination_access_requests SET state='cancelled' WHERE source_id LIKE 'woven:bot:%' AND state='pending'")
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
            db.execute("CREATE TABLE IF NOT EXISTS calendar_task_executors(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, tools_json TEXT)")
            db.execute("INSERT OR REPLACE INTO calendar_task_executors(event_id,device_id) SELECT id,? FROM dashboard_calendar_items", (str(uuid.uuid4()),))
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
        (temporary / "mcp-access.json").unlink(missing_ok=True)
        (temporary / "dashboard-device-id").write_text(device_id)
        (temporary / "dashboard-device-id").chmod(0o600)
        (temporary / "development-snapshot.json").write_text(json.dumps({"version": 1, "id": str(uuid.uuid4()), "source": str(source), "createdAt": time.time()}))
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def keychain_services(bundle):
    """Keychain service names one Dev instance owns: its bundle ID's, and the Woven Matter
    service namespace derived from it (WovenMatterKeychainService). Exact name or a dotted child."""
    if not bundle.startswith("wovenmatter.desktop.dev."):
        raise ValueError("Only a Dev instance's Keychain items can be reset.")
    return (bundle, "Woven Matter." + bundle[len("wovenmatter."):])


def owned_service(service, roots):
    return any(service == root or service.startswith(root + ".") for root in roots)


def reset(support, bundle, *, dev_root=None, trash=None, run=subprocess.run, now=time.time):
    """Clears one snapshot instance so the next launch takes a fresh snapshot under the same
    bundle ID, which keeps the privacy permissions macOS ties to it. The data folder (bots and
    their VM included) moves to the Trash; the instance's preferences and Keychain items
    (provider sign-ins, pairing keys) are deleted. The caller stops the instance first."""
    support = Path(support).expanduser().resolve()
    dev_root = Path(dev_root or Path.home() / "Library/Application Support/Woven Matter Dev").expanduser().resolve()
    if dev_root not in support.parents or support.name != "snapshot":
        raise ValueError("Only a Dev snapshot under Woven Matter Dev can be reset.")
    if bundle != f"wovenmatter.desktop.dev.{support.parent.name}.snapshot":
        raise ValueError(f"{bundle} is not the bundle ID of {support}.")
    roots = keychain_services(bundle)
    if support.exists():
        if not (support / "development-snapshot.json").is_file():
            raise ValueError(f"{support} is not a development snapshot; refusing to reset it.")
        trash = Path(trash or Path.home() / ".Trash")
        trash.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H.%M.%S", time.localtime(now()))
        target = trash / f"Woven Matter Dev {support.parent.name} {support.name} {stamp}"
        suffix = 2
        while target.exists():
            target = trash / f"Woven Matter Dev {support.parent.name} {support.name} {stamp} {suffix}"
            suffix += 1
        shutil.move(str(support), str(target))
        print(f"Moved the old snapshot to the Trash: {target}")
    run(["defaults", "delete", bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Attributes only (no -d): service names, never secrets.
    dump = run(["security", "dump-keychain"], capture_output=True, text=True).stdout
    services = sorted({name for name in re.findall(r'"svce"<blob>="([^"]*)"', dump) if owned_service(name, roots)})
    removed, failed = 0, []
    for service in services:
        while run(["security", "delete-generic-password", "-s", service],
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            removed += 1
        if service in re.findall(r'"svce"<blob>="([^"]*)"',
                                 run(["security", "dump-keychain"], capture_output=True, text=True).stdout):
            failed.append(service)
    print(f"Removed {removed} Keychain item(s) and the preferences of {bundle}.")
    if failed:
        raise ValueError("Could not remove Keychain items for: " + ", ".join(failed) + ". Delete them in Keychain Access, then run this again.")


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
    library = sub.add_parser("linux-library")
    library.add_argument("--root", type=Path, required=True)
    fresh = sub.add_parser("reset")
    fresh.add_argument("--support", type=Path, required=True)
    fresh.add_argument("--bundle", required=True)
    args = parser.parse_args()
    if args.command == "profile":
        print(json.dumps(profile(args.root, args.instance, args.mode)))
    elif args.command == "snapshot":
        snapshot(args.source, args.destination)
    elif args.command == "linux-library":
        ensure_linux_library(args.root)
    elif args.command == "reset":
        reset(args.support, args.bundle)
    else:
        print("true" if backend_running(args.executable) else "false")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TimeoutError, sqlite3.Error, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
