import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "collect-github-analytics.py")
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

class HistoryTests(unittest.TestCase):
    def test_rollover_and_asset_replacement(self):
        history = {"schema_version":1,"repository":"o/r","traffic_days":{"2025-01-01":{"views":{"count":7,"uniques":3}}},"download_observations":{"2025-01-01":{"assets":[{"asset_id":1,"name":"Old.dmg","download_count":5}]}}}
        def fetch(path):
            if "traffic" in path:
                metric="views" if "views" in path else "clones"
                return {metric:[{"timestamp":"2026-01-01T00:00:00Z","count":10,"uniques":4}]}
            return [{"draft":False,"tag_name":"v1","assets":[{"id":2,"name":"App.dmg","download_count":2}]}]
        result=collector.collect(history,"o/r",fetch,"2026-01-02T05:00:00+00:00")
        self.assertEqual(result["traffic_days"]["2025-01-01"]["views"]["count"],7)
        self.assertEqual(result["download_observations"]["2025-01-01"]["assets"][0]["asset_id"],1)
        self.assertEqual(result["download_observations"]["2026-01-02"]["assets"][0]["asset_id"],2)
        self.assertNotIn("2026-01-02",history["download_observations"])
        with self.assertRaises(ValueError): collector.collect(history,"different/repo",fetch)
    def test_same_day_rerun_retains_replaced_asset_and_updates_existing_counter(self):
        previous = {"schema_version": 1, "repository": "o/r", "download_observations": {
            "2026-01-02": {"assets": [
                {"asset_id": 1, "name": "Old.dmg", "download_count": 5},
                {"asset_id": 2, "name": "Current.dmg", "download_count": 2}]}}}
        def fetch(path):
            if "traffic" in path:
                return {"views" if "views" in path else "clones": []}
            return [{"draft": False, "tag_name": "v2", "assets": [
                {"id": 2, "name": "Current.dmg", "download_count": 7},
                {"id": 3, "name": "New.dmg", "download_count": 1}]}]
        result = collector.collect(previous, "o/r", fetch, "2026-01-02T15:00:00+00:00")
        assets = {a["asset_id"]: a["download_count"] for a in result["download_observations"]["2026-01-02"]["assets"]}
        self.assertEqual(assets, {1: 5, 2: 7, 3: 1})
        self.assertEqual(previous["download_observations"]["2026-01-02"]["assets"][1]["download_count"], 2)

    def test_supporting_files_are_not_retained_from_legacy_or_new_observations(self):
        previous = {"schema_version": 1, "repository": "o/r", "download_observations": {
            "2025-01-01": {"assets": [
                {"asset_id": 1, "name": "Old.dmg", "download_count": 5},
                {"asset_id": 2, "name": "latest-mac.json", "download_count": 30},
                {"asset_id": 3, "name": "SHA256SUMS.txt", "download_count": 2}]}}}
        def fetch(path):
            if "traffic" in path:
                return {"views" if "views" in path else "clones": []}
            return [{"draft": False, "tag_name": "v2", "assets": [
                {"id": 4, "name": "New.DMG", "download_count": 10},
                {"id": 5, "name": "latest-mac.json", "download_count": 100},
                {"id": 6, "name": "SHA256SUMS.txt", "download_count": 50}]}]
        result = collector.collect(previous, "o/r", fetch, "2026-01-02T15:00:00+00:00")
        self.assertEqual([a["asset_id"] for a in result["download_observations"]["2025-01-01"]["assets"]], [1])
        self.assertEqual([a["asset_id"] for a in result["download_observations"]["2026-01-02"]["assets"]], [4])
        self.assertEqual(len(previous["download_observations"]["2025-01-01"]["assets"]), 3)

    def test_failure_preserves_previous_history(self):
        previous={}
        def unavailable(_): raise RuntimeError("unavailable")
        with self.assertRaises(RuntimeError): collector.collect(previous,"o/r",unavailable)
        self.assertEqual(previous,{})

if __name__ == "__main__": unittest.main()
