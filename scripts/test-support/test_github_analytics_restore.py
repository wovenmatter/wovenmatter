import importlib.util
import io
import json
from pathlib import Path
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("restore", Path(__file__).parents[1] / "restore-github-analytics.py")
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)

HISTORY = {"schema_version": 1, "repository": "o/r", "traffic_days": {"old-day": {}},
           "download_observations": {"old-day": {"assets": []}}, "posthog_accepted": {"old": "uuid"}}


def archive_bytes():
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr("history.json", json.dumps(HISTORY))
    return data.getvalue()


def artifact(identifier, branch="main", expired=False):
    return {"id": identifier, "name": "analytics-history", "expired": expired,
            "workflow_run": {"id": identifier, "head_branch": branch}}


class RestoreTests(unittest.TestCase):
    def test_missing_or_expired_history_requires_complete_backup(self):
        def fetch(_): return json.dumps({"artifacts": [artifact(1, expired=True)]}).encode()
        with self.assertRaisesRegex(ValueError, "refusing to reset"):
            restore.restore("o/r", fetch)
        self.assertEqual(restore.restore("o/r", fetch, json.dumps(HISTORY)), HISTORY)
        with self.assertRaises(ValueError): restore.restore("o/r", fetch, "{}")

    def test_pagination_and_workflow_provenance_preserve_checkpoint(self):
        requested = []
        def fetch(path):
            requested.append(path)
            if "&page=1" in path: return json.dumps({"artifacts": [artifact(i, "untrusted") for i in range(100)]}).encode()
            if "&page=2" in path: return json.dumps({"artifacts": [artifact(102), artifact(101)]}).encode()
            if "/runs/" in path:
                return json.dumps({"path": ".github/workflows/other.yml" if path.endswith("102") else ".github/workflows/analytics-history.yml",
                                   "event": "workflow_dispatch", "head_repository": {"full_name": "o/r"}}).encode()
            self.assertTrue(path.endswith("/101/zip"))
            return archive_bytes()
        self.assertEqual(restore.restore("o/r", fetch, "invalid ignored seed"), HISTORY)
        self.assertTrue(any("&page=2" in path for path in requested))

    def test_corrupt_latest_archive_never_falls_back_or_uses_seed(self):
        def fetch(path):
            if "artifacts?" in path: return json.dumps({"artifacts": [artifact(2), artifact(1)]}).encode()
            if "/runs/" in path:
                return json.dumps({"path": ".github/workflows/analytics-history.yml", "event": "schedule", "head_repository": {"full_name": "o/r"}}).encode()
            self.assertTrue(path.endswith("/2/zip"))
            return b"corrupt"
        with self.assertRaises(zipfile.BadZipFile): restore.restore("o/r", fetch, json.dumps(HISTORY))


if __name__ == "__main__": unittest.main()
