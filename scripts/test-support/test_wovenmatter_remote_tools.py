import base64
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "app/App/Resources/wovenmatter-remote.py"
spec = importlib.util.spec_from_file_location("wovenmatter_remote_tools", SOURCE)
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class RemoteToolTests(unittest.TestCase):
    def test_files_are_read_on_the_cli_host_and_identity_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            file = Path(root) / "artifact.html"
            file.write_text("<h1>Remote body</h1>")
            request = json.loads(tools.build_request(["notes", "set-html", "--file", str(file)], {"WOVENMATTER_NOTE_ID": "note-a"}))
            self.assertEqual(request["arguments"], ["notes", "set-html", "--html", "<h1>Remote body</h1>", "--note-id", "note-a"])
            self.assertNotIn("callerID", request)
            self.assertNotIn("sourceID", request)
        with self.assertRaises(ValueError):
            tools.build_request(["notes", "list", "--file", "/does/not/exist"], {})

    def test_relay_binds_private_endpoint_and_closes_with_app(self):
        with tempfile.TemporaryDirectory(prefix="wmt-", dir="/tmp") as root:
            relay_dir = Path(root) / "relay"
            relay = subprocess.Popen([sys.executable, str(SOURCE), "--relay", str(relay_dir)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            child = None
            try:
                self.assertTrue(select.select([relay.stdout], [], [], 5)[0], "Relay never became ready")
                self.assertEqual(json.loads(relay.stdout.readline()), {"ready": True})
                self.assertEqual(relay_dir.stat().st_mode & 0o777, 0o700)
                self.assertEqual((relay_dir / "rpc.sock").stat().st_mode & 0o777, 0o700)
                environment = dict(os.environ)
                environment.pop("WOVENMATTER_SOCKET", None)
                child = subprocess.Popen([sys.executable, str(relay_dir / "wovenmatter"), "sessions", "list"],
                                         env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertTrue(select.select([relay.stdout], [], [], 5)[0], "No forwarded request")
                packet = json.loads(relay.stdout.readline())
                request = json.loads(base64.b64decode(packet["payload"]))
                self.assertEqual(request["arguments"], ["sessions", "list"])
                response = {"success": True, "result": {"fixture": "scoped response"}, "silent": False}
                relay.stdin.write(json.dumps({"id": packet["id"], "payload": base64.b64encode(json.dumps(response).encode()).decode()}).encode() + b"\n")
                relay.stdin.flush()
                stdout, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr)
                self.assertEqual(json.loads(stdout), response)
                relay.stdin.close()
                relay.wait(timeout=5)
                self.assertFalse(relay_dir.exists())
            finally:
                if child is not None and child.poll() is None:
                    child.kill()
                    child.wait()
                if relay.poll() is None:
                    relay.kill()
                    relay.wait()
                for handle in [relay.stdin, relay.stdout, relay.stderr]:
                    handle.close()


if __name__ == "__main__":
    unittest.main()
