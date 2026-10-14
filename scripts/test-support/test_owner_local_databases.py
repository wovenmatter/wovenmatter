"""Exercise scheduled-agent dataset tools with all Mac bridge state absent."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[2] / 'remote/src/wovenmatter'


class OwnerLocalDatabaseTests(unittest.TestCase):
    def test_offline_writes_are_owned_and_atomic(self):
        with tempfile.TemporaryDirectory(prefix='wovenmatter-owner-local-') as root:
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(('WOVENMATTER_', 'WOVEN_NOTE_'))}
            environment['WOVENMATTER_DATA_DIRECTORY'] = root

            def run(*args, success=True):
                result = subprocess.run(['/usr/bin/python3', str(CLI), 'databases', *args],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                return json.loads(result.stdout) if success else result.stderr

            row = run('create', '--title', 'Offline collection')
            self.assertTrue(row['owner'].startswith('workspace:'))
            run('execute', '--database-id', row['id'], '--query',
                'CREATE TABLE observations(value); INSERT INTO observations VALUES(42)')
            run('execute', '--database-id', row['id'], '--query',
                'INSERT INTO observations VALUES(99); INSERT INTO missing VALUES(1)', success=False)
            data = run('query', '--database-id', row['id'], '--query',
                       'SELECT value FROM observations')
            self.assertEqual(data['query']['rows'], [['42']])
            self.assertEqual(run('list')['databases'][0]['revision'], 2)
            self.assertEqual(run('list')['databases'][0]['owner'], row['owner'])


if __name__ == '__main__':
    unittest.main()
