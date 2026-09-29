import base64
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "app/App/Resources/wovenmatter-remote.py"
spec = importlib.util.spec_from_file_location("wovenmatter_remote_tools", SOURCE)
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class RemoteToolTests(unittest.TestCase):
    def test_transport_failure_retains_the_retry_identity(self):
        identity = "10000000-0000-4000-8000-000000000002"
        with tempfile.TemporaryDirectory(prefix="wmt-", dir="/tmp") as root:
            output = io.StringIO()
            with patch.dict(os.environ, {"WOVENMATTER_SOCKET": str(Path(root) / "missing.sock")}), contextlib.redirect_stdout(output):
                status = tools.run_cli(["sessions", "create", "--title", "Retry", "--request-id", identity])
            response = json.loads(output.getvalue())
            self.assertEqual(status, 1)
            self.assertFalse(response["success"])
            self.assertEqual(response["requestID"], identity)
            self.assertEqual(response["code"], "transport_error")

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

    def test_literal_flags_are_values_and_retry_id_is_preserved(self):
        request_id = "10000000-0000-4000-8000-000000000001"
        args = ["sessions", "send", "target", "--text", "--file", "--request-id", request_id]
        request = json.loads(tools.build_request(args, {}))
        self.assertEqual(request["arguments"], args)
        self.assertEqual(request["requestID"], request_id)
        args = ["notes", "append", "--text", "--note-id", "--request-id", request_id]
        request = json.loads(tools.build_request(args, {"WOVENMATTER_NOTE_ID": "note-a"}))
        self.assertEqual(request["arguments"], args + ["--note-id", "note-a"])
        args = ["notes", "append", "--text", "--request-id"]
        self.assertEqual(json.loads(tools.build_request(args, {}))["arguments"], args)

    def test_attached_note_does_not_override_explicit_read_or_folder_discovery(self):
        for args in [["notes", "folders"], ["notes", "read", "explicit-note"],
                     ["notes", "read", "--offset", "10", "explicit-note"]]:
            request = json.loads(tools.build_request(args, {"WOVENMATTER_NOTE_ID": "attached-note"}))
            self.assertEqual(request["arguments"], args)
        args = ["notes", "read", "--offset", "10"]
        request = json.loads(tools.build_request(args, {"WOVENMATTER_NOTE_ID": "attached-note"}))
        self.assertEqual(request["arguments"], args + ["--note-id", "attached-note"])
        with self.assertRaises(ValueError):
            tools.build_request(["notes", "list"] + [""] * 1023, {})

    def test_receive_deadline_cannot_be_extended_by_trickle_input(self):
        class TrickleConnection:
            def __init__(self):
                self.timeouts = []
                self.reads = 0

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

            def recv(self, maximum):
                self.reads += 1
                return b"x"

        connection = TrickleConnection()
        with patch.object(tools.time, "monotonic", side_effect=[0, 0, 0.5, 1.1]):
            with self.assertRaises(TimeoutError):
                tools.receive_all(connection, 1024, timeout=1)
        self.assertEqual(connection.reads, 2)
        self.assertEqual(connection.timeouts, [1, 0.5])

    def test_overload_returns_busy_with_a_fixed_drain_deadline(self):
        class Connection:
            def __init__(self):
                self.reply = None
                self.closed = False
                self.shutdowns = []
                self.timeouts = []

            def settimeout(self, timeout):
                self.timeouts.append(timeout)

            def sendall(self, data):
                self.reply = json.loads(data)

            def shutdown(self, direction):
                self.shutdowns.append(direction)

            def recv(self, maximum):
                raise TimeoutError("unresponsive request")

            def close(self):
                self.closed = True

        connection = Connection()
        with patch.object(tools.time, "monotonic", side_effect=[0, 0.1, 0.1, 0.2]):
            tools.reject_busy(connection)
        self.assertEqual(connection.reply["code"], "busy")
        self.assertFalse(connection.reply["success"])
        self.assertTrue(connection.closed)
        self.assertEqual(connection.shutdowns, [tools.socket.SHUT_WR])
        self.assertLessEqual(max(connection.timeouts), 0.25)
        self.assertEqual(tools.RESPONSE_LIMIT, 1024 * 1024)

    def test_relay_rejects_fifth_request_before_forwarding(self):
        with tempfile.TemporaryDirectory(prefix="wmt-", dir="/tmp") as root:
            relay_dir = Path(root) / "relay"
            relay = subprocess.Popen([sys.executable, str(SOURCE), "--relay", str(relay_dir)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            connections = []
            try:
                self.assertTrue(select.select([relay.stdout], [], [], 5)[0])
                self.assertEqual(json.loads(relay.stdout.readline()), {"ready": True})
                for _ in range(4):
                    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    connections.append(connection)
                    connection.settimeout(5)
                    connection.connect(str(relay_dir / "rpc.sock"))
                    connection.sendall(tools.build_request(["sessions", "list"], {}))
                    connection.shutdown(socket.SHUT_WR)
                    self.assertTrue(select.select([relay.stdout], [], [], 5)[0])
                    self.assertIn("payload", json.loads(relay.stdout.readline()))
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as overflow:
                    overflow.settimeout(5)
                    overflow.connect(str(relay_dir / "rpc.sock"))
                    overflow.sendall(tools.build_request(["sessions", "list"], {}))
                    overflow.shutdown(socket.SHUT_WR)
                    reply = json.loads(tools.receive_all(overflow, tools.RESPONSE_LIMIT, timeout=5))
                self.assertEqual(reply["code"], "busy")
                self.assertFalse(reply["success"])
                self.assertFalse(select.select([relay.stdout], [], [], 0)[0], "Rejected work was forwarded")
            finally:
                for connection in connections:
                    connection.close()
                relay.stdin.close()
                if relay.poll() is None:
                    try:
                        relay.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        relay.kill()
                        relay.wait()
                for handle in [relay.stdout, relay.stderr]:
                    handle.close()

    def test_relay_rejects_invalid_envelopes_without_forwarding(self):
        with tempfile.TemporaryDirectory(prefix="wmt-", dir="/tmp") as root:
            relay_dir = Path(root) / "relay"
            relay = subprocess.Popen([sys.executable, str(SOURCE), "--relay", str(relay_dir)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([relay.stdout], [], [], 5)[0])
                self.assertEqual(json.loads(relay.stdout.readline()), {"ready": True})
                for request in [b'{}', json.dumps({"requestID": "x" * 100_000}).encode(),
                                b'[' * 2000 + b']' * 2000]:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.settimeout(5)
                        connection.connect(str(relay_dir / "rpc.sock"))
                        connection.sendall(request)
                        connection.shutdown(socket.SHUT_WR)
                        raw = tools.receive_all(connection, tools.RESPONSE_LIMIT, timeout=5)
                    reply = json.loads(raw)
                    self.assertEqual(reply["code"], "invalid_request")
                    self.assertIsNone(reply.get("requestID"))
                    self.assertLess(len(raw), 1024)
                self.assertFalse(select.select([relay.stdout], [], [], 0)[0])
            finally:
                relay.stdin.close()
                if relay.poll() is None:
                    try:
                        relay.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        relay.kill()
                        relay.wait()
                for handle in [relay.stdout, relay.stderr]:
                    handle.close()

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
