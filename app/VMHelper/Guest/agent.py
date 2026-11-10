#!/usr/bin/python3
"""Woven VM guest agent.

Listens on vsock only and accepts connections only from the Mac (CID 2):
- 2000: one JSON request per connection, one JSON reply (control);
- 2001: preview forwards: a one-line header names the target, then raw bytes;
- 2375: the Docker Engine API, bridged to /run/docker.sock.
Both bridges keep each direction open until its own end-of-stream, so a
client's half-close (exec stdin EOF) never truncates the other direction.
"""
import base64
import http.client
import json
import os
import socket
import subprocess
import threading
import time

AGENT_VERSION = 1
AGENT_PORT, FORWARD_PORT, DOCKER_PORT = 2000, 2001, 2375
HOST_CID = 2
STATE = "/var/lib/woven"
DATA = "/var/lib/woven-data"
DOCKER_SOCKET = "/run/docker.sock"
BUFFER = 256 * 1024
UPDATABLE = ("/usr/local/lib/woven/", "/etc/systemd/system/woven-", "/etc/woven/versions.env",
             "/etc/apt/keyrings/docker.asc")


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


class DockerConnection(http.client.HTTPConnection):
    def __init__(self, timeout):
        super().__init__("localhost", timeout=timeout)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(DOCKER_SOCKET)


def docker(path, timeout=10):
    connection = DockerConnection(timeout)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        return response.status, (json.loads(body) if body else None)
    finally:
        connection.close()


def meminfo():
    values = {}
    with open("/proc/meminfo") as handle:
        for line in handle:
            name, rest = line.split(":", 1)
            parts = rest.split()
            values[name] = int(parts[0]) * (1024 if len(parts) > 1 else 1)
    return values


def balloon_features():
    root = "/sys/bus/virtio/drivers/virtio_balloon"
    try:
        for entry in os.listdir(root):
            path = os.path.join(root, entry, "features")
            if os.path.exists(path):
                bits = open(path).read().strip()
                # VIRTIO_BALLOON_F_DEFLATE_ON_OOM = 2, F_FREE_PAGE_HINT = 3, F_PAGE_POISON = 4, F_REPORTING = 5
                return {"bits": bits, "deflate_on_oom": bits[2:3] == "1",
                        "free_page_hint": bits[3:4] == "1", "page_reporting": bits[5:6] == "1"}
    except OSError:
        pass
    return None


def os_name():
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return None


def tail(path, lines=20):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 16384))
            return b"\n".join(handle.read().splitlines()[-lines:]).decode(errors="replace")
    except OSError:
        return ""


def disk_usage():
    if not os.path.ismount(DATA):
        return None
    stats = os.statvfs(DATA)
    total = stats.f_blocks * stats.f_frsize
    free = stats.f_bavail * stats.f_frsize
    reserve = 0
    try:
        reserve = os.stat(DATA + "/.reserve").st_size
    except OSError:
        pass
    return {"total": total, "free": free, "reserve": reserve, "cap": total - reserve,
            "used": max(0, total - free - reserve)}


_host_addresses = None


def op_status(_):
    # Status must answer at once whatever state Docker is in: the Mac follows
    # provisioning through it. Docker matters only once the guest is
    # provisioned; before that, connecting to its (socket-activated) API would
    # start a half-installed daemon, and a daemon that is still starting holds
    # the request open.
    docker_version = None
    provisioned = read_json(STATE + "/provisioned")
    if provisioned is not None:
        try:
            code, body = docker("/version", timeout=2)
            if code == 200:
                docker_version = body.get("Version")
        except (OSError, http.client.HTTPException, ValueError):
            pass
    return {"agent": AGENT_VERSION, "os": os_name(), "kernel": os.uname().release, "docker": docker_version,
            "provision": read_json(STATE + "/status.json"), "update": read_json(STATE + "/update.json"),
            "provisioned": provisioned, "balloon": balloon_features(),
            "boot_id": open("/proc/sys/kernel/random/boot_id").read().strip(),
            "cmdline": open("/proc/cmdline").read().strip()}


def vmstat():
    counts = {}
    try:
        with open("/proc/vmstat") as handle:
            for line in handle:
                name, _, value = line.partition(" ")
                counts[name] = int(value)
    except (OSError, ValueError):
        pass
    return counts


def balloon_bytes(counts):
    """What the balloon holds now. The Mac only sets a target; the guest reaches
    it gradually (or not at all when it cannot reclaim), so the target is not
    the balloon's size."""
    if "balloon_inflate" not in counts or "balloon_deflate" not in counts:
        return None
    return max(0, counts["balloon_inflate"] - counts["balloon_deflate"]) * os.sysconf("SC_PAGE_SIZE")


def refault_bytes(counts):
    """Evicted page cache read back in, cumulative: a cache too small for the work."""
    if "workingset_refault_file" not in counts:
        return None
    return counts["workingset_refault_file"] * os.sysconf("SC_PAGE_SIZE")


def memory_pressure():
    """/proc/pressure/memory: the share of time tasks stalled on memory."""
    result = {}
    try:
        with open("/proc/pressure/memory") as handle:
            for line in handle:
                kind, *fields = line.split()
                values = dict(field.split("=", 1) for field in fields)
                result[kind] = {"avg10": float(values["avg10"]), "total_us": int(values["total"])}
    except (OSError, KeyError, ValueError):
        return None
    return result


def op_meminfo(_):
    info, counts = meminfo(), vmstat()
    return {"total": info["MemTotal"], "free": info["MemFree"], "available": info["MemAvailable"],
            "cached": info.get("Cached", 0), "shmem": info.get("Shmem", 0), "dirty": info.get("Dirty", 0),
            "writeback": info.get("Writeback", 0), "balloon": balloon_bytes(counts),
            "refault": refault_bytes(counts), "pressure": memory_pressure()}


def op_set_time(request):
    target = int(request["epoch_ns"])
    delta = target - time.time_ns()
    changed = abs(delta) > 50_000_000
    if changed:
        time.clock_settime_ns(time.CLOCK_REALTIME, target)
    return {"delta_ns": delta, "set": changed}


def op_set_host_addresses(request):
    global _host_addresses
    addresses = sorted(set(str(a) for a in request.get("addresses", [])))
    for address in addresses:
        if not all(c in "0123456789abcdefABCDEF:." for c in address) or len(address) > 45:
            raise ValueError("invalid address")
    if addresses != _host_addresses:
        subprocess.run(["/usr/local/lib/woven/egress.sh", "host", *addresses], check=True, timeout=90,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _host_addresses = addresses
    return {"addresses": addresses}


def op_disk(_):
    return disk_usage()


def op_set_disk_cap(request):
    result = subprocess.run(["/usr/local/lib/woven/disk-cap.sh", str(int(request["bytes"]))], check=True,
                            timeout=600, capture_output=True, text=True)
    usage = disk_usage()
    usage["message"] = result.stdout.strip()
    return usage


def op_running_containers(_):
    code, body = docker("/containers/json")
    if code != 200:
        raise RuntimeError("Docker Engine returned %d" % code)
    # Image builds run no listed container; the load shows them.
    return {"running": len(body), "load": os.getloadavg()[0]}


def op_update(request):
    files = request.get("files", {})
    for path, content in files.items():
        if not path.startswith(UPDATABLE) or ".." in path:
            raise ValueError("refusing to write " + path)
    for path, content in files.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = path + ".woven-new"
        with open(temporary, "wb") as handle:
            handle.write(base64.b64decode(content))
        os.chmod(temporary, 0o755 if path.startswith("/usr/local/lib/woven/") else 0o644)
        os.replace(temporary, path)
    try:
        os.unlink(STATE + "/update.json")
    except FileNotFoundError:
        pass
    subprocess.run(["systemctl", "daemon-reload"], check=True, timeout=60)
    subprocess.run(["systemctl", "start", "--no-block", "woven-update.service"], check=True, timeout=60)
    return {"started": True}


def op_provision(_):
    subprocess.run(["systemctl", "restart", "--no-block", "woven-provision.service"], check=True, timeout=60)
    return {"started": True}


def op_trim(_):
    result = subprocess.run(["fstrim", "-av"], capture_output=True, text=True, timeout=600)
    return {"output": (result.stdout + result.stderr).strip(), "code": result.returncode}


def op_poweroff(_):
    subprocess.Popen(["systemctl", "poweroff"])
    return {"ok": True}


def command_output(arguments, timeout=5, lines=80):
    """A diagnostic command's output (its first lines); its failure is part of the answer."""
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
        return "\n".join((result.stdout + result.stderr).strip().splitlines()[:lines])
    except (OSError, subprocess.SubprocessError) as error:
        return "%s: %s" % (type(error).__name__, error)


def op_diagnostics(_):
    """What explains a stuck or failed guest, for the Mac's diagnostics."""
    journal = ["journalctl", "--no-pager", "-b", "-o", "short-iso"]
    return {"provision": read_json(STATE + "/status.json"), "update": read_json(STATE + "/update.json"),
            "provision_log": tail("/var/log/woven-provision.log", 60),
            # The first alert-level lines: the first oops or lockup explains the rest.
            "kernel_alerts": command_output(["journalctl", "--no-pager", "-b", "-k", "-p", "0..2", "-o", "cat"],
                                            timeout=10, lines=40),
            "kernel_log": command_output(journal + ["-k", "-n", "60"], timeout=10),
            "failed_units": command_output(["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"]),
            "jobs": command_output(["systemctl", "list-jobs", "--no-legend", "--no-pager"]),
            "processes": command_output(["ps", "-eo", "pid,stat,pcpu,etime,wchan:24,args", "--sort=-pcpu"],
                                        lines=25),
            "load": os.getloadavg(), "uptime": float(open("/proc/uptime").read().split()[0]),
            "cloud_init": command_output(["cloud-init", "status", "--long"], timeout=10)}


OPERATIONS = {"ping": lambda _: {"agent": AGENT_VERSION}, "status": op_status, "meminfo": op_meminfo,
              "set_time": op_set_time, "set_host_addresses": op_set_host_addresses,
              "disk": op_disk, "set_disk_cap": op_set_disk_cap, "running_containers": op_running_containers,
              "update": op_update, "provision": op_provision, "trim": op_trim, "poweroff": op_poweroff,
              "diagnostics": op_diagnostics}


def read_line(connection, limit=1 << 20):
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = connection.recv(65536 if limit > 4096 else 1)
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            raise ValueError("request too large")
    return bytes(data)


def serve_control(connection):
    try:
        connection.settimeout(30)
        request = json.loads(read_line(connection))
        handler = OPERATIONS.get(request.get("op"))
        if handler is None:
            reply = {"ok": False, "error": "unknown operation"}
        else:
            reply = {"ok": True, "result": handler(request)}
    except Exception as error:  # Report every failure to the Mac instead of dropping it.
        reply = {"ok": False, "error": "%s: %s" % (type(error).__name__, error)}
    try:
        connection.sendall(json.dumps(reply).encode() + b"\n")
    except OSError:
        pass
    finally:
        connection.close()


def pump(source, destination, done):
    try:
        while True:
            data = source.recv(BUFFER)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    try:
        destination.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    done.release()


def splice(first, second):
    done = threading.Semaphore(0)
    threading.Thread(target=pump, args=(second, first, done), daemon=True).start()
    pump(first, second, done)
    done.acquire()
    done.acquire()
    first.close()
    second.close()


def container_address(name):
    code, body = docker("/containers/%s/json" % name)
    if code != 200:
        raise LookupError("no container named " + name)
    if not body.get("State", {}).get("Running"):
        raise LookupError(name + " is not running")
    for network in (body.get("NetworkSettings", {}).get("Networks") or {}).values():
        if network.get("IPAddress"):
            return network["IPAddress"]
    raise LookupError(name + " has no network address")


def serve_forward(connection):
    try:
        connection.settimeout(10)
        kind, target, port = read_line(connection, 4096).decode().split()
        address = container_address(target) if kind == "container" else target
        upstream = socket.create_connection((address, int(port)), timeout=10)
        upstream.settimeout(None)
        connection.settimeout(None)
        connection.sendall(b"OK\n")
    except Exception as error:
        try:
            connection.sendall(("ERR %s\n" % error).encode())
        except OSError:
            pass
        connection.close()
        return
    splice(connection, upstream)


def serve_docker(connection):
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        upstream.connect(DOCKER_SOCKET)
    except OSError:
        connection.close()
        return
    splice(connection, upstream)


def listen(port, handler):
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((socket.VMADDR_CID_ANY, port))
    server.listen(128)
    while True:
        connection, (cid, _) = server.accept()
        if cid != HOST_CID:
            connection.close()
            continue
        threading.Thread(target=handler, args=(connection,), daemon=True).start()


def main():
    os.makedirs(STATE, exist_ok=True)
    for port, handler in ((FORWARD_PORT, serve_forward), (DOCKER_PORT, serve_docker)):
        threading.Thread(target=listen, args=(port, handler), daemon=True).start()
    listen(AGENT_PORT, serve_control)


if __name__ == "__main__":
    main()
