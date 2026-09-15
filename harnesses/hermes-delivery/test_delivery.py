import importlib.util
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('delivery', Path(__file__).with_name('__init__.py'))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)

class DeliveryTests(unittest.TestCase):
    def test_durable_identity_and_conflicting_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home/'cron').mkdir()
            with sqlite3.connect(home/'cron/executions.db') as ledger:
                ledger.execute('CREATE TABLE executions(id,job_id,pid,status,started_at)')
                ledger.execute("INSERT INTO executions VALUES('run1','job',?,'running','today')",(os.getpid(),))
            self.assertEqual(delivery.save_result(home,'job','same output',os.getpid()),'run1')
            self.assertEqual(delivery.save_result(home,'job','same output',os.getpid()),'run1')
            with self.assertRaises(ValueError): delivery.save_result(home,'job','different',os.getpid())
            with self.assertRaises(ValueError): delivery.save_result(home,'other','output',os.getpid())
            with sqlite3.connect(home/'.woven-matter/scheduled-results.sqlite') as queue:
                self.assertEqual(queue.execute('SELECT count(*) FROM results').fetchone()[0],1)
            with sqlite3.connect(home/'cron/executions.db') as ledger:
                ledger.execute("UPDATE executions SET status='completed'")
                ledger.execute("INSERT INTO executions VALUES('run2','job',?,'running','later')",(os.getpid(),))
            self.assertEqual(delivery.save_result(home,'job','same output',os.getpid()),'run2')
            with sqlite3.connect(home/'.woven-matter/scheduled-results.sqlite') as queue:
                self.assertEqual(queue.execute('SELECT count(*) FROM results').fetchone()[0],2)

if __name__ == '__main__': unittest.main()
