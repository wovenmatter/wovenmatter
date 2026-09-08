#!/usr/bin/env python3
"""Portable WovenMatter history client and private SSH-stdio relay (stdlib only)."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

MAX_BYTES = 64 * 1024 * 1024


def receive(stream):
    data = bytearray()
    while True:
        chunk = stream.recv(65536)
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        if len(data) > MAX_BYTES:
            raise ValueError("History response exceeds 64 MiB; request a smaller page")


def relay(directory, source):
    """Only reached over the workspace's already-authorized SSH connection.

    Each process owns a session-bound private socket. No public listener, shared
    database file, credentials in prompts, or container-to-host networking needed.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    script = directory / "woven-history"
    script.write_text(source)
    os.chmod(script, 0o700)
    path = directory / "history.sock"
    path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX)
    try:
        server.bind(str(path))
        os.chmod(path, 0o600)
        server.listen(16)
        print("READY", flush=True)
        # select also observes owner disconnect while no client is connected.
        import select
        while True:
            ready, _, _ = select.select([server, sys.stdin], [], [])
            if sys.stdin in ready:
                break
            client, _ = server.accept()
            with client:
                client.settimeout(60)
                try:
                    request = receive(client)
                    if len(request) > 4 * 1024 * 1024:
                        raise ValueError("History request exceeds 4 MiB")
                    sys.stdout.write(base64.b64encode(request).decode() + "\n")
                    sys.stdout.flush()
                    response = sys.stdin.readline(MAX_BYTES * 2)
                    if not response:
                        break
                    client.sendall(base64.b64decode(response.strip(), validate=True))
                except (OSError, ValueError) as error:
                    try:
                        client.sendall(json.dumps({"error": str(error)}).encode())
                    except OSError:
                        pass
    finally:
        server.close()
        path.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["conversations", "conversation", "runs", "events", "trace", "event", "search", "versions", "version", "send"])
    parser.add_argument("value", nargs="?")
    for flag in ["conversation", "run", "harness", "kind", "since", "until", "text", "request-id"]:
        parser.add_argument("--" + flag)
    parser.add_argument("--after", type=int, default=0)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--characters", type=int, default=65536)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--socket", default=os.environ.get("WOVEN_HISTORY_SOCKET", str(Path(__file__).parent / "history.sock")))
    args = parser.parse_args(argv)
    if args.limit < 1 or args.limit > 200 or args.after < 0 or args.offset < 0 or not 1 <= args.characters <= 65536:
        parser.error("limit must be 1...200 and cursor nonnegative")
    if args.command in ["conversation", "trace", "event", "search", "versions", "version", "send"] and not args.value:
        parser.error("command requires an ID or search text")
    request = {"schemaVersion": 1, "command": args.command, "after": args.after, "limit": args.limit, "offset": args.offset, "characters": args.characters}
    if args.value:
        request["search" if args.command == "search" else "id"] = args.value
    for name, key in [("conversation", "conversationID"), ("run", "runID"), ("harness", "harness"), ("kind", "kind"), ("since", "since"), ("until", "until"), ("text", "message"), ("request_id", "requestID")]:
        if getattr(args, name) is not None:
            request[key] = getattr(args, name)
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(60)
        client.connect(args.socket)
        client.sendall(json.dumps(request).encode())
        client.shutdown(socket.SHUT_WR)
        response = receive(client)
    result = json.loads(response)
    print(json.dumps(result, ensure_ascii=False))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--relay":
        relay(sys.argv[2], source)  # injected by the owner during SSH bootstrap
    else:
        try:
            sys.exit(main())
        except (OSError, ValueError) as error:
            print("woven-history: " + str(error), file=sys.stderr)
            sys.exit(1)
