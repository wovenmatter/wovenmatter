import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).parents[1] / "publish-github-analytics.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def history():
    return {"schema_version": 1, "repository": "wovenmatter/wovenmatter", "traffic_days": {
        "2026-10-10": {"views": {"count": 12, "uniques": 4, "observed_at": "2026-10-11T05:17:00+00:00"}}
    }, "download_observations": {
        "2026-10-10": {"observed_at": "2026-10-10T05:17:00+00:00", "assets": [
            {"asset_id": 1, "name": "App.dmg", "download_count": 20},
            {"asset_id": 2, "name": "SHA256SUMS.txt", "download_count": 5}]},
        "2026-10-11": {"observed_at": "2026-10-11T05:17:00+00:00", "assets": [
            {"asset_id": 3, "name": "Replacement.dmg", "download_count": 2}]}
    }}


class PublisherTests(unittest.TestCase):
    def test_privacy_replacement_and_original_dates(self):
        events = [event for _, event in publisher.pending_snapshots(history())]
        self.assertEqual(events[0]["properties"]["report_day"], "2026-10-10")
        self.assertEqual(events[0]["timestamp"], "2026-10-11T05:17:00+00:00")
        self.assertEqual(events[-1]["properties"]["cumulative_dmg_downloads"], 22)
        self.assertEqual(events[-1]["properties"]["cumulative_release_asset_downloads"], 27)
        for event in events:
            props = event["properties"]
            self.assertFalse(props["qualifying_activity"])
            self.assertFalse(props["$process_person_profile"])
            self.assertTrue(props["$geoip_disable"])
            self.assertNotIn("name", props)
            self.assertNotIn("$ip", props)
            self.assertTrue(props["distinct_id"].startswith("github-repository:"))

    def test_partial_failure_retry_and_changed_observation(self):
        value = history()
        saved = []
        calls = []
        def send(payload):
            calls.append(payload)
            if len(calls) == 2:
                raise RuntimeError("offline")
        original = publisher.pending_snapshots(value)
        with self.assertRaises(RuntimeError):
            publisher.publish(value, "public-test-key", send, lambda h: saved.append(copy.deepcopy(h)), batch_size=1)
        self.assertEqual(len(saved), 1)
        pending = publisher.pending_snapshots(saved[-1])
        self.assertEqual(pending, original[1:])
        batches = []
        self.assertEqual(publisher.publish(saved[-1], "public-test-key", batches.append), 2)
        self.assertEqual(batches[0]["batch"][0]["uuid"], calls[1]["batch"][0]["uuid"])
        self.assertEqual(publisher.publish(saved[-1], "public-test-key", batches.append), 0)
        row = saved[-1]["traffic_days"]["2026-10-10"]["views"]
        row.update(count=15, observed_at="2026-10-12T05:17:00+00:00")
        revised = publisher.pending_snapshots(saved[-1])
        self.assertEqual(len(revised), 1)
        self.assertNotEqual(revised[0][1]["uuid"], original[0][1]["uuid"])

    def test_missing_token_and_invalid_counter_do_not_send(self):
        batches = []
        with self.assertRaises(ValueError):
            publisher.publish(history(), "", batches.append)
        value = history()
        value["traffic_days"]["2026-10-10"]["views"]["count"] = -1
        with self.assertRaises(ValueError):
            publisher.publish(value, "public-test-key", batches.append)
        self.assertEqual(batches, [])


if __name__ == "__main__":
    unittest.main()
