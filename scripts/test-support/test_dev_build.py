import importlib.util
import json
import os
import plistlib
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("dev_build", Path(__file__).resolve().parents[1] / "dev-build.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class DevelopmentBuildTests(unittest.TestCase):
    def test_backend_guard_matches_executable_aliases_without_matching_other_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            actual = root / "actual"; actual.mkdir()
            alias = root / "alias"; alias.symlink_to(actual, target_is_directory=True)
            executable = actual / "Review snapshot Dev.app/Contents/MacOS/Review snapshot Dev"
            executable.parent.mkdir(parents=True); executable.touch()
            via_alias = alias / executable.relative_to(actual)
            self.assertTrue(dev.backend_running(executable, [str(via_alias) + " --backend"]))
            self.assertTrue(dev.backend_running(via_alias, [str(executable) + " --backend"]))
            self.assertFalse(dev.backend_running(executable, [str(executable)]))
            self.assertFalse(dev.backend_running(executable, [str(root / "Other Dev") + " --backend"]))
            self.assertFalse(dev.backend_running(executable, []))

    def test_power_helper_accepts_profiles_with_an_exact_client_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binaries = root / "bin"; binaries.mkdir()
            compiler = binaries / "xcrun"
            compiler.write_text("#!/bin/sh\nexit 77\n"); compiler.chmod(0o755)
            for suffix in ("a.client", "c.live", "b.snapshot", "a.unrecognized.extra"):
                identifier = "wovenmatter.desktop.dev." + suffix
                scratch = root / suffix
                environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                                   PRODUCT_BUNDLE_IDENTIFIER=identifier, DERIVED_FILE_DIR=str(scratch))
                result = subprocess.run(["bash", str(Path(__file__).resolve().parents[1] / "build-power-helper.sh"),
                                         str(root / (suffix + ".app"))], env=environment, capture_output=True, text=True)
                if suffix.endswith("extra"):
                    self.assertNotEqual(result.returncode, 77)
                    self.assertIn("Unsupported power helper", result.stderr)
                else:
                    self.assertEqual(result.returncode, 77)  # Stopped before compilation or signing.
                    with (scratch / "power-helper/Info.plist").open("rb") as stream:
                        info = plistlib.load(stream)
                    self.assertEqual(set(info["WMAllowedClients"]),
                                     {"wovenmatter.desktop", "wovenmatter.desktop.dev", identifier})

    def test_profile_identity_and_modes_are_independent(self):
        a = dev.profile(Path("/tmp/work-a/repo"), None, "client")
        b = dev.profile(Path("/tmp/work-b/repo"), None, "client")
        self.assertNotEqual(a["bundle"], b["bundle"])
        self.assertNotEqual(a["support"], dev.profile(Path("/tmp/work-a/repo"), None, "snapshot")["support"])
        self.assertEqual(a, dev.profile(Path("/tmp/work-a/repo"), None, "client"))
        with self.assertRaises(ValueError): dev.profile(Path("/tmp/a"), "../production", "client")

    def test_auto_always_launches_full_app_and_client_remains_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args): subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True)
            git("init"); git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            path = root / "app/App/Views/Fixture.swift"; path.parent.mkdir(parents=True); path.write_text("UI")
            self.assertEqual(dev.choose_mode(root), "snapshot")
            path = root / "app/Sources/WovenMatterDashboardStore/WorkspaceDatabase+Schema.swift"
            path.parent.mkdir(parents=True); path.write_text("schema")
            self.assertEqual(dev.choose_mode(root), "snapshot")
            self.assertEqual(dev.profile(root, "fixture", "client")["mode"], "client")

    def test_default_launcher_plan_selects_the_standalone_snapshot(self):
        root = Path(__file__).resolve().parents[2]
        environment = dict(os.environ)
        environment.pop("WOVENMATTER_DEV_MODE", None)
        result = subprocess.run(["bash", str(root / "scripts/build_and_run.sh"),
                                 "--plan", "--instance", "default-fixture"],
                                env=environment, check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)["mode"], "snapshot")

    def test_live_host_is_explicit_and_shares_only_the_production_data_path(self):
        root = Path(__file__).resolve().parents[2]
        profiles = {}
        for mode in ("client", "snapshot", "live"):
            result = subprocess.run(["bash", str(root / "scripts/build_and_run.sh"), "--plan",
                                     "--mode", mode, "--instance", "fixture"], check=True, capture_output=True, text=True)
            profiles[mode] = json.loads(result.stdout)
            self.assertEqual(profiles[mode]["mode"], mode)
            self.assertEqual(profiles[mode]["bundle"], "wovenmatter.desktop.dev.fixture." + mode)
        production = str(Path.home() / "Library/Application Support/Woven Matter")
        self.assertEqual(profiles["live"]["support"], production)
        for mode in ("client", "snapshot"):
            self.assertNotEqual(profiles[mode]["support"], production)
        other = dev.profile(root, "other", "live")
        self.assertEqual(other["support"], production)
        self.assertNotEqual(other["bundle"], profiles["live"]["bundle"])

    def test_snapshot_includes_wal_and_assets_without_changing_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / "production"; source.mkdir()
            writer = sqlite3.connect(source / "workspace.sqlite")
            self.addCleanup(writer.close)
            writer.executescript("""
              PRAGMA journal_mode=WAL;
              CREATE TABLE notes(id TEXT PRIMARY KEY, content TEXT);
              CREATE TABLE desktop_local_acp_sessions(id TEXT);
              CREATE TABLE dashboard_agents(id TEXT PRIMARY KEY, governing_plane TEXT,
                authority_kind TEXT, runtime_device_id TEXT, deleted_at TEXT, status TEXT);
              CREATE TABLE dashboard_conversations(id TEXT PRIMARY KEY, agent_id TEXT REFERENCES dashboard_agents(id));
              INSERT INTO dashboard_agents VALUES('local-pi','wovenmatter_macos','device_owned',NULL,NULL,'ready');
              INSERT INTO dashboard_agents VALUES('remote-pi','remote_workspace','device_owned','remote',NULL,'ready');
              INSERT INTO dashboard_conversations VALUES('history','local-pi');
              CREATE TABLE companion_workspace(singleton INTEGER, workspace_id TEXT);
              CREATE TABLE dashboard_calendar_items(id TEXT, calendar_json TEXT);
              CREATE TABLE dashboard_runs(id TEXT,status TEXT);
              CREATE TABLE workspace_session_goals(session_id TEXT,value TEXT);
              CREATE TABLE workspace_session_timers(id TEXT,is_paused INTEGER,pending_delivery_id TEXT);
              INSERT INTO notes VALUES('note','shared content');
              INSERT INTO desktop_local_acp_sessions VALUES('production-session');
              INSERT INTO companion_workspace VALUES(1,'production-identity');
              INSERT INTO dashboard_calendar_items VALUES('job','{"task":{"prompt":"retain me"}}');
              INSERT INTO dashboard_runs VALUES('run','running');
              INSERT INTO workspace_session_goals VALUES('session','{"status":"active"}');
              INSERT INTO workspace_session_timers VALUES('timer',0,'pending');
            """)
            asset = source / "library-files"; asset.mkdir(); (asset / "blob").write_bytes(b"saved output")
            target = root / "dev"; dev.snapshot(source, target)
            with sqlite3.connect(target / "workspace.sqlite") as copy:
                self.assertEqual(copy.execute("SELECT content FROM notes").fetchone()[0], "shared content")
                self.assertEqual(copy.execute("SELECT COUNT(*) FROM desktop_local_acp_sessions").fetchone()[0], 0)
                self.assertIsNotNone(copy.execute("SELECT deleted_at FROM dashboard_agents WHERE id='local-pi'").fetchone()[0])
                self.assertEqual(copy.execute("SELECT status FROM dashboard_agents WHERE id='local-pi'").fetchone()[0], "offline")
                self.assertEqual(copy.execute("SELECT a.id FROM dashboard_conversations c JOIN dashboard_agents a ON c.agent_id=a.id").fetchone()[0], "local-pi")
                self.assertIsNone(copy.execute("SELECT deleted_at FROM dashboard_agents WHERE id='remote-pi'").fetchone()[0])
                self.assertNotEqual(copy.execute("SELECT workspace_id FROM companion_workspace").fetchone()[0], "production-identity")
                self.assertEqual(copy.execute("SELECT COUNT(*) FROM companion_calendar_owners").fetchone()[0], 1)
                self.assertIn("retain me", copy.execute("SELECT calendar_json FROM dashboard_calendar_items").fetchone()[0])
                self.assertEqual(copy.execute("SELECT status FROM dashboard_runs").fetchone()[0], "interrupted")
                self.assertEqual(json.loads(copy.execute("SELECT value FROM workspace_session_goals").fetchone()[0])["status"], "paused")
                self.assertEqual(copy.execute("SELECT is_paused,pending_delivery_id FROM workspace_session_timers").fetchone(), (1, None))
                copy.execute("UPDATE notes SET content='private'"); copy.commit()
            self.assertEqual(writer.execute("SELECT content FROM notes").fetchone()[0], "shared content")
            self.assertEqual(writer.execute("SELECT deleted_at,status FROM dashboard_agents WHERE id='local-pi'").fetchone(), (None, "ready"))
            self.assertEqual(writer.execute("SELECT status FROM dashboard_runs").fetchone()[0], "running")
            self.assertEqual(writer.execute("SELECT is_paused,pending_delivery_id FROM workspace_session_timers").fetchone(), (0, "pending"))
            self.assertEqual((target / "library-files/blob").read_bytes(), b"saved output")
            with self.assertRaises(ValueError): dev.snapshot(source, target)

    def test_snapshot_keeps_outside_tool_choices_without_inheriting_network_exposure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / "production"; source.mkdir()
            settings = {"enabledByDefault": ["notes"], "externalMCP": {"isEnabled": True, "groups": ["notes", "calendar"]}}
            with sqlite3.connect(source / "workspace.sqlite") as db:
                db.execute("CREATE TABLE workspace_tool_settings(id INTEGER PRIMARY KEY,value TEXT)")
                db.execute("INSERT INTO workspace_tool_settings VALUES(1,?)", (json.dumps(settings),))
            target = root / "snapshot"
            dev.snapshot(source, target)
            with sqlite3.connect(target / "workspace.sqlite") as db:
                copied = json.loads(db.execute("SELECT value FROM workspace_tool_settings").fetchone()[0])
            self.assertFalse(copied["externalMCP"]["isEnabled"])
            self.assertEqual(copied["externalMCP"]["groups"], ["notes", "calendar"])
            with sqlite3.connect(source / "workspace.sqlite") as db:
                self.assertEqual(json.loads(db.execute("SELECT value FROM workspace_tool_settings").fetchone()[0]), settings)

    def test_snapshot_refuses_source_alias_and_symlinked_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / "production"; source.mkdir()
            with sqlite3.connect(source / "workspace.sqlite") as db: db.execute("CREATE TABLE notes(id TEXT)")
            alias = root / "alias"; alias.symlink_to(source, target_is_directory=True)
            with self.assertRaises(ValueError): dev.snapshot(source, alias / "nested")
            (source / "library-files").symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError): dev.snapshot(source, root / "dev")
            self.assertFalse((root / "dev").exists())


if __name__ == "__main__": unittest.main()
