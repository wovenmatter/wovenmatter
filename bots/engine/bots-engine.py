#!/usr/bin/env python3
"""Woven Matter's own Docker Engine for the bots on a Linux machine.

Install once, as root, for the account that runs the Woven server:

    sudo python3 bots-engine.py install --user NAME [--pool BYTES|none] [--disk BYTES|none]

It downloads the pinned static Docker Engine release, verifies it, and runs it
as its own dockerd with its own containerd, socket, data root, exec root,
bridge, nftables table and systemd units. Any Docker already on the machine,
its units, chains and /etc/docker are never read or changed. The socket
belongs to the account's own group, so the Woven server needs no root after
installing. The memory pool is the engine's systemd slice; the disk cap is
the size of the sparse ext4 image its data lives on. The server asks for a
new pool or cap by writing a request file that a root path unit applies.

Afterwards the installed root-owned copy runs only from those units. Remove
everything with:

    sudo python3 /usr/local/lib/woven-bots-engine/bots-engine uninstall
"""
import contextlib, grp, hashlib, ipaddress, json, os, platform, pwd, re, shutil, stat, subprocess, sys, tarfile
import tempfile, time, urllib.request
from pathlib import Path, PurePosixPath

# The pinned Docker Engine static release (download.docker.com/linux/static/stable)
# and its archives' SHA-256 values. See docs/DEPENDENCIES.md.
DOCKER_VERSION = '29.10.0'
DOCKER_SHA256 = {
    'x86_64': '7c1ebadc65c716cdc6d35fc78759ed0e4317debf43c21dd12f066f2006999def',
    'aarch64': '6e5159e8b5615e0c0c2954a2a1a2a12bc65f5d9b603595dba24a10cb367408cd',
}

GiB = 1024**3
MiB = 1024**2
MINIMUM_DISK = 2*GiB
MINIMUM_POOL = 1*GiB
REQUEST_LIMIT = 4096
# Outbound destinations a bot may never reach. IPv6 is not routed for bots at
# all, which covers the tailnet's IPv6 range, ULA and link-local. Ranges are
# written as (octets, prefix): the public tree keeps literal non-loopback
# addresses out of source files.
def cidr(octets, prefix): return str(ipaddress.IPv4Network((bytes(octets+(0,)*(4-len(octets))), prefix)))
def address(*octets): return str(ipaddress.IPv4Address(bytes(octets)))
BLOCKED_IPV4 = [cidr(*value) for value in (((0,),8),((10,),8),((100,64),10),((127,),8),((169,254),16),((172,16),12),
    ((192,0,0),24),((192,0,2),24),((192,168),16),((198,18),15),((198,51,100),24),((203,0,113),24),((224,),4),((240,),4))]
# The bridge's network: dockerd takes the bridge's own address as the network
# it hands containers, so the bridge address, the recorded subnet and every
# firewall rule name this one /24.
SUBNET_CANDIDATES = [cidr((10,n),24) for n in range(237,252)]
# Public resolvers: host resolvers are usually loopback, LAN or MagicDNS
# addresses, all of which the egress policy blocks.
DNS = [address(1,1,1,1), address(8,8,8,8)]


class Failure(Exception):
    def __init__(self, code, detail, status=69):
        super().__init__(detail)
        self.code, self.detail, self.status = code, detail, status


def fail(code, detail, status=69): raise Failure(code, detail, status)


class Layout:
    """Every path and unit name, derived from one name: `woven-bots-engine`,
    or `woven-bots-engine-<instance>` for a development instance, so one can
    run beside the real one. No name can be another program's."""
    def __init__(self, instance=None, root='/'):
        if instance is not None and not re.fullmatch(r'[a-z][a-z0-9]{1,15}', instance):
            fail('invalid_instance', 'Use a short lowercase engine instance name.', 64)
        self.instance = instance
        name = 'woven-bots-engine' + ('-'+instance if instance else '')
        self.name = name
        r = Path(root)
        self.lib = r/'usr/local/lib'/name
        self.helper = self.lib/'bots-engine'
        self.docker_root = self.lib/'docker'
        self.docker_current = self.docker_root/'current'
        self.etc = r/'etc'/name
        self.config = self.etc/'instance.json'
        self.daemon = self.etc/'daemon.json'
        self.containerd_config = self.etc/'containerd.toml'
        self.var = r/'var/lib'/name
        self.image = self.var/'disk.img'
        self.data = self.var/'docker'
        self.requests = self.var/'requests'
        self.request = self.requests/'settings.json'
        self.state = self.var/'state/state.json'
        self.run = r/'run'/name
        self.socket = self.run/'docker.sock'
        self.containerd_socket = self.run/'containerd/containerd.sock'
        self.units = r/'etc/systemd/system'
        self.service = name+'.service'
        # Its own containerd: dockerd would otherwise join a system containerd
        # and share the person's Docker "moby" namespace.
        self.containerd = name+'-containerd.service'
        self.slice = name.replace('-', '_')+'.slice'
        self.firewall = name+'-firewall.service'
        self.apply_path = name+'-apply.path'
        self.apply_service = name+'-apply.service'
        self.mount = systemd_escape_path(str(Path('/')/self.data.relative_to(r)))+'.mount'
        # Docker-style name: host firewalls that admit container bridges
        # commonly match br-*. The person's Docker manages only bridges it made.
        self.bridge = 'br-wvbots' + ('-'+instance[:5] if instance else '')
        self.table = name.replace('-', '_')
        self.chain = name.upper()[:28]

    def unit_names(self):
        return [self.service, self.containerd, self.slice, self.firewall, self.apply_path, self.apply_service, self.mount]


def systemd_escape_path(path):
    # systemd-escape --path, without the binary.
    trimmed = path.strip('/')
    if not trimmed: return '-'
    out = []
    for index, ch in enumerate(trimmed):
        if ch == '/': out.append('-')
        elif ch.isalnum() or ch in '_:' or (ch == '.' and index > 0): out.append(ch)
        else: out.append('\\x%02x' % ord(ch))
    return ''.join(out)

# ---------------------------------------------------------------- rendering

def size_or_none(value, label):
    if value in (None, 'none', 'null'): return None
    if isinstance(value, bool): fail('invalid_size', 'Invalid '+label+'.', 64)
    if isinstance(value, str):
        if not value.isdigit(): fail('invalid_size', 'Invalid '+label+'.', 64)
        value = int(value)
    if not isinstance(value, int) or value <= 0 or value > 2**62: fail('invalid_size', 'Invalid '+label+'.', 64)
    return value


def normalize_pool(value, total_memory):
    value = size_or_none(value, 'memory pool')
    if value is None: return None
    if value < MINIMUM_POOL: fail('pool_too_small', 'The bots\' memory pool must be at least 1 GB.', 64)
    return min(value, total_memory)


def normalize_disk(value, total_disk):
    value = size_or_none(value, 'disk cap')
    if value is None: return None
    if value < MINIMUM_DISK: fail('disk_too_small', 'The bots\' disk cap must be at least 2 GB.', 64)
    return min(value, total_disk)


def round_image(size): return size-size % (4*MiB)


def choose_subnet(existing):
    """The first candidate /24 that overlaps no existing route or address."""
    taken = []
    for value in existing:
        with contextlib.suppress(ValueError): taken.append(ipaddress.ip_network(value, strict=False))
    for candidate in SUBNET_CANDIDATES:
        network = ipaddress.ip_network(candidate)
        if not any(network.overlaps(other) for other in taken if other.version == 4 and other.prefixlen > 0): return candidate
    fail('no_free_subnet', 'No private bridge subnet is free on this machine.', 73)


def bridge_address(subnet):
    network = ipaddress.ip_network(subnet)
    return str(network.network_address+1)+'/'+str(network.prefixlen)


def render_daemon(layout, config):
    return {
        'hosts': ['unix://'+str(layout.socket)],
        'group': config['group'],
        'data-root': str(layout.data),
        'exec-root': str(layout.run/'exec'),
        'pidfile': str(layout.run/'docker.pid'),
        'bridge': layout.bridge,
        # This engine never edits iptables. Its egress and NAT rules live in
        # its own nftables table, which dockerd cannot flush. dockerd refuses
        # icc=false without iptables; the bridge table keeps bots apart instead.
        'iptables': False, 'ip6tables': False, 'ip-forward': False, 'ip-masq': False, 'ipv6': False,
        'userland-proxy': True,
        # Never set default-address-pools: with it (and live-restore off),
        # dockerd deletes the host's docker0 on every restart, whatever this
        # engine's own bridge is called. Bots use only the default bridge.
        'dns': DNS,
        'exec-opts': ['native.cgroupdriver=systemd'],
        'cgroup-parent': layout.slice,
        'log-driver': 'local', 'log-opts': {'max-size': '10m', 'max-file': '3'},
        'storage-driver': 'overlay2',
        'containerd': str(layout.containerd_socket),
    }


def render_containerd(layout):
    run = layout.run/'containerd'
    return f'''version = 2
root = "{layout.data/'containerd'}"
state = "{run/'state'}"
disabled_plugins = ["io.containerd.grpc.v1.cri"]
oom_score = -999

[grpc]
  address = "{layout.containerd_socket}"
  uid = 0
  gid = 0

[ttrpc]
  address = "{layout.containerd_socket}.ttrpc"

[debug]
  address = "{run/'debug.sock'}"

[metrics]
  address = ""
'''


def render_ruleset(layout, config, drop_foreign=False):
    """`drop_foreign`: this engine turned host forwarding on and no iptables
    holds the FORWARD policy, so it drops all other forwarding."""
    subnet = config['subnet']; bridge = layout.bridge
    blocked = ', '.join(BLOCKED_IPV4)
    foreign = f'\n    iifname != "{bridge}" oifname != "{bridge}" drop' if drop_foreign else ''
    # One atomic transaction: create-or-keep, delete, then define, so a reload
    # never leaves bots without their egress policy. Drops are final across
    # every table at a hook, so other firewalls' accepts cannot reopen them.
    # Frames bridged between two bot containers never reach the inet hooks;
    # the bridge table drops them, touching no other bridge on the machine.
    return f'''table inet {layout.table} {{}}
delete table inet {layout.table}
table bridge {layout.table} {{}}
delete table bridge {layout.table}
table bridge {layout.table} {{
  chain forward {{
    type filter hook forward priority filter - 10; policy accept;
    meta ibrname "{bridge}" meta obrname "{bridge}" drop
  }}
}}
table inet {layout.table} {{
  set blocked4 {{ type ipv4_addr; flags interval; elements = {{ {blocked} }} }}
  chain forward {{
    type filter hook forward priority filter - 10; policy accept;
    iifname "{bridge}" meta nfproto ipv6 drop
    oifname "{bridge}" meta nfproto ipv6 drop
    oifname "{bridge}" ct state established,related accept
    oifname "{bridge}" drop
    iifname "{bridge}" ip saddr != {subnet} drop
    iifname "{bridge}" ip daddr @blocked4 drop{foreign}
  }}
  chain input {{
    type filter hook input priority filter - 10; policy accept;
    iifname "{bridge}" ct state established,related accept
    iifname "{bridge}" drop
  }}
  chain postrouting {{
    type nat hook postrouting priority srcnat + 10; policy accept;
    ip saddr {subnet} oifname != "{bridge}" masquerade
  }}
}}
'''


def render_units(layout, config, python):
    helper = f'{python} -I {layout.helper}' + (f' --instance {layout.instance}' if layout.instance else '')
    pool = 'infinity' if config.get('poolBytes') is None else str(config['poolBytes'])
    return {
        layout.slice: f'''[Unit]
Description=Woven Matter bots memory pool
Before=slices.target

[Slice]
MemoryAccounting=yes
MemoryMax={pool}
''',
        layout.mount: f'''[Unit]
Description=Woven Matter bots storage

[Mount]
What={layout.image}
Where={layout.data}
Type=ext4
Options=loop,discard,noatime

[Install]
WantedBy=multi-user.target
''',
        layout.firewall: f'''[Unit]
Description=Woven Matter bots egress policy
After=network-pre.target nftables.service
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={helper} firewall

[Install]
WantedBy=multi-user.target
''',
        layout.containerd: f'''[Unit]
Description=Woven Matter bots containerd
After=local-fs.target network.target
RequiresMountsFor={layout.data}

[Service]
Type=notify
Slice={layout.slice}
Environment=PATH={layout.docker_current}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart={layout.docker_current}/containerd --config {layout.containerd_config}
RuntimeDirectory={layout.name}/containerd
RuntimeDirectoryPreserve=yes
Restart=always
RestartSec=3
Delegate=yes
KillMode=process
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity
OOMScoreAdjust=-999
''',
        layout.service: f'''[Unit]
Description=Woven Matter bots engine
After=network-online.target {layout.firewall} {layout.containerd}
Wants=network-online.target {layout.firewall}
Requires={layout.containerd}
RequiresMountsFor={layout.data}

[Service]
Type=notify
Slice={layout.slice}
Environment=PATH={layout.docker_current}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre={helper} prestart
ExecStart={layout.docker_current}/dockerd --config-file {layout.daemon}
ExecReload=/bin/kill -s HUP $MAINPID
RuntimeDirectory={layout.name}
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
TimeoutStartSec=180
TimeoutStopSec=90
Restart=always
RestartSec=3
StartLimitBurst=5
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
''',
        layout.apply_path: f'''[Unit]
Description=Woven Matter bots limits requests

[Path]
PathChanged={layout.request}
Unit={layout.apply_service}

[Install]
WantedBy=multi-user.target
''',
        layout.apply_service: f'''[Unit]
Description=Apply Woven Matter bots limits

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart={helper} apply
''',
    }

# ---------------------------------------------------------------- the machine

class Host:
    """Commands, replaceable in a test."""
    def run(self, args, check=True, timeout=120, input=None):
        try:
            result = subprocess.run([str(a) for a in args], input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired):
            if check: fail('host_command_failed', 'A required command could not finish: '+str(args[0]))
            return subprocess.CompletedProcess(args, 127, b'', b'')
        if check and result.returncode:
            fail('host_command_failed', 'A required command failed: '+' '.join(str(a) for a in args[:3]))
        return result

    def which(self, name): return shutil.which(name, path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')


def text(result): return result.stdout.decode('utf8', 'replace').strip()


def write_root_file(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.'+path.name+'.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data if isinstance(data, bytes) else data.encode()); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temp, mode); os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError): os.unlink(temp)


def read_bytes(path):
    with contextlib.suppress(OSError): return Path(path).read_bytes()
    return None


def read_json(path, default=None):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return default


def total_memory():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemTotal:'): return int(line.split()[1])*1024
    fail('memory_unknown', 'This machine\'s memory size is unavailable.')


def filesystem(path):
    path = Path(path)
    while not path.exists(): path = path.parent
    info = os.statvfs(path)
    return {'totalBytes': info.f_blocks*info.f_frsize, 'freeBytes': info.f_bavail*info.f_frsize}


def existing_networks(host):
    values = []
    result = host.run(['ip', '-j', '-4', 'route', 'show', 'table', 'all'], check=False)
    with contextlib.suppress(ValueError):
        for route in json.loads(result.stdout or b'[]'):
            if route.get('dst') and route['dst'] != 'default': values.append(route['dst'])
    result = host.run(['ip', '-j', '-4', 'addr'], check=False)
    with contextlib.suppress(ValueError):
        for link in json.loads(result.stdout or b'[]'):
            for entry in link.get('addr_info', []): values.append(entry['local']+'/'+str(entry['prefixlen']))
    return values


def account(user):
    try: entry = pwd.getpwnam(user)
    except KeyError: fail('unknown_user', 'The account '+str(user)+' does not exist on this machine.', 67)
    if entry.pw_uid == 0: fail('root_account_unsupported', 'Bots run for a regular account.', 78)
    group = grp.getgrgid(entry.pw_gid)
    # The socket is root-equivalent. Its group must contain only this account.
    others = [name for name in group.gr_mem if name != user]
    others += [p.pw_name for p in pwd.getpwall() if p.pw_gid == entry.pw_gid and p.pw_name != user]
    if others: fail('shared_primary_group', 'This account\'s primary group is shared, so it cannot own the bots\' engine socket.', 78)
    return entry, group.gr_name

# ---------------------------------------------------------------- the engine

class Engine:
    def __init__(self, layout, host=None, python=None):
        self.layout = layout; self.host = host or Host(); self.python = python or sys.executable
        self.forwarding = Path('/proc/sys/net/ipv4/ip_forward')

    def config(self, required=True):
        value = read_json(self.layout.config)
        if value is None and required: fail('engine_not_installed', 'The bots\' engine is not installed.', 66)
        return value

    def save_config(self, config): write_root_file(self.layout.config, json.dumps(config, indent=2, sort_keys=True)+'\n')

    def systemctl(self, *args, check=True): return self.host.run(['systemctl', *args], check=check, timeout=240)

    def active(self, unit): return self.systemctl('is-active', '--quiet', unit, check=False).returncode == 0

    def write_units(self, config):
        units = render_units(self.layout, config, self.python)
        for name, content in units.items(): write_root_file(self.layout.units/name, content)
        write_root_file(self.layout.daemon, json.dumps(render_daemon(self.layout, config), indent=2)+'\n')
        write_root_file(self.layout.containerd_config, render_containerd(self.layout))
        self.systemctl('daemon-reload')

    def install_docker(self):
        machine = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}.get(platform.machine())
        if not machine: fail('unsupported_architecture', 'Bots need an x86_64 or arm64 machine.', 78)
        version, sha256 = DOCKER_VERSION, DOCKER_SHA256[machine]
        target = self.layout.docker_root/version
        if not ((target/'dockerd').is_file() and (target/'.sha256').is_file() and (target/'.sha256').read_text().strip() == sha256):
            with tempfile.TemporaryDirectory(dir=self.layout.lib) as temp:
                local = Path(temp)/'docker.tgz'
                url = 'https://download.docker.com/linux/static/stable/'+machine+'/docker-'+version+'.tgz'
                try:
                    with urllib.request.urlopen(url, timeout=600) as response, local.open('wb') as stream:
                        shutil.copyfileobj(response, stream)
                except OSError as error:
                    fail('docker_download_failed', 'Docker Engine '+version+' could not be downloaded: '+str(error), 69)
                if hashlib.sha256(local.read_bytes()).hexdigest() != sha256:
                    fail('docker_checksum_mismatch', 'The Docker Engine archive failed SHA-256 verification.', 78)
                stage = Path(temp)/'docker'; stage.mkdir()
                with tarfile.open(local, 'r:gz') as bundle:
                    for member in bundle.getmembers():
                        path = PurePosixPath(member.name)
                        if member.isdir() and path.as_posix() == 'docker': continue
                        if not member.isfile() or len(path.parts) != 2 or path.parts[0] != 'docker' or not re.fullmatch(r'[a-z0-9-]+', path.parts[1]):
                            fail('unsafe_docker_archive', 'The Docker Engine archive holds an unexpected entry.', 78)
                        output = stage/path.parts[1]
                        with output.open('xb') as stream: shutil.copyfileobj(bundle.extractfile(member), stream)
                        output.chmod(0o755)
                for binary in ('dockerd', 'containerd', 'containerd-shim-runc-v2', 'runc', 'docker-init', 'docker-proxy'):
                    if not (stage/binary).is_file(): fail('invalid_docker_archive', 'The Docker Engine archive is incomplete.', 78)
                (stage/'.sha256').write_text(sha256+'\n')
                if target.exists(): shutil.rmtree(target)
                stage.chmod(0o755); os.replace(stage, target)
        link = self.layout.docker_current; temporary = link.with_name('.current.'+str(os.getpid()))
        with contextlib.suppress(FileNotFoundError): temporary.unlink()
        temporary.symlink_to(version); os.replace(temporary, link)
        for other in self.layout.docker_root.iterdir():
            if other.name not in (version, 'current') and other.is_dir() and not other.is_symlink(): shutil.rmtree(other)

    def install(self, user, pool, disk):
        if os.geteuid() != 0: fail('root_required', 'Installing the bots\' engine needs root: run it with sudo.', 77)
        layout = self.layout; entry, group = account(user)
        for binary in ('nft', 'ip', 'mkfs.ext4', 'resize2fs', 'e2fsck', 'losetup', 'systemctl'):
            if not self.host.which(binary): fail('missing_tool', 'The bots\' engine needs '+binary+' on this machine.', 69)
        if not Path('/sys/fs/cgroup/cgroup.controllers').exists(): fail('cgroup_v2_required', 'The bots\' engine needs the unified cgroup hierarchy.', 69)
        interpreter = Path(self.python).resolve()
        if interpreter.stat().st_uid != 0 or interpreter.stat().st_mode & 0o022:
            fail('unsafe_interpreter', 'The Python that runs the bots\' engine units must be root-owned.', 78)
        existing = self.config(required=False)
        if existing and existing['user'] != user: fail('engine_owner_conflict', 'This bots\' engine belongs to the account '+existing['user']+'.', 73)
        for directory, mode in ((layout.lib, 0o755), (layout.docker_root, 0o755), (layout.etc, 0o755), (layout.var, 0o711), (layout.state.parent, 0o755)):
            directory.mkdir(parents=True, exist_ok=True); os.chown(directory, 0, 0); directory.chmod(mode)
        layout.requests.mkdir(exist_ok=True); os.chown(layout.requests, 0, entry.pw_gid); layout.requests.chmod(0o770)
        # Changed binaries or configuration restart the engine; an unchanged
        # reinstall leaves running bots alone.
        def fingerprint():
            digest = hashlib.sha256()
            for path in (layout.daemon, layout.containerd_config, layout.units/layout.service, layout.units/layout.containerd):
                digest.update((read_bytes(path) or b'')+b'\0')
            digest.update(os.path.realpath(layout.docker_current).encode())
            return digest.hexdigest()
        was_active = self.active(layout.service)
        self.install_docker()
        # The installed helper is a root-owned copy; units never run the account's files.
        write_root_file(layout.helper, Path(__file__).read_bytes(), 0o755)
        config = {'user': user, 'uid': entry.pw_uid, 'group': group, 'gid': entry.pw_gid,
            'subnet': existing['subnet'] if existing else choose_subnet(existing_networks(self.host)),
            'socket': str(layout.socket), 'dockerVersion': DOCKER_VERSION,
            'ipForwardWasEnabled': existing['ipForwardWasEnabled'] if existing else self.forwarding.read_text().strip() == '1',
            'poolBytes': existing.get('poolBytes') if existing else None, 'diskBytes': existing.get('diskBytes') if existing else None}
        if pool is not None or not existing: config['poolBytes'] = normalize_pool(pool, total_memory())
        if disk is not None or not existing: config['diskBytes'] = normalize_disk(disk, filesystem(layout.var)['totalBytes'])
        self.save_config(config)
        self.write_units(config)
        self.systemctl('enable', '--now', layout.firewall)
        self.apply_settings({'poolBytes': config['poolBytes'], 'diskBytes': config['diskBytes']}, start=True)
        self.systemctl('enable', '--now', layout.apply_path)
        self.systemctl('enable', layout.mount, layout.containerd, layout.service)
        if was_active and fingerprint() != (read_json(layout.state, {}) or {}).get('engineFingerprint'):
            self.systemctl('restart', layout.containerd, layout.service)
        self.wait_ready()
        self.record_state({'engineFingerprint': fingerprint()})
        return self.status()

    def wait_ready(self, deadline=90):
        stop = time.monotonic()+deadline
        while time.monotonic() < stop:
            if self.active(self.layout.service) and self.layout.socket.is_socket(): return
            time.sleep(.5)
        fail('engine_start_failed', 'The bots\' engine did not start: see journalctl -u '+self.layout.service, 70)

    def image_size(self):
        with contextlib.suppress(OSError): return self.layout.image.stat().st_size
        return None

    def loop_device(self):
        match = re.match(r'(/dev/loop\d+):', text(self.host.run(['losetup', '-j', str(self.layout.image)], check=False)))
        return match.group(1) if match else None

    def minimum_image_bytes(self):
        # Offline estimate of the smallest filesystem that holds what is stored.
        estimate = text(self.host.run(['resize2fs', '-P', str(self.layout.image)], check=False))
        header = text(self.host.run(['dumpe2fs', '-h', str(self.layout.image)], check=False))
        blocks = re.search(r'minimum size of the filesystem:\s*(\d+)', estimate)
        size = re.search(r'Block size:\s*(\d+)', header)
        if not blocks or not size: fail('disk_estimate_failed', 'What the bots store could not be measured.', 70)
        minimum = int(int(blocks.group(1))*int(size.group(1))*1.1)+512*MiB
        return max(MINIMUM_DISK, minimum+(-minimum) % (4*MiB))

    def apply_settings(self, requested, start=False):
        """Applies the pool and the disk cap. No cap is an image as large as
        the filesystem that holds it; the image is sparse either way."""
        layout = self.layout; config = self.config()
        pool, disk = requested['poolBytes'], requested['diskBytes']
        notes = []
        config['poolBytes'] = pool
        self.save_config(config); self.write_units(config)
        self.systemctl('set-property', '--runtime', layout.slice, 'MemoryMax='+('infinity' if pool is None else str(pool)), check=False)
        active = self.active(layout.service)
        want = round_image(disk if disk is not None else filesystem(layout.var)['totalBytes'])
        current = self.image_size()
        if current is None:
            with layout.image.open('xb') as stream: stream.truncate(want)
            layout.image.chmod(0o600)
            self.host.run(['mkfs.ext4', '-q', '-F', '-m', '0', '-L', ('wvbots'+(layout.instance or ''))[:16], str(layout.image)], timeout=600)
        elif want > current:
            with layout.image.open('r+b') as stream: stream.truncate(want)
            device = self.loop_device()
            if device and self.active(layout.mount):
                self.host.run(['losetup', '-c', device]); self.host.run(['resize2fs', device], timeout=3600)
            else:
                self.host.run(['e2fsck', '-f', '-p', str(layout.image)], check=False, timeout=3600)
                self.host.run(['resize2fs', str(layout.image)], timeout=3600)
        elif want < current:
            # containerd keeps its root on the data mount too.
            self.systemctl('stop', layout.service, layout.containerd, check=False)
            if self.active(layout.mount): self.systemctl('stop', layout.mount)
            self.host.run(['e2fsck', '-f', '-p', str(layout.image)], check=False, timeout=3600)
            size = max(want, self.minimum_image_bytes())
            if size < current:
                self.host.run(['resize2fs', str(layout.image), str(size//1024)+'K'], timeout=3600)
                with layout.image.open('r+b') as stream: stream.truncate(size)
            if size > want: notes.append('The disk cap stops at what the bots already store.')
        config['diskBytes'] = disk
        self.save_config(config)
        layout.data.mkdir(mode=0o710, exist_ok=True)
        if not self.active(layout.mount): self.systemctl('start', layout.mount)
        if active or start: self.systemctl('start', layout.service)
        return notes

    def apply_request(self):
        """The path unit's entry: the request file is the account's."""
        layout = self.layout; config = self.config()
        try:
            fd = os.open(layout.request, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError: return self.status()
        except OSError: fail('invalid_request', 'The bots\' limits request is unsafe.', 78)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, config['uid']) or info.st_size > REQUEST_LIMIT:
                fail('invalid_request', 'The bots\' limits request is invalid.', 78)
            raw = os.read(fd, REQUEST_LIMIT+1)
        finally: os.close(fd)
        try:
            request = json.loads(raw)
            if not isinstance(request, dict) or set(request)-{'revision', 'poolBytes', 'diskBytes'}: raise ValueError()
            revision = request['revision']
            if not isinstance(revision, str) or not re.fullmatch(r'[A-Za-z0-9-]{1,64}', revision): raise ValueError()
        except (ValueError, KeyError):
            self.record_state({'requestError': 'invalid_request', 'requestDetail': 'The bots\' limits request is invalid.'})
            return self.status()
        if (read_json(layout.state, {}) or {}).get('appliedRevision') == revision: return self.status()
        try:
            notes = self.apply_settings({'poolBytes': normalize_pool(request.get('poolBytes'), total_memory()),
                'diskBytes': normalize_disk(request.get('diskBytes'), filesystem(layout.var)['totalBytes'])})
            self.record_state({'appliedRevision': revision, 'requestError': None, 'requestDetail': None, 'notes': notes})
        except Failure as error:
            self.record_state({'appliedRevision': revision, 'requestError': error.code, 'requestDetail': error.detail})
        return self.status()

    def record_state(self, changes):
        state = read_json(self.layout.state, {}) or {}
        state.update(changes); state['updatedAt'] = time.time()
        write_root_file(self.layout.state, json.dumps(state, sort_keys=True)+'\n')

    def firewall(self):
        layout = self.layout; config = self.config(); marker = layout.run/'forwarding-enabled'
        # Bots need host-wide IPv4 forwarding. When nothing else had turned it
        # on, this engine owns what that does to the machine's other
        # interfaces: like dockerd, it sets the FORWARD policy to DROP; with no
        # iptables, its own table drops other forwarding. The marker in /run
        # keeps that until the next boot.
        owned = marker.exists() or self.forwarding.read_text().strip() != '1'
        iptables = self.host.which('iptables')
        self.host.run(['nft', '-f', '-'], input=render_ruleset(layout, config, drop_foreign=owned and not iptables).encode())
        if iptables:
            self.accept_forwarding(config)
            if owned: self.host.run(['iptables', '-w', '-P', 'FORWARD', 'DROP'])
        if self.forwarding.read_text().strip() != '1':
            layout.run.mkdir(mode=0o755, parents=True, exist_ok=True); marker.write_text('1\n')
            self.forwarding.write_text('1\n')
        self.record_state({'firewallAppliedAt': time.time()})

    def accept_forwarding(self, config):
        # Machines whose FORWARD policy is DROP (any Docker install sets this)
        # must still pass bot internet traffic. Woven's nft drops run first, so
        # this chain only accepts what the egress policy already allowed.
        chain = self.layout.chain; bridge = self.layout.bridge; run = self.host.run
        if run(['iptables', '-w', '-S', chain], check=False).returncode: run(['iptables', '-w', '-N', chain])
        run(['iptables', '-w', '-F', chain])
        run(['iptables', '-w', '-A', chain, '-o', bridge, '-m', 'conntrack', '--ctstate', 'RELATED,ESTABLISHED', '-j', 'ACCEPT'])
        run(['iptables', '-w', '-A', chain, '-i', bridge, '-s', config['subnet'], '!', '-o', bridge, '-j', 'ACCEPT'])
        if run(['iptables', '-w', '-C', 'FORWARD', '-j', chain], check=False).returncode: run(['iptables', '-w', '-I', 'FORWARD', '1', '-j', chain])

    def prestart(self):
        layout = self.layout; config = self.config(); run = self.host.run
        if run(['ip', 'link', 'show', 'dev', layout.bridge], check=False).returncode:
            run(['ip', 'link', 'add', 'name', layout.bridge, 'type', 'bridge'])
        run(['ip', 'addr', 'replace', bridge_address(config['subnet']), 'dev', layout.bridge])
        run(['ip', 'link', 'set', 'dev', layout.bridge, 'up'])
        # Never start dockerd without the egress policy in place.
        self.firewall()
        if not self.active(layout.mount): fail('storage_unmounted', 'The bots\' storage image is not mounted.', 70)

    def remove_firewall(self):
        run = self.host.run
        run(['nft', 'delete', 'table', 'inet', self.layout.table], check=False)
        run(['nft', 'delete', 'table', 'bridge', self.layout.table], check=False)
        if self.host.which('iptables'):
            while run(['iptables', '-w', '-C', 'FORWARD', '-j', self.layout.chain], check=False).returncode == 0:
                run(['iptables', '-w', '-D', 'FORWARD', '-j', self.layout.chain], check=False)
            run(['iptables', '-w', '-F', self.layout.chain], check=False); run(['iptables', '-w', '-X', self.layout.chain], check=False)

    def uninstall(self):
        """Stops the engine and removes it with everything the bots stored in it."""
        if os.geteuid() != 0: fail('root_required', 'Removing the bots\' engine needs root: run it with sudo.', 77)
        layout = self.layout; config = self.config(required=False) or {}
        for unit in (layout.apply_path, layout.apply_service, layout.service, layout.containerd, layout.firewall, layout.mount):
            self.systemctl('disable', '--now', unit, check=False)
        self.systemctl('stop', layout.slice, check=False)
        for name in layout.unit_names():
            with contextlib.suppress(FileNotFoundError): (layout.units/name).unlink()
        for control in (Path('/etc/systemd/system.control'), Path('/run/systemd/system.control')):
            shutil.rmtree(control/(layout.slice+'.d'), ignore_errors=True)
        self.systemctl('daemon-reload', check=False)
        self.systemctl('reset-failed', *layout.unit_names(), check=False)
        self.remove_firewall()
        self.host.run(['ip', 'link', 'delete', 'dev', layout.bridge], check=False)
        if config and not config.get('ipForwardWasEnabled', True) and not Path('/sys/class/net/docker0').exists():
            with contextlib.suppress(OSError): self.forwarding.write_text('0\n')
        for path in (layout.var, layout.etc, layout.lib, layout.run):
            if path.is_symlink(): path.unlink()
            elif path.exists(): shutil.rmtree(path)
        return {'removed': True, 'name': layout.name}

    def status(self):
        layout = self.layout; config = self.config(required=False)
        if not config: return {'installed': False, 'name': layout.name}
        state = read_json(layout.state, {}) or {}
        used = None
        with contextlib.suppress(OSError):
            if os.path.ismount(layout.data):
                info = os.statvfs(layout.data); used = (info.f_blocks-info.f_bfree)*info.f_frsize
        return {'installed': True, 'name': layout.name, 'running': self.active(layout.service),
            'socket': str(layout.socket), 'user': config['user'], 'dockerVersion': config.get('dockerVersion'),
            'bridge': layout.bridge, 'subnet': config['subnet'], 'slice': layout.slice,
            'poolBytes': config.get('poolBytes'), 'diskBytes': config.get('diskBytes'), 'diskImageBytes': self.image_size(),
            'diskUsedBytes': used, 'memoryTotalBytes': total_memory(), **filesystem(layout.var),
            'appliedRevision': state.get('appliedRevision'), 'requestError': state.get('requestError'),
            'requestDetail': state.get('requestDetail'), 'notes': state.get('notes') or []}


def main(argv):
    # Root-owned files must be readable by the account's server.
    os.umask(0o022)
    instance = None
    if len(argv) >= 2 and argv[0] == '--instance': instance, argv = argv[1], argv[2:]
    if not argv: fail('invalid_command', 'usage: bots-engine.py install --user NAME [--pool BYTES|none] [--disk BYTES|none] | uninstall | status', 64)
    command, *rest = argv; options = {}
    while rest:
        key = rest.pop(0)
        if not key.startswith('--') or not rest: fail('invalid_command', 'Invalid arguments.', 64)
        options[key[2:]] = rest.pop(0)
    engine = Engine(Layout(instance))
    if command == 'install':
        if 'user' not in options or set(options)-{'user', 'pool', 'disk'}: fail('invalid_command', 'usage: install --user NAME [--pool BYTES|none] [--disk BYTES|none]', 64)
        return engine.install(options['user'], options.get('pool'), options.get('disk'))
    if options: fail('invalid_command', 'Invalid arguments.', 64)
    if command == 'uninstall': return engine.uninstall()
    if command == 'status': return engine.status()
    if os.geteuid() != 0: fail('root_required', 'This command runs from the engine\'s systemd units.', 77)
    if command == 'apply': return engine.apply_request()
    if command == 'firewall': engine.firewall(); return {'firewall': True}
    if command == 'prestart': engine.prestart(); return {'ready': True}
    fail('invalid_command', 'Unknown command '+command+'.', 64)


if __name__ == '__main__':
    try: print(json.dumps(main(sys.argv[1:]), separators=(',', ':')), flush=True)
    except Failure as error:
        print(json.dumps({'error': error.code, 'detail': error.detail}), file=sys.stderr)
        raise SystemExit(error.status)
