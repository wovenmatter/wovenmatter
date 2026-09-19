#!/usr/bin/env python3
"""Session-bound CLI and stdio relay for a managed Woven Matter workspace."""
import base64
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import sys
import threading
import uuid

REQUEST_LIMIT = 4 * 1024 * 1024
RESPONSE_LIMIT = 32 * 1024 * 1024
# The Swift forwarder has a 55s total deadline; leave time for SSH replies.
RELAY_TIMEOUT = 75
CLI_TIMEOUT = 90


def receive_all(connection, maximum):
    chunks, size = [], 0
    while True:
        chunk = connection.recv(min(65536, maximum + 1 - size))
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if size > maximum:
            raise ValueError("Tool message exceeds its size limit.")
        chunks.append(chunk)


def option_indices(arguments):
    # Values may themselves look like flags. Only inspect argument positions,
    # never a literal message or document value, for CLI-side transformations.
    boolean_flags = {"all-workspace", "independent", "no-notify", "paused", "all-day", "json", "header", "help"}
    if arguments[:1] == ["notes"]:
        boolean_flags.discard("json")
    result, index = {}, 2
    while index < len(arguments):
        item = arguments[index]
        if not item.startswith("--"):
            index += 1
            continue
        key = item[2:]
        if key in result:
            raise ValueError("Repeated option: " + item)
        result[key] = index
        index += 1 if key in boolean_flags else 2
    return result


def build_request(arguments, environment):
    args = list(arguments)
    options = option_indices(args)
    if "file" in options:
        index = options["file"]
        if args[:2] not in (["notes", "apply"], ["notes", "set-html"]) or index + 1 >= len(args):
            raise ValueError("--file is supported by notes apply and notes set-html.")
        with open(args[index + 1], "rb") as source:
            data = source.read(3 * 1024 * 1024 + 1)
        if len(data) > 3 * 1024 * 1024:
            raise ValueError("Input files must be at most 3 MiB.")
        args[index:index + 2] = ["--html" if args[1] == "set-html" else "--json", data.decode("utf-8")]
    if len(args) > 1 and args[0] == "notes" and args[1] not in ("list", "create", "versions", "version", "restore", "help"):
        if "note-id" not in options and environment.get("WOVENMATTER_NOTE_ID"):
            args += ["--note-id", environment["WOVENMATTER_NOTE_ID"]]
    request_id = str(uuid.uuid4())
    if "request-id" in options:
        index = options["request-id"]
        if index + 1 >= len(args):
            raise ValueError("--request-id requires a UUID.")
        request_id = str(uuid.UUID(args[index + 1]))
    data = json.dumps({"schemaVersion": 1, "requestID": request_id, "arguments": args}).encode("utf-8")
    if len(data) > REQUEST_LIMIT:
        raise ValueError("Tool request exceeds 4 MiB.")
    return data


def run_cli(arguments):
    endpoint = os.environ.get("WOVENMATTER_SOCKET") or str(Path(__file__).with_name("rpc.sock"))
    request = build_request(arguments, os.environ)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(CLI_TIMEOUT)
            connection.connect(endpoint)
            connection.sendall(request)
            connection.shutdown(socket.SHUT_WR)
            response = receive_all(connection, RESPONSE_LIMIT)
        result = json.loads(response)
        if not result.get("silent", False):
            sys.stdout.buffer.write(response + b"\n")
        return 0 if result.get("success", False) else 1
    except (OSError, ValueError) as error:
        # A lost reply is not permission to create a new mutation identity.
        print(json.dumps({"success": False, "error": str(error), "silent": False,
                          "requestID": json.loads(request)["requestID"]}))
        return 1


def run_relay(directory):
    # The app chooses a fresh, unguessable directory for each endpoint. Never
    # reuse or remove another relay's directory on reconnect.
    os.umask(0o077)
    root = Path(directory)
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.mkdir(mode=0o700)
    endpoint = root / "rpc.sock"
    source = globals().get("WOVENMATTER_SOURCE") or Path(__file__).read_text()
    cli = root / "wovenmatter"
    cli.write_text(source)
    cli.chmod(0o700)
    stopped = threading.Event()
    pending, connections = {}, set()
    lock, output_lock = threading.Lock(), threading.Lock()
    capacity = threading.BoundedSemaphore(4)

    def write_packet(packet):
        with output_lock:
            sys.stdout.write(json.dumps(packet) + "\n")
            sys.stdout.flush()

    def read_responses():
        try:
            while not stopped.is_set():
                line = sys.stdin.buffer.readline((RESPONSE_LIMIT * 4 // 3) + 4096)
                if not line:
                    break
                if not line.endswith(b"\n"):
                    raise ValueError("Oversized relay response.")
                packet = json.loads(line)
                data = base64.b64decode(packet["payload"], validate=True)
                if len(data) > RESPONSE_LIMIT:
                    raise ValueError("Oversized tool response.")
                with lock:
                    waiter = pending.get(packet["id"])
                if waiter is not None:
                    waiter.put_nowait(data)
        finally:
            stopped.set()
            with lock:
                for connection in connections:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

    def forward(connection):
        identity = str(uuid.uuid4())
        request_id = None
        try:
            connection.settimeout(RELAY_TIMEOUT)
            data = receive_all(connection, REQUEST_LIMIT)
            request = json.loads(data)
            if not isinstance(request, dict):
                raise ValueError("A tool request must be a JSON object.")
            request_id = request.get("requestID")
            waiter = queue.Queue(maxsize=1)
            with lock:
                pending[identity] = waiter
            write_packet({"id": identity, "payload": base64.b64encode(data).decode("ascii")})
            response = waiter.get(timeout=RELAY_TIMEOUT)
            connection.sendall(response)
        except (OSError, ValueError, queue.Empty) as error:
            try:
                connection.sendall(json.dumps({"success": False, "error": str(error) or "The tool relay timed out.", "silent": False, "requestID": request_id}).encode())
            except OSError:
                pass
        finally:
            with lock:
                pending.pop(identity, None)
                connections.discard(connection)
            connection.close()
            capacity.release()

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(endpoint))
            listener.listen(4)
            listener.settimeout(0.5)
            threading.Thread(target=read_responses, daemon=True).start()
            write_packet({"ready": True})
            while not stopped.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                if not capacity.acquire(blocking=False):
                    connection.close()
                    continue
                with lock:
                    connections.add(connection)
                threading.Thread(target=forward, args=(connection,), daemon=True).start()
    finally:
        stopped.set()
        shutil.rmtree(root)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--relay":
            run_relay(sys.argv[2])
            sys.exit(0)
        sys.exit(run_cli(sys.argv[1:]))
    except (OSError, ValueError, IndexError) as error:
        print("wovenmatter: " + str(error), file=sys.stderr)
        sys.exit(1)
