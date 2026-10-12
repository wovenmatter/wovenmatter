import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("collector", Path(__file__).parents[1] / "collect-github-analytics.py")
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

class HistoryTests(unittest.TestCase):
    def test_rollover_and_asset_replacement(self):
        history = {"schema_version":1,"repository":"o/r","traffic_days":{"2025-01-01":{"views":{"count":7,"uniques":3}}},"download_observations":{"2025-01-01":{"assets":[{"asset_id":1,"download_count":5}]}}}
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
    def test_failure_preserves_previous_history(self):
        previous={}
        def unavailable(_): raise RuntimeError("unavailable")
        with self.assertRaises(RuntimeError): collector.collect(previous,"o/r",unavailable)
        self.assertEqual(previous,{})

if __name__ == "__main__": unittest.main()
