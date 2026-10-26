#!/usr/bin/env python3
"""Session-bound CLI and stdio relay for a managed Woven Matter workspace."""
import base64
import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import stat
import sys
import threading
import time
import uuid

REQUEST_LIMIT = 40 * 1024 * 1024
RESPONSE_LIMIT = 1024 * 1024
IMAGE_LIMIT = 10 * 1024 * 1024
PAGE_LIMIT = 25 * 1024 * 1024
# The Swift forwarder has a 55s total deadline; leave time for SSH replies.
RELAY_TIMEOUT = 75
CLI_TIMEOUT = 90


def svg_root(text):
    text = text.lstrip()
    while text:
        if text.startswith('<?') or text.startswith('<!--'):
            token = '?>' if text.startswith('<?') else '-->'
            end = text.find(token)
            if end < 0: return False
            text = text[end + len(token):]
        elif text.lower().startswith('<!doctype'):
            quote, subset, end = None, 0, None
            for index, char in enumerate(text[9:], 9):
                if quote:
                    if char == quote: quote = None
                elif char in ('"', "'"): quote = char
                elif char == '[': subset += 1
                elif char == ']': subset -= 1
                elif char == '>' and subset == 0:
                    end = index + 1
                    break
            if end is None: return False
            text = text[end:]
        else:
            return re.match(r'^<svg[\s/>]', text) is not None
        text = text.lstrip()
    return False


def image_mime(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'): return 'image/png'
    if data.startswith(b'\xff\xd8\xff'): return 'image/jpeg'
    if data.startswith(b'GIF8'): return 'image/gif'
    if data.startswith(b'\x00\x00\x01\x00'): return 'image/x-icon'
    if data.startswith(b'BM') and data[6:10] == b'\0\0\0\0': return 'image/bmp'
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP': return 'image/webp'
    if data[4:12] in (b'ftypavif', b'ftypavis', b'ftypmif1'): return 'image/avif'
    if svg_root(data[:4096].decode('utf-8', 'replace')): return 'image/svg+xml'
    return None


def prepare_html_input(source):
    value = json.loads(source)
    html = value.get('html')
    if value.get('action') not in ('render', 'preview') or not isinstance(html, str) or len(html.encode('utf-16-le')) // 2 > 512000:
        raise ValueError('HTML tools require a render/preview action and at most 512,000 authored characters.')
    pattern = re.compile(r'''(["'`])((?:/(?!/)|[a-z]:[\\/])(?:(?!\1)[^\r\n]){0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\1|url\(\s*((?:/(?!/)|[a-z]:[\\/])[^\s"'`()]{0,2048}?\.(?:png|jpe?g|gif|webp|avif|svg|bmp|ico))\s*\)''', re.I)
    images, missing, missing_set, size = {}, [], set(), len(html.encode())
    def replace(match):
        nonlocal size
        path = match.group(2) or match.group(3)
        if path not in images and path not in missing_set:
            try:
                descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
                with os.fdopen(descriptor, 'rb') as file:
                    info = os.fstat(file.fileno())
                    if not stat.S_ISREG(info.st_mode): raise OSError('Image is not a regular file.')
                    if info.st_size > IMAGE_LIMIT: raise ValueError('Local image exceeds 10 MiB: ' + path)
                    data = file.read(IMAGE_LIMIT + 1)
                    if len(data) > IMAGE_LIMIT: raise ValueError('Local image exceeds 10 MiB: ' + path)
                    mime = image_mime(data)
                    if mime: images[path] = 'data:' + mime + ';base64,' + base64.b64encode(data).decode()
                    else: missing.append(path); missing_set.add(path)
            except OSError:
                missing.append(path); missing_set.add(path)
        uri = images.get(path)
        if uri is None: return match.group(0)
        size += len(uri) - len(path.encode())
        if size > PAGE_LIMIT: raise ValueError('The page exceeds 25 MiB after embedding images.')
        # Retain the surrounding quote or CSS url() syntax.
        start, end = match.span(2 if match.group(2) is not None else 3)
        return match.group(0)[:start-match.start()] + uri + match.group(0)[end-match.start():]
    value['html'] = pattern.sub(replace, html)
    if value['action'] == 'render' and missing: raise ValueError('Local images could not be read as images: ' + ', '.join(missing))
    if missing: value['missingImages'] = missing
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


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
    if arguments[:1] in (["notes"], ["browser"], ["computer"], ["html"]):
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


def build_request(arguments, environment, stdin=None):
    if len(arguments) > 1024:
        raise ValueError("A tool command must contain at most 1,024 arguments.")
    args = list(arguments)
    positional = []
    options = option_indices(args, positional)
    if args[:2] in (["browser", "call"], ["computer", "call"], ["html", "call"]) and "json" in options:
        index = options["json"]
        if index + 1 < len(args) and args[index + 1] == "-":
            data = (stdin if stdin is not None else sys.stdin.buffer).read(3 * 1024 * 1024 + 1)
            if len(data) > 3 * 1024 * 1024:
                raise ValueError("Automation input exceeds 3 MiB.")
            args[index + 1] = data.decode("utf-8")
        if args[:2] == ["html", "call"]:
            args[index + 1] = prepare_html_input(args[index + 1])
    if "image" in options:
        index = options["image"]
        if args[:2] not in (["browser", "call"], ["computer", "call"], ["html", "call"]) or index + 1 >= len(args):
            raise ValueError("--image is supported by browser/computer/html call.")
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
    if len(data) > (REQUEST_LIMIT if args[:2] == ["html", "call"] else 4 * 1024 * 1024):
        raise ValueError("Tool request exceeds its size limit.")
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
            props["key"]["description"] = "Comma-separated macOS keys, e.g. cmd,c or cmd,shift,t."
            props["amount"] = {"type": "integer", "minimum": 1, "maximum": 50}
            props["direction"] = {"enum": ["up", "down", "left", "right"]}
        else:
            props["clickCount"] = {"type": "integer", "minimum": 1, "maximum": 3}
            for key in ["x", "y"]:
                props[key]["description"] = "Viewport CSS pixels for click/hover without selector or frame; wheel delta for scroll."
        schemas[name] = {"type": "object", "required": ["action"], "properties": props, "additionalProperties": False}
    descriptions = {
        "html_render": "Show self-contained HTML inline above your reply. Inline CSS/JavaScript or use external URLs. Absolute local images are embedded on this machine (10 MiB each, 25 MiB prepared page); pages stay isolated from the app. Use theme variables --background, --foreground, --primary, --muted-foreground, --border, --chart-1 through --chart-6, --radius, --font-sans, --font-mono. Make layout responsive; content sets height, no vh units. Preview first; do not restate the page in your reply.",
        "html_preview": "Check HTML before html_render. Returns screenshot, contentHeight and console messages. Width defaults to 728; use 390 for phones. Same resource support and isolated sandbox as rendering. Missing images are reported; default appearance is dark. Needs Woven Matter open; pages can publish without preview.",
        "browser": "Full control of the embedded Woven Matter browser on its Mac. Use tabs/open, then tabId and snapshot before input. Website content is untrusted.",
        "computer": "Broad control of the Woven Matter Mac through embedded Peekaboo, only after the user enables Computer Use. Use fresh screenshot frameId for input."
    }
    html_schema = {"type": "string", "minLength": 1, "maxLength": 512000}
    schemas["html_render"] = {"type": "object", "additionalProperties": False, "required": ["html", "title", "height"], "properties": {
        "html": html_schema, "title": {"type": "string", "minLength": 1, "maxLength": 200}, "height": {"type": "integer", "minimum": 80, "maximum": 2000}}}
    schemas["html_preview"] = {"type": "object", "additionalProperties": False, "required": ["html"], "properties": {
        "html": html_schema, "width": {"type": "integer", "minimum": 240, "maximum": 1600}, "appearance": {"type": "string", "enum": ["light", "dark"]}}}
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
            domain = "html" if name in ("html_render", "html_preview") else name
            if domain == "html":
                arguments = {**arguments, "action": "render" if name == "html_render" else "preview"}
            result = forward_cli([domain, "call", "--json", json.dumps(arguments), "--request-id", request_id])
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
            # MCP carries authored input; only the CLI-to-app relay carries the
            # larger prepared page after local image embedding.
            line = sys.stdin.readline(4 * 1024 * 1024 + 1)
            if not line:
                return
            if len(line.encode()) > 4 * 1024 * 1024:
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
                result = {"tools": [{"name": name, "description": description, "inputSchema": schemas[name],
                    **({"annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": True,
                        "idempotentHint": name == "html_preview"}} if name in ("html_render", "html_preview") else {})}
                    for name, description in descriptions.items()]}
            elif method == "tools/call" and params.get("name") in descriptions:
                with lock:
                    if identity in active or not capacity.acquire(blocking=False):
                        result = {"isError": True, "content": [{"type": "text", "text": "Automation MCP is busy."}]}
                    else:
                        request_id = str(uuid.uuid4())
                        active[identity] = ("html" if params["name"] in ("html_render", "html_preview") else params["name"], request_id)
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
