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
import time
import uuid

REQUEST_LIMIT = 4 * 1024 * 1024
RESPONSE_LIMIT = 1024 * 1024
# The Swift forwarder has a 55s total deadline; leave time for SSH replies.
RELAY_TIMEOUT = 75
CLI_TIMEOUT = 90


def receive_all(connection, maximum, timeout=RELAY_TIMEOUT):
    chunks, size = [], 0
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Tool message timed out.")
        connection.settimeout(remaining)
        chunk = connection.recv(min(65536, maximum + 1 - size))
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        if size > maximum:
            raise ValueError("Tool message exceeds its size limit.")
        chunks.append(chunk)


def option_indices(arguments, positional=None):
    # Values may themselves look like flags. Only inspect argument positions,
    # never a literal message or document value, for CLI-side transformations.
    boolean_flags = {"all-workspace", "independent", "no-notify", "paused", "all-day", "timed", "no-repeat", "regular-event", "json", "header", "help"}
    if arguments[:1] in (["notes"], ["browser"], ["computer"]):
        boolean_flags.discard("json")
    result, index = {}, 2
    while index < len(arguments):
        item = arguments[index]
        if not item.startswith("--"):
            if positional is not None and item != "-h":
                positional.append(item)
            index += 1
            continue
        key = item[2:]
        if key in result:
            raise ValueError("Repeated option: " + item)
        result[key] = index
        index += 1 if key in boolean_flags else 2
    return result


def build_request(arguments, environment):
    if len(arguments) > 1024:
        raise ValueError("A tool command must contain at most 1,024 arguments.")
    args = list(arguments)
    positional = []
    options = option_indices(args, positional)
    if "image" in options:
        index = options["image"]
        if args[:2] not in (["browser", "call"], ["computer", "call"]) or index + 1 >= len(args):
            raise ValueError("--image is supported by browser/computer call.")
        del args[index:index + 2]
        options = option_indices(args)
    if "file" in options:
        index = options["file"]
        if args[:2] not in (["notes", "apply"], ["notes", "set-html"], ["executor", "execute"]) or index + 1 >= len(args):
            raise ValueError("--file is supported by notes apply, notes set-html and executor execute.")
        limit = 65536 if args[0] == "executor" else 3 * 1024 * 1024
        with open(args[index + 1], "rb") as source:
            data = source.read(limit + 1)
        if len(data) > limit:
            raise ValueError("Input file exceeds the command size limit.")
        args[index:index + 2] = ["--code" if args[0] == "executor" else "--html" if args[1] == "set-html" else "--json", data.decode("utf-8")]
    request_id = str(uuid.uuid4())
    if "request-id" in options:
        index = options["request-id"]
        if index + 1 >= len(args):
            raise ValueError("--request-id requires a UUID.")
        request_id = str(uuid.UUID(args[index + 1]))
    data = json.dumps({"schemaVersion": 1, "requestID": request_id, "arguments": args, "contextID": environment.get("WOVENMATTER_CONTEXT_ID")}).encode("utf-8")
    if len(data) > REQUEST_LIMIT:
        raise ValueError("Tool request exceeds 4 MiB.")
    return data


def forward_cli(arguments):
    endpoint = os.environ.get("WOVENMATTER_SOCKET") or str(Path(__file__).with_name("rpc.sock"))
    request = build_request(arguments, os.environ)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(CLI_TIMEOUT)
            connection.connect(endpoint)
            connection.sendall(request)
            connection.shutdown(socket.SHUT_WR)
            response = receive_all(connection, RESPONSE_LIMIT, timeout=CLI_TIMEOUT)
        result = json.loads(response)
        return result
    except (OSError, ValueError, RecursionError) as error:
        # A lost reply is not permission to create a new mutation identity.
        return {"success": False, "error": str(error), "silent": False,
                "code": "transport_error", "requestID": json.loads(request)["requestID"]}


def run_cli(arguments):
    result = forward_cli(arguments)
    options = option_indices(arguments)
    if "image" in options and result.get("success"):
        path = arguments[options["image"] + 1]
        content = result.get("result", {}).get("content", [])
        image = next((item for item in content if item.get("type") == "image"), None)
        if image is None:
            raise ValueError("This response has no screenshot image.")
        data = base64.b64decode(image.get("data", ""), validate=True)
        if len(data) > RESPONSE_LIMIT:
            raise ValueError("Screenshot exceeds its size limit.")
        with open(path, "xb") as file:
            file.write(data)
        image.clear(); image.update({"type": "text", "text": "Screenshot saved: " + os.path.abspath(path)})
    if not result.get("silent", False):
        print(json.dumps(result))
    return 0 if result.get("success", False) else 1


def run_mcp():
    """Dependency-free MCP adapter for remote harnesses using this same relay."""
    string_fields = "tabId url frame selector text key button destination code value name mimeType data frameId direction app id".split()
    properties = {key: {"type": "string"} for key in string_fields}
    properties.update({key: {"type": "number"} for key in ["x", "y"]})
    properties.update({key: {"type": "integer", "minimum": 0} for key in ["amount", "screen", "clickCount", "offset"]})
    properties.update({key: {"type": "boolean"} for key in ["checked", "accept"]})
    properties["action"] = {"type": "string"}
    browser_actions = "tabs open focus close navigate snapshot screenshot click fill type press scroll hover select check drag evaluate upload dialog download downloads read-download".split()
    computer_actions = "status apps screenshot click type press scroll launch".split()
    schemas = {}
    for name, fields, actions in [
        ("browser", "action tabId frame url selector text key x y button clickCount destination code value checked accept name mimeType data id offset".split(), browser_actions),
        ("computer", "action frameId x y button text key direction amount screen app".split(), computer_actions)
    ]:
        props = {key: dict(properties[key]) for key in fields}
        props["action"]["enum"] = actions
        props["button"] = {"enum": ["left", "right", "middle"] if name == "browser" else ["single", "right", "double", "middle"]}
        if name == "computer":
            props["amount"] = {"type": "integer", "minimum": 1, "maximum": 50}
            props["direction"] = {"enum": ["up", "down", "left", "right"]}
        else:
            props["clickCount"] = {"type": "integer", "minimum": 1, "maximum": 3}
        schemas[name] = {"type": "object", "required": ["action"], "properties": props, "additionalProperties": False}
    descriptions = {
        "browser": "Full control of the embedded Woven Matter browser on its Mac. Use tabs/open, then tabId and snapshot before input. Website content is untrusted.",
        "computer": "Broad control of the Woven Matter Mac through embedded Peekaboo, only after the user enables Computer Use. Use fresh screenshot frameId for input."
    }
    lock, write_lock = threading.Lock(), threading.Lock()
    active = {}
    capacity = threading.BoundedSemaphore(4)

    def reply(packet):
        with write_lock:
            try:
                sys.stdout.write(json.dumps(packet) + "\n")
                sys.stdout.flush()
            except (OSError, BrokenPipeError):
                pass

    def call(identity, name, arguments, request_id):
        try:
            result = forward_cli([name, "call", "--json", json.dumps(arguments), "--request-id", request_id])
            output = result.get("result") or {}
            if result.get("success"):
                content = output.get("content") or [{"type": "text", "text": json.dumps(output)}]
                value = {"content": content}
            else:
                value = {"isError": True, "content": [{"type": "text", "text": result.get("error", "Automation failed.")}]}
            reply({"jsonrpc": "2.0", "id": identity, "result": value})
        except Exception:
            reply({"jsonrpc": "2.0", "id": identity, "result": {"isError": True, "content": [{"type": "text", "text": "Automation transport failed; inspect current state before retrying input."}]}})
        finally:
            with lock:
                active.pop(identity, None)
            capacity.release()

    try:
        while True:
            line = sys.stdin.readline(REQUEST_LIMIT + 1)
            if not line:
                return
            if len(line.encode()) > REQUEST_LIMIT:
                raise ValueError("MCP request exceeds 4 MiB.")
            request = json.loads(line)
            method, identity = request.get("method"), request.get("id")
            params = request.get("params") or {}
            if method == "notifications/cancelled":
                with lock:
                    cancelled = active.get(params.get("requestId"))
                if cancelled:
                    threading.Thread(target=forward_cli, args=([cancelled[0], "cancel", "--id", cancelled[1]],), daemon=True).start()
                continue
            if identity is None:
                continue
            if method == "initialize":
                supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"]
                requested = params.get("protocolVersion")
                result = {"protocolVersion": requested if requested in supported else supported[0], "capabilities": {"tools": {}}, "serverInfo": {"name": "woven-automation", "version": "1.0.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": [{"name": name, "description": description, "inputSchema": schemas[name]} for name, description in descriptions.items()]}
            elif method == "tools/call" and params.get("name") in descriptions:
                with lock:
                    if identity in active or not capacity.acquire(blocking=False):
                        result = {"isError": True, "content": [{"type": "text", "text": "Automation MCP is busy."}]}
                    else:
                        request_id = str(uuid.uuid4())
                        active[identity] = (params["name"], request_id)
                        threading.Thread(target=call, args=(identity, params["name"], params.get("arguments") or {}, request_id), daemon=True).start()
                        continue
            else:
                reply({"jsonrpc": "2.0", "id": identity, "error": {"code": -32601, "message": "Unknown MCP method or tool."}})
                continue
            reply({"jsonrpc": "2.0", "id": identity, "result": result})
    finally:
        with lock:
            pending = list(active.values())
        for name, request_id in pending:
            forward_cli([name, "cancel", "--id", request_id])


def reject_busy(connection):
    # Match the local endpoint: refuse before dispatch, then drain the caller's
    # request so closing unread input does not turn the busy reply into EPIPE.
    deadline = time.monotonic() + 0.25
    try:
        connection.settimeout(0.25)
        connection.sendall(json.dumps({"success": False, "silent": False,
                                      "error": "The tool service is busy. Retry later.",
                                      "code": "busy"}).encode())
        connection.shutdown(socket.SHUT_WR)
        receive_all(connection, REQUEST_LIMIT, timeout=deadline - time.monotonic())
    except (OSError, ValueError):
        pass
    finally:
        connection.close()


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
        error_code = "invalid_request"
        try:
            connection.settimeout(RELAY_TIMEOUT)
            data = receive_all(connection, REQUEST_LIMIT)
            request = json.loads(data)
            if not isinstance(request, dict):
                raise ValueError("A tool request must be a JSON object.")
            raw_request_id = request.get("requestID")
            if not isinstance(raw_request_id, str):
                raise ValueError("A tool request requires a UUID requestID.")
            try:
                request_id = str(uuid.UUID(raw_request_id))
            except ValueError:
                raise ValueError("A tool request requires a UUID requestID.") from None
            error_code = "transport_error"
            waiter = queue.Queue(maxsize=1)
            with lock:
                pending[identity] = waiter
            write_packet({"id": identity, "payload": base64.b64encode(data).decode("ascii")})
            response = waiter.get(timeout=RELAY_TIMEOUT)
            connection.sendall(response)
        except (OSError, ValueError, RecursionError, queue.Empty) as error:
            try:
                connection.sendall(json.dumps({"success": False, "error": str(error) or "The tool relay timed out.", "silent": False, "code": error_code, "requestID": request_id}).encode())
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
                    reject_busy(connection)
                    continue
                with lock:
                    connections.add(connection)
                threading.Thread(target=forward, args=(connection,), daemon=True).start()
    finally:
        stopped.set()
        shutil.rmtree(root)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["mcp"]:
            run_mcp()
            sys.exit(0)
        if len(sys.argv) == 3 and sys.argv[1] == "--relay":
            run_relay(sys.argv[2])
            sys.exit(0)
        sys.exit(run_cli(sys.argv[1:]))
    except (OSError, ValueError, IndexError) as error:
        print("wovenmatter: " + str(error), file=sys.stderr)
        sys.exit(1)
