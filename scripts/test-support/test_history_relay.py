import base64
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import sys

SOURCE = Path(__file__).resolve().parents[2] / 'app/App/Resources/woven-history-remote.py'


class RelayTests(unittest.TestCase):
    def test_portable_cli_queries_and_sends_over_owner_stdio(self):
        source = SOURCE.read_text()
        bootstrap = 'import base64; source=base64.b64decode(' + repr(base64.b64encode(source.encode()).decode()) + ').decode(); exec(compile(source,"<relay>","exec"))'
        with tempfile.TemporaryDirectory(prefix='wmh-', dir='/tmp') as directory:
            relay = subprocess.Popen([sys.executable, '-c', bootstrap, '--relay', directory], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(relay.stdout.readline().strip(), 'READY')
                received = []
                def owner():
                    for _ in range(2):
                        request = json.loads(base64.b64decode(relay.stdout.readline()))
                        received.append(request)
                        response = {'schemaVersion': 1, 'rows': [{'id': 'fixture', 'text': 'π evidence'}]}
                        relay.stdin.write(base64.b64encode(json.dumps(response).encode()).decode() + '\n')
                        relay.stdin.flush()
                thread = threading.Thread(target=owner, daemon=True)
                thread.start()
                for arguments in [['search', 'π evidence'], ['send', 'target-session', '--text', 'hello']]:
                    client = subprocess.run([sys.executable, str(Path(directory) / 'woven-history')] + arguments, text=True, capture_output=True, timeout=10)
                    self.assertEqual(client.returncode, 0, client.stderr)
                    self.assertEqual(json.loads(client.stdout)['rows'][0]['text'], 'π evidence')
                thread.join(5)
                self.assertFalse(thread.is_alive())
                self.assertEqual(received[0]['search'], 'π evidence')
                self.assertEqual(received[1]['message'], 'hello')
                self.assertNotIn('callerConversationID', received[1])
                self.assertEqual((Path(directory) / 'history.sock').stat().st_mode & 0o777, 0o600)
                relay.stdin.close()
                self.assertEqual(relay.wait(timeout=5), 0)
                self.assertFalse((Path(directory) / 'history.sock').exists())
            finally:
                if relay.poll() is None:
                    relay.terminate()
                    relay.wait(timeout=5)
                relay.stdout.close()
                relay.stderr.close()


if __name__ == '__main__':
    unittest.main()
