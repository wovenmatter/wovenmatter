"""The retained GitHub analytics history is recognised by what it holds: its repository and
its counters. A history collected earlier, which also carries a number nothing reads, is
collected into, published from and restored like any other. No GitHub or PostHog request."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'wovenmatter/wovenmatter'


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector, publisher, restorer = (load(name) for name in (
    'collect-github-analytics', 'publish-github-analytics', 'restore-github-analytics'))


def github(path):
    if path == f'repos/{REPOSITORY}':
        return {'stargazers_count': 7, 'forks_count': 2}
    if '/traffic/' in path:
        metric = path.split('/traffic/')[1].split('?')[0]
        return {metric: [{'timestamp': '2026-11-18T00:00:00Z', 'count': 5, 'uniques': 3}]}
    if '/releases?' in path:
        return [{'draft': False, 'tag_name': 'v1.2.3', 'assets': [{'id': 11, 'name': 'WovenMatter_1.2.3_arm64.dmg', 'download_count': 40}]}]
    raise AssertionError(path)


# As the workflow has kept it until now.
EARLIER = {
    'schema_version': 1, 'repository': REPOSITORY,
    'repository_observations': {'2026-11-17': {'observed_at': '2026-11-17T06:00:00+00:00', 'stars': 6, 'forks': 2}},
    'traffic_days': {'2026-11-17': {'views': {'count': 4, 'uniques': 2, 'observed_at': '2026-11-17T06:00:00+00:00'}}},
    'download_observations': {'2026-11-17': {'observed_at': '2026-11-17T06:00:00+00:00',
        'assets': [{'asset_id': 11, 'release': 'v1.2.3', 'name': 'WovenMatter_1.2.3_arm64.dmg', 'download_count': 30}]}},
    'last_collected_at': '2026-11-17T06:00:00+00:00',
}


class GitHubAnalyticsHistoryTests(unittest.TestCase):
    def test_a_new_history_holds_only_the_repository_and_its_counters(self):
        history = collector.collect({}, REPOSITORY, fetch=github, now='2026-11-19T06:00:00+00:00')
        self.assertEqual(sorted(history), ['download_observations', 'last_collected_at', 'repository',
                                           'repository_observations', 'traffic_days'])
        self.assertTrue(publisher.pending_snapshots(history))

    def test_a_history_collected_earlier_is_kept_and_extended(self):
        before = json.loads(json.dumps(EARLIER))
        history = collector.collect(EARLIER, REPOSITORY, fetch=github, now='2026-11-19T06:00:00+00:00')
        self.assertEqual(EARLIER, before, 'the previous snapshot is never modified')
        for section in ('repository_observations', 'traffic_days', 'download_observations'):
            self.assertEqual(history[section]['2026-11-17'], EARLIER[section]['2026-11-17'])
        self.assertEqual(sorted(history['download_observations']), ['2026-11-17', '2026-11-19'])
        # What it publishes does not depend on the number: the same events as without it.
        without = {key: value for key, value in EARLIER.items() if key != 'schema_version'}
        self.assertEqual(publisher.pending_snapshots(EARLIER), publisher.pending_snapshots(without))
        self.assertTrue(publisher.pending_snapshots(history))

    def test_a_backup_made_earlier_restores(self):
        none = lambda path: json.dumps({'artifacts': []}).encode()
        self.assertEqual(restorer.restore(REPOSITORY, fetch=none, bootstrap=json.dumps(EARLIER)), EARLIER)
        with self.assertRaises(ValueError):
            restorer.restore(REPOSITORY, fetch=none)

    def test_another_repositorys_history_is_refused(self):
        other = dict(EARLIER, repository='someone/else')
        with self.assertRaises(ValueError):
            collector.collect(other, REPOSITORY, fetch=github, now='2026-11-19T06:00:00+00:00')
        with self.assertRaises(ValueError):
            restorer.restore(REPOSITORY, fetch=lambda path: json.dumps({'artifacts': []}).encode(), bootstrap=json.dumps(other))
        with self.assertRaises(ValueError):
            restorer.restore(REPOSITORY, fetch=lambda path: json.dumps({'artifacts': []}).encode(),
                             bootstrap=json.dumps({'repository': REPOSITORY, 'traffic_days': {}, 'download_observations': {}}))


if __name__ == '__main__':
    unittest.main()
