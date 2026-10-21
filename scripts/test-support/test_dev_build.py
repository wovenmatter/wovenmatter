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
    def test_power_helper_accepts_profiles_with_an_exact_client_allowlist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binaries = root / "bin"; binaries.mkdir()
            compiler = binaries / "xcrun"
            compiler.write_text("#!/bin/sh\nexit 77\n"); compiler.chmod(0o755)
            for suffix in ("a.live", "b.snapshot", "a.unrecognized.extra"):
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
        a = dev.profile(Path("/tmp/work-a/repo"), None, "live")
        b = dev.profile(Path("/tmp/work-b/repo"), None, "live")
        self.assertNotEqual(a["bundle"], b["bundle"])
        self.assertNotEqual(a["support"], dev.profile(Path("/tmp/work-a/repo"), None, "snapshot")["support"])
        self.assertEqual(a, dev.profile(Path("/tmp/work-a/repo"), None, "live"))
        with self.assertRaises(ValueError): dev.profile(Path("/tmp/a"), "../production", "live")

    def test_auto_selects_host_changes_but_live_for_harness_and_ui(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args): subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True)
            git("init"); git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            path = root / "app/App/Views/Fixture.swift"; path.parent.mkdir(parents=True); path.write_text("UI")
            self.assertEqual(dev.choose_mode(root), "live")
            path = root / "app/Sources/WovenMatterDashboardStore/WorkspaceDatabase+Schema.swift"
            path.parent.mkdir(parents=True); path.write_text("schema")
            self.assertEqual(dev.choose_mode(root), "snapshot")
            self.assertEqual(dev.profile(root, "fixture", "live")["mode"], "live")

    def test_snapshot_includes_wal_and_assets_without_changing_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / "production"; source.mkdir()
            writer = sqlite3.connect(source / "workspace.sqlite")
            self.addCleanup(writer.close)
            writer.executescript("""
              PRAGMA journal_mode=WAL;
              CREATE TABLE notes(id TEXT PRIMARY KEY, content TEXT);
              CREATE TABLE desktop_local_acp_sessions(id TEXT);
              CREATE TABLE companion_workspace(singleton INTEGER, workspace_id TEXT);
              CREATE TABLE dashboard_calendar_items(id TEXT, calendar_json TEXT);
              CREATE TABLE dashboard_runs(id TEXT,status TEXT);
              CREATE TABLE workspace_session_goals(session_id TEXT,value TEXT);
              INSERT INTO notes VALUES('note','shared content');
              INSERT INTO desktop_local_acp_sessions VALUES('production-session');
              INSERT INTO companion_workspace VALUES(1,'production-identity');
              INSERT INTO dashboard_calendar_items VALUES('job','{"task":{"prompt":"retain me"}}');
              INSERT INTO dashboard_runs VALUES('run','running');
              INSERT INTO workspace_session_goals VALUES('session','{"status":"active"}');
            """)
            asset = source / "library-files"; asset.mkdir(); (asset / "blob").write_bytes(b"saved output")
            target = root / "dev"; dev.snapshot(source, target)
            with sqlite3.connect(target / "workspace.sqlite") as copy:
                self.assertEqual(copy.execute("SELECT content FROM notes").fetchone()[0], "shared content")
                self.assertEqual(copy.execute("SELECT COUNT(*) FROM desktop_local_acp_sessions").fetchone()[0], 0)
                self.assertNotEqual(copy.execute("SELECT workspace_id FROM companion_workspace").fetchone()[0], "production-identity")
                self.assertEqual(copy.execute("SELECT COUNT(*) FROM companion_calendar_owners").fetchone()[0], 1)
                self.assertIn("retain me", copy.execute("SELECT calendar_json FROM dashboard_calendar_items").fetchone()[0])
                self.assertEqual(copy.execute("SELECT status FROM dashboard_runs").fetchone()[0], "interrupted")
                self.assertEqual(json.loads(copy.execute("SELECT value FROM workspace_session_goals").fetchone()[0])["status"], "paused")
                copy.execute("UPDATE notes SET content='private'"); copy.commit()
            self.assertEqual(writer.execute("SELECT content FROM notes").fetchone()[0], "shared content")
            self.assertEqual(writer.execute("SELECT status FROM dashboard_runs").fetchone()[0], "running")
            self.assertEqual((target / "library-files/blob").read_bytes(), b"saved output")
            with self.assertRaises(ValueError): dev.snapshot(source, target)

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
