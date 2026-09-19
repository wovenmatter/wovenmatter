"""Exercise the built app's CLI against a private, provider-free socket fixture."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

CLI = Path(sys.argv.pop(1)).resolve()


class BundledCLITests(unittest.TestCase):
    def invoke(self, arguments, response, environment=None):
        with tempfile.TemporaryDirectory(prefix="wmcli-", dir="/tmp") as directory:
            endpoint = str(Path(directory) / "rpc.sock")
            captured, errors = [], []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(endpoint)
                listener.listen(1)
                listener.settimeout(5)

                def serve():
                    try:
                        connection, _ = listener.accept()
                        with connection:
                            connection.settimeout(5)
                            chunks = []
                            while True:
                                chunk = connection.recv(65536)
                                if not chunk:
                                    break
                                chunks.append(chunk)
                            captured.append(json.loads(b"".join(chunks)))
                            connection.sendall(json.dumps(response).encode())
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=serve)
                worker.start()
                try:
                    result = subprocess.run([str(CLI)] + arguments,
                        env={**os.environ, "WOVENMATTER_SOCKET": endpoint, **(environment or {})},
                        capture_output=True, text=True, timeout=10)
                finally:
                    worker.join(timeout=6)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors, errors)
                self.assertEqual(len(captured), 1, result.stderr)
                return result, captured[0]

    def test_help_for_all_groups_requires_no_endpoint(self):
        for group in [None, "notes", "history", "sessions", "timers", "usage", "calendar", "library"]:
            result = subprocess.run([str(CLI)] + ([group, "help"] if group else ["help"]),
                env={**os.environ, "WOVENMATTER_SOCKET": "/nonexistent/wovenmatter-test.sock"},
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("wovenmatter", result.stdout)

    def test_literal_flag_value_and_request_id_reach_bound_endpoint(self):
        identity = "10000000-0000-4000-8000-000000000001"
        args = ["sessions", "send", "destination", "--text", "--file", "--request-id", identity]
        response = {"success": True, "result": {"status": "accepted"}, "silent": False, "requestID": identity}
        result, request = self.invoke(args, response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(request["arguments"], args)
        self.assertEqual(request["requestID"], identity)
        self.assertNotIn("callerID", request)
        self.assertEqual(json.loads(result.stdout), response)

    def test_note_file_is_normalized_on_cli_host(self):
        with tempfile.TemporaryDirectory(prefix="wmcli-input-", dir="/tmp") as directory:
            document = Path(directory) / "fixture.html"
            document.write_text("<p>Fixture body</p>")
            result, request = self.invoke(["notes", "set-html", "--file", str(document)],
                {"success": True, "silent": False}, {"WOVENMATTER_NOTE_ID": "note-fixture"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(request["arguments"], ["notes", "set-html", "--html", "<p>Fixture body</p>", "--note-id", "note-fixture"])

    def test_silent_capacity_response_and_explicit_errors(self):
        result, _ = self.invoke(["sessions", "send", "destination", "--text", "Fixture"],
            {"success": True, "silent": True})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        result, _ = self.invoke(["sessions", "manage", "destination", "--purpose", "Fixture"],
            {"success": False, "silent": False, "error": "This session is already coordinated by session fixture-owner."})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture-owner", json.loads(result.stdout)["error"])


if __name__ == "__main__":
    unittest.main()
