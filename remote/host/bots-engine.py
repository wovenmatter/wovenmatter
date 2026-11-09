#!/usr/bin/env python3
"""Woven Matter's own Docker Engine instance for bots on Linux.

The privileged half of the bots capability. `remote-host.sh` runs `install`
once with the account's existing noninteractive sudo. Afterwards the installed
root-owned copy runs only from systemd units: the engine's ExecStartPre, the
firewall unit, and a path-activated unit that applies resource settings the
Woven server requests through a group-writable file. No sudoers rule is added.

Everything lives under one instance name (production: `wovenmatter`), so a test
instance can run side by side with it and with any Docker the user already
runs. The user's Docker, its units, chains and /etc/docker are never read or
changed: this dockerd uses its own config file, socket, data root, exec root,
pidfile, bridge and managed containerd, and its own nftables table.
"""
import contextlib, grp, hashlib, ipaddress, json, os, pwd, re, shutil, stat, subprocess, sys, tarfile, tempfile, time
from pathlib import Path, PurePosixPath

GiB = 1024**3
MiB = 1024**2
MINIMUM_DISK = 2*GiB
MINIMUM_POOL = 1*GiB
REQUEST_LIMIT = 4096
# Outbound destinations a bot may never reach. IPv6 is not routed for bots at
# all, which covers the tailnet's fd7a:115c:a1e0::/48, ULA and link-local.
BLOCKED_IPV4 = ['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12',
    '192.0.0.0/24','192.0.2.0/24','192.168.0.0/16','198.18.0.0/15','198.51.100.0/24','203.0.113.0/24','224.0.0.0/4','240.0.0.0/4']
SUBNET_CANDIDATES = [f'10.{n}.0.0/16' for n in range(237,252)]
# Public resolvers: host resolvers are usually loopback, LAN or MagicDNS
# addresses, all of which the egress policy blocks.
DNS = ['1.1.1.1','8.8.8.8']

class Failure(Exception):
    def __init__(self,code,detail,status=69): super().__init__(detail); self.code,self.detail,self.status=code,detail,status

def fail(code,detail,status=69): raise Failure(code,detail,status)

def valid_instance(name):
    if not re.fullmatch(r'[a-z][a-z0-9]{1,15}',name or ''): fail('invalid_instance','Use a short lowercase engine instance name.',64)
    return name

class Layout:
    """Every path and unit name derived from one instance name."""
    def __init__(self,instance='wovenmatter',root='/'):
        self.instance=valid_instance(instance); r=Path(root)
        self.lib=r/'usr/local/lib'/(instance+'-bots')
        self.helper=self.lib/'bots-engine'
        self.docker_root=self.lib/'docker'
        self.docker_current=self.docker_root/'current'
        self.etc=r/'etc'/(instance+'-bots')
        self.config=self.etc/'instance.json'
        self.daemon=self.etc/'daemon.json'
        self.var=r/'var/lib'/(instance+'-bots')
        self.image=self.var/'disk.img'
        self.data=self.var/'docker'
        self.requests=self.var/'requests'
        self.request=self.requests/'settings.json'
        self.state_dir=self.var/'state'
        self.state=self.state_dir/'state.json'
        self.run=r/'run'/instance
        self.socket=self.run/'docker.sock'
        self.units=r/'etc/systemd/system'
        self.service=instance+'-docker.service'
        # Its own containerd: dockerd would otherwise join a system containerd
        # (/run/containerd) and share the user's Docker "moby" namespace.
        self.containerd=instance+'-containerd.service'
        self.containerd_config=self.etc/'containerd.toml'
        self.containerd_socket=self.run/'containerd/containerd.sock'
        self.slice=instance+'-bots.slice'
        self.firewall=instance+'-bots-firewall.service'
        self.apply_path=instance+'-bots-apply.path'
        self.apply_service=instance+'-bots-apply.service'
        self.mount=systemd_escape_path(str(Path('/')/self.data.relative_to(r)))+'.mount'
        # Docker-style name: host firewalls that admit container bridges
        # commonly match br-*. The user's Docker manages only bridges it made.
        self.bridge='br-wovenbots' if instance=='wovenmatter' else 'br-'+instance[:12]
        self.table=instance+'_bots'
        self.chain=(instance.upper()+'-BOTS')[:28]
    def unit_names(self):
        return [self.service,self.containerd,self.slice,self.firewall,self.apply_path,self.apply_service,self.mount]

def systemd_escape_path(path):
    # systemd-escape --path, without requiring the binary in tests.
    trimmed=path.strip('/')
    if not trimmed: return '-'
    out=[]
    for index,ch in enumerate(trimmed):
        if ch=='/': out.append('-')
        elif ch.isalnum() or ch in '_:' or (ch=='.' and index>0): out.append(ch)
        else: out.append('\\x%02x'%ord(ch))
    return ''.join(out)

# ---------------------------------------------------------------- rendering

def size_or_none(value,label):
    if value in (None,'none','null'): return None
    if isinstance(value,bool): fail('invalid_size','Invalid '+label+'.',64)
    if isinstance(value,str):
        if not value.isdigit(): fail('invalid_size','Invalid '+label+'.',64)
        value=int(value)
    if not isinstance(value,int) or value<=0 or value>2**62: fail('invalid_size','Invalid '+label+'.',64)
    return value

def normalize_pool(value,total_memory):
    value=size_or_none(value,'RAM pool')
    if value is None: return None
    if value<MINIMUM_POOL: fail('pool_too_small','The bot RAM pool must be at least 1 GB.',64)
    return min(value,total_memory)

def normalize_disk(value,total_disk):
    value=size_or_none(value,'disk cap')
    if value is None: return None
    if value<MINIMUM_DISK: fail('disk_too_small','The bot disk cap must be at least 2 GB.',64)
    value=min(value,total_disk)
    return value-value%(4*MiB)

def choose_subnet(existing):
    """First candidate /16 that overlaps no existing route or address."""
    taken=[]
    for value in existing:
        with contextlib.suppress(ValueError): taken.append(ipaddress.ip_network(value,strict=False))
    for candidate in SUBNET_CANDIDATES:
        network=ipaddress.ip_network(candidate)
        if not any(network.overlaps(other) for other in taken if other.version==4 and other.prefixlen>0): return candidate
    fail('no_free_subnet','No private bridge subnet is free on this host.',73)

def bridge_address(subnet):
    network=ipaddress.ip_network(subnet)
    return str(network.network_address+1)+'/24'

def render_daemon(layout,config):
    return {
        'hosts':['unix://'+str(layout.socket)],
        'group':config['group'],
        'data-root':str(layout.data),
        'exec-root':str(layout.run/'exec'),
        'pidfile':str(layout.run/'docker.pid'),
        'bridge':layout.bridge,
        # This engine never edits iptables. Its egress and NAT rules live in
        # the Woven-owned nftables table below, which dockerd cannot flush.
        'iptables':False,'ip6tables':False,'ip-forward':False,'ip-masq':False,'ipv6':False,
        'userland-proxy':True,
        # Never set default-address-pools: with it (and live-restore off),
        # dockerd deletes the host's docker0 on every restart, whatever this
        # engine's own bridge is called (moby configureNetworking). Bots use
        # only the default bridge; the runtime creates no networks.
        'dns':DNS,
        'exec-opts':['native.cgroupdriver=systemd'],
        'cgroup-parent':layout.slice,
        'log-driver':'local','log-opts':{'max-size':'10m','max-file':'3'},
        'storage-driver':'overlay2',
        'containerd':str(layout.containerd_socket),
    }

def render_containerd(layout):
    run=layout.run/'containerd'
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

def render_ruleset(layout,config):
    subnet=config['subnet']; bridge=layout.bridge
    blocked=', '.join(BLOCKED_IPV4)
    # One atomic transaction: create-or-keep, delete, then define, so a reload
    # never leaves bots without their egress policy. Drops are final across
    # every table at a hook, so other firewalls' accepts cannot reopen them.
    return f'''table inet {layout.table} {{}}
delete table inet {layout.table}
table inet {layout.table} {{
  set blocked4 {{ type ipv4_addr; flags interval; elements = {{ {blocked} }} }}
  chain forward {{
    type filter hook forward priority filter - 10; policy accept;
    iifname "{bridge}" meta nfproto ipv6 drop
    oifname "{bridge}" meta nfproto ipv6 drop
    oifname "{bridge}" ct state established,related accept
    oifname "{bridge}" drop
    iifname "{bridge}" ip saddr != {subnet} drop
    iifname "{bridge}" ip daddr @blocked4 drop
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

def render_units(layout,config,python):
    helper=f'{python} -I {layout.helper} --instance {layout.instance}'
    pool='infinity' if config.get('poolBytes') is None else str(config['poolBytes'])
    mount_dependency=f'RequiresMountsFor={layout.data}\n' if config.get('diskBytes') is not None else ''
    units={
        layout.slice:f'''[Unit]
Description=Woven Matter bots memory pool
Before=slices.target

[Slice]
MemoryAccounting=yes
MemoryMax={pool}
''',
        layout.firewall:f'''[Unit]
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
        layout.containerd:f'''[Unit]
Description=Woven Matter bot engine containerd
After=local-fs.target network.target
{mount_dependency}
[Service]
Type=notify
Slice={layout.slice}
Environment=PATH={layout.docker_current}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart={layout.docker_current}/containerd --config {layout.containerd_config}
RuntimeDirectory={layout.instance}/containerd
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
        layout.service:f'''[Unit]
Description=Woven Matter bot engine
After=network-online.target {layout.firewall} {layout.containerd}
Wants=network-online.target {layout.firewall}
Requires={layout.containerd}
{mount_dependency}
[Service]
Type=notify
Slice={layout.slice}
Environment=PATH={layout.docker_current}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre={helper} prestart
ExecStart={layout.docker_current}/dockerd --config-file {layout.daemon}
ExecReload=/bin/kill -s HUP $MAINPID
RuntimeDirectory={layout.instance}
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
        layout.apply_path:f'''[Unit]
Description=Woven Matter bots settings requests

[Path]
PathChanged={layout.request}
Unit={layout.apply_service}

[Install]
WantedBy=multi-user.target
''',
        layout.apply_service:f'''[Unit]
Description=Apply Woven Matter bots settings

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart={helper} apply
''',
    }
    if config.get('diskBytes') is not None:
        units[layout.mount]=f'''[Unit]
Description=Woven Matter bots storage

[Mount]
What={layout.image}
Where={layout.data}
Type=ext4
Options=loop,discard,noatime

[Install]
WantedBy=multi-user.target
'''
    return units

# ---------------------------------------------------------------- host access

class Host:
    """Command and filesystem access, replaced by a recorder in tests."""
    def run(self,args,check=True,timeout=120,input=None):
        try:
            result=subprocess.run([str(a) for a in args],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
        except (OSError,subprocess.TimeoutExpired):
            if check: fail('host_command_failed','A required host command could not finish: '+str(args[0]))
            return subprocess.CompletedProcess(args,127,b'',b'')
        if check and result.returncode:
            fail('host_command_failed','A required host command failed: '+' '.join(str(a) for a in args[:3]))
        return result
    def which(self,name): return shutil.which(name,path='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')

def text(result): return result.stdout.decode('utf8','replace').strip()

def write_root_file(path,data,mode=0o644):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data if isinstance(data,bytes) else data.encode()); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temp,mode); os.replace(temp,path)
    finally:
        with contextlib.suppress(FileNotFoundError): os.unlink(temp)

def read_bytes(path):
    with contextlib.suppress(OSError): return Path(path).read_bytes()
    return None

def read_json(path,default=None):
    try: return json.loads(Path(path).read_text())
    except (OSError,ValueError): return default

def total_memory():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemTotal:'): return int(line.split()[1])*1024
    fail('memory_unknown','The host memory size is unavailable.')

def filesystem(path):
    path=Path(path)
    while not path.exists(): path=path.parent
    info=os.statvfs(path)
    return {'totalBytes':info.f_blocks*info.f_frsize,'freeBytes':info.f_bavail*info.f_frsize}

def existing_networks(host):
    values=[]
    for family in ('-4',):
        result=host.run(['ip','-j',family,'route','show','table','all'],check=False)
        with contextlib.suppress(ValueError):
            for route in json.loads(result.stdout or b'[]'):
                if route.get('dst') and route['dst']!='default': values.append(route['dst'])
        result=host.run(['ip','-j',family,'addr'],check=False)
        with contextlib.suppress(ValueError):
            for link in json.loads(result.stdout or b'[]'):
                for address in link.get('addr_info',[]): values.append(address['local']+'/'+str(address['prefixlen']))
    return values

def account(user):
    try: entry=pwd.getpwnam(user)
    except KeyError: fail('unknown_user','The Woven account does not exist on this host.',67)
    if entry.pw_uid==0: fail('root_account_unsupported','Bots run for a regular account.',78)
    group=grp.getgrgid(entry.pw_gid)
    # The socket is root-equivalent. Its group must contain only this account.
    others=[name for name in group.gr_mem if name!=user]
    others+=[p.pw_name for p in pwd.getpwall() if p.pw_gid==entry.pw_gid and p.pw_name!=user]
    if others: fail('shared_primary_group','This account’s primary group is shared, so it cannot own the bot engine socket.',78)
    return entry,group.gr_name

# ---------------------------------------------------------------- operations

class Engine:
    def __init__(self,layout,host=None,python=None):
        self.layout=layout; self.host=host or Host(); self.python=python or sys.executable
    def config(self,required=True):
        value=read_json(self.layout.config)
        if value is None and required: fail('engine_not_installed','The Woven bot engine is not installed.',66)
        return value
    def save_config(self,config): write_root_file(self.layout.config,json.dumps(config,indent=2,sort_keys=True)+'\n')
    def systemctl(self,*args,check=True): return self.host.run(['systemctl',*args],check=check,timeout=240)

    def write_units(self,config):
        units=render_units(self.layout,config,self.python)
        for name in self.layout.unit_names():
            path=self.layout.units/name
            if name in units: write_root_file(path,units[name])
            else:
                with contextlib.suppress(FileNotFoundError): path.unlink()
        write_root_file(self.layout.daemon,json.dumps(render_daemon(self.layout,config),indent=2)+'\n')
        write_root_file(self.layout.containerd_config,render_containerd(self.layout))
        self.systemctl('daemon-reload')

    def install_docker(self,archive,version,sha256):
        if not re.fullmatch(r'\d+\.\d+\.\d+',version or '') or not re.fullmatch(r'[a-f0-9]{64}',sha256 or ''):
            fail('invalid_runtime_record','Invalid pinned Docker Engine record.',78)
        target=self.layout.docker_root/version
        if (target/'dockerd').is_file() and (target/'.sha256').is_file() and (target/'.sha256').read_text().strip()==sha256:
            target.chmod(0o755); return target
        with tempfile.TemporaryDirectory(dir=self.layout.lib) as temp:
            # Copy the caller's download into root-owned space before verifying.
            local=Path(temp)/'docker.tgz'; shutil.copyfile(archive,local)
            if hashlib.sha256(local.read_bytes()).hexdigest()!=sha256: fail('docker_checksum_mismatch','The pinned Docker Engine archive failed SHA-256 verification.',78)
            stage=Path(temp)/'docker'; stage.mkdir()
            with tarfile.open(local,'r:gz') as bundle:
                for member in bundle.getmembers():
                    path=PurePosixPath(member.name)
                    if member.isdir() and path.as_posix()=='docker': continue
                    if not member.isfile() or len(path.parts)!=2 or path.parts[0]!='docker' or not re.fullmatch(r'[a-z0-9-]+',path.parts[1]):
                        fail('unsafe_docker_archive','The Docker Engine archive contains an unexpected entry.',78)
                    output=stage/path.parts[1]
                    with output.open('xb') as stream: shutil.copyfileobj(bundle.extractfile(member),stream)
                    output.chmod(0o755)
            for binary in ('dockerd','containerd','containerd-shim-runc-v2','runc','docker-init','docker-proxy'):
                if not (stage/binary).is_file(): fail('invalid_docker_archive','The Docker Engine archive is incomplete.',78)
            (stage/'.sha256').write_text(sha256+'\n')
            if target.exists(): shutil.rmtree(target)
            stage.chmod(0o755); os.replace(stage,target)
        link=self.layout.docker_current; temporary=link.with_name('.current.'+str(os.getpid()))
        with contextlib.suppress(FileNotFoundError): temporary.unlink()
        temporary.symlink_to(version); os.replace(temporary,link)
        for other in self.layout.docker_root.iterdir():
            if other.name not in (version,'current') and other.is_dir() and not other.is_symlink(): shutil.rmtree(other)
        return target

    def install(self,user,pool,disk,archive,version,sha256):
        if os.geteuid()!=0: fail('root_required','Installing the bot engine requires administrative access.',77)
        layout=self.layout; entry,group=account(user)
        for binary in ('nft','ip','mkfs.ext4','resize2fs','e2fsck','losetup','systemctl'):
            if not self.host.which(binary): fail('missing_host_tool','The bot engine needs '+binary+' on this host.',69)
        if not Path('/sys/fs/cgroup/cgroup.controllers').exists(): fail('cgroup_v2_required','The bot engine requires the unified cgroup hierarchy.',69)
        interpreter=Path(self.python).resolve()
        if interpreter.stat().st_uid!=0 or interpreter.stat().st_mode&0o022: fail('unsafe_interpreter','The system Python used by the bot engine units must be root-owned.',78)
        existing=self.config(required=False)
        if existing and existing['user']!=user: fail('engine_owner_conflict','This bot engine belongs to another account.',73)
        for directory,mode in ((layout.lib,0o755),(layout.docker_root,0o755),(layout.etc,0o755),(layout.var,0o711),(layout.state_dir,0o755)):
            directory.mkdir(parents=True,exist_ok=True); os.chown(directory,0,0); directory.chmod(mode)
        layout.requests.mkdir(exist_ok=True); os.chown(layout.requests,0,entry.pw_gid); layout.requests.chmod(0o770)
        # An update that changes the engine's binaries or configuration must
        # restart it; an unchanged reinstall leaves running bots alone.
        # The recorded fingerprint is of the files the running engine started
        # with, so an interrupted earlier update is still applied.
        def engine_fingerprint():
            digest=hashlib.sha256()
            for path in (layout.daemon,layout.containerd_config,layout.units/layout.service,layout.units/layout.containerd):
                digest.update((read_bytes(path) or b'')+b'\0')
            digest.update(os.path.realpath(layout.docker_current).encode())
            return digest.hexdigest()
        was_active=self.systemctl('is-active','--quiet',layout.service,check=False).returncode==0
        self.install_docker(archive,version,sha256)
        # The installed helper is a root-owned copy; units never run user files.
        write_root_file(layout.helper,Path(__file__).read_bytes(),0o755)
        memory=total_memory(); storage=filesystem(layout.var)
        ip_forward=Path('/proc/sys/net/ipv4/ip_forward').read_text().strip()=='1'
        config={'schemaVersion':1,'instance':layout.instance,'user':user,'uid':entry.pw_uid,'group':group,'gid':entry.pw_gid,
            'subnet':existing['subnet'] if existing else choose_subnet(existing_networks(self.host)),
            'bridge':layout.bridge,'socket':str(layout.socket),'dockerVersion':version,
            'ipForwardWasEnabled':existing.get('ipForwardWasEnabled',ip_forward) if existing else ip_forward,
            'poolBytes':existing.get('poolBytes') if existing else None,'diskBytes':existing.get('diskBytes') if existing else None}
        self.save_config(config)
        self.write_units(config)
        self.systemctl('enable','--now',layout.firewall)
        self.apply_settings({'poolBytes':normalize_pool(pool,memory),'diskBytes':normalize_disk(disk,storage['totalBytes'])},start=True)
        self.systemctl('enable','--now',layout.apply_path)
        self.systemctl('enable',layout.containerd,layout.service)
        applied=(read_json(layout.state,{}) or {}).get('engineFingerprint')
        if was_active and engine_fingerprint()!=applied: self.systemctl('restart',layout.containerd,layout.service)
        self.wait_ready()
        self.record_state({'engineFingerprint':engine_fingerprint()})
        return self.status()

    def image_size(self):
        with contextlib.suppress(OSError): return self.layout.image.stat().st_size
        return None

    def wait_ready(self,deadline=90):
        stop=time.monotonic()+deadline
        while time.monotonic()<stop:
            if self.systemctl('is-active','--quiet',self.layout.service,check=False).returncode==0 and self.layout.socket.is_socket(): return
            time.sleep(.5)
        fail('engine_start_failed','The Woven bot engine did not start.',70)

    def mounted(self):
        return self.systemctl('is-active','--quiet',self.layout.mount,check=False).returncode==0

    def loop_device(self):
        value=text(self.host.run(['losetup','-j',str(self.layout.image)],check=False))
        match=re.match(r'(/dev/loop\d+):',value)
        return match.group(1) if match else None

    def used_bytes(self):
        if not self.layout.data.exists(): return 0
        info=os.statvfs(self.layout.data)
        if self.layout.image.exists() and self.mounted(): return (info.f_blocks-info.f_bfree)*info.f_frsize
        result=self.host.run(['du','-sxB1',str(self.layout.data)],check=False,timeout=600)
        with contextlib.suppress(ValueError,IndexError): return int(text(result).split()[0])
        return 0

    def minimum_image_bytes(self):
        # Offline estimate of the smallest filesystem holding current data.
        estimate=text(self.host.run(['resize2fs','-P',str(self.layout.image)],check=False))
        header=text(self.host.run(['dumpe2fs','-h',str(self.layout.image)],check=False))
        blocks=re.search(r'minimum size of the filesystem:\s*(\d+)',estimate)
        size=re.search(r'Block size:\s*(\d+)',header)
        if not blocks or not size: fail('disk_estimate_failed','The current bot storage size could not be measured.',70)
        minimum=int(blocks.group(1))*int(size.group(1))
        minimum=int(minimum*1.1)+512*MiB
        return max(MINIMUM_DISK,minimum+(-minimum)%(4*MiB))

    def copy_tree(self,source,destination):
        # GNU cp -a keeps overlay whiteouts, xattrs, hard links and sparseness.
        self.host.run(['cp','-a','--sparse=always',str(source)+'/.',str(destination)],timeout=24*3600)

    def apply_settings(self,requested,start=False):
        """Apply pool and disk idempotently. Returns the effective settings."""
        layout=self.layout; config=self.config()
        pool=requested['poolBytes']; disk=requested['diskBytes']
        active=self.systemctl('is-active','--quiet',layout.service,check=False).returncode==0
        notes=[]
        # Pool: unit file for boot, runtime property for the running slice.
        value='infinity' if pool is None else str(pool)
        config['poolBytes']=pool
        self.save_config(config); self.write_units(config)
        self.systemctl('set-property','--runtime',layout.slice,'MemoryMax='+value,check=False)
        current=config.get('diskBytes')
        if disk!=current or (disk is not None and self.image_size()!=disk):
            if current is not None and disk is not None and disk>=(self.image_size() or 0):
                self.grow(disk)
            else:
                if active: self.systemctl('stop',layout.service,layout.containerd)
                if current is None and disk is not None: disk=self.to_image(disk)
                elif current is not None and disk is None: self.to_directory()
                elif disk is not None: disk=self.shrink(disk)
                if disk is not None and disk!=requested['diskBytes']: notes.append('The disk cap stops at the space bots already use.')
            config['diskBytes']=disk; self.save_config(config); self.write_units(config)
        if disk is not None and not self.mounted(): self.systemctl('start',layout.mount)
        if disk is None: layout.data.mkdir(mode=0o710,exist_ok=True)
        if active or start: self.systemctl('start',layout.service)
        return {'poolBytes':pool,'diskBytes':disk,'notes':notes}

    def grow(self,size):
        layout=self.layout
        with layout.image.open('r+b') as stream: stream.truncate(size)
        device=self.loop_device()
        if device and self.mounted():
            self.host.run(['losetup','-c',device]); self.host.run(['resize2fs',device],timeout=3600)
        else:
            self.host.run(['e2fsck','-f','-p',str(layout.image)],check=False,timeout=3600)
            self.host.run(['resize2fs',str(layout.image)],timeout=3600)

    def shrink(self,size):
        layout=self.layout
        if self.mounted(): self.systemctl('stop',layout.mount)
        self.host.run(['e2fsck','-f','-p',str(layout.image)],check=False,timeout=3600)
        size=max(size,self.minimum_image_bytes())
        if size<layout.image.stat().st_size:
            self.host.run(['resize2fs',str(layout.image),str(size//1024)+'K'],timeout=3600)
            with layout.image.open('r+b') as stream: stream.truncate(size)
        return layout.image.stat().st_size

    def new_image(self,size):
        layout=self.layout
        with layout.image.open('xb') as stream: stream.truncate(size)
        layout.image.chmod(0o600)
        self.host.run(['mkfs.ext4','-q','-F','-m','0','-L',(layout.instance+'bots')[:16],str(layout.image)],timeout=600)

    def to_image(self,size):
        layout=self.layout; used=self.used_bytes()
        size=max(size,MINIMUM_DISK,int(used*1.1)+512*MiB); size+=(-size)%(4*MiB)
        if layout.image.exists(): layout.image.unlink()
        self.new_image(size)
        has_data=layout.data.exists() and any(layout.data.iterdir())
        if has_data:
            staging=layout.var/'migrate'; staging.mkdir(exist_ok=True)
            self.host.run(['mount','-o','loop',str(layout.image),str(staging)])
            try: self.copy_tree(layout.data,staging)
            finally: self.host.run(['umount',str(staging)],check=False)
            staging.rmdir()
            shutil.rmtree(layout.data)
        layout.data.mkdir(mode=0o710,exist_ok=True)
        return size

    def to_directory(self):
        layout=self.layout
        if not self.mounted(): self.systemctl('start',layout.mount)
        staging=layout.var/'docker.new'
        if staging.exists(): shutil.rmtree(staging)
        staging.mkdir(mode=0o710)
        self.copy_tree(layout.data,staging)
        self.systemctl('stop',layout.mount)
        with contextlib.suppress(FileNotFoundError): (layout.units/layout.mount).unlink()
        self.systemctl('daemon-reload')
        layout.data.rmdir(); os.replace(staging,layout.data)
        layout.image.unlink()

    def apply_request(self):
        """Path-unit entry: the request file is written by the Woven account."""
        layout=self.layout; config=self.config()
        try:
            fd=os.open(layout.request,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        except FileNotFoundError: return self.status()
        except OSError: fail('invalid_request','The bots settings request is unsafe.',78)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0,config['uid']) or info.st_size>REQUEST_LIMIT: fail('invalid_request','The bots settings request is invalid.',78)
            raw=os.read(fd,REQUEST_LIMIT+1)
        finally: os.close(fd)
        state=read_json(layout.state,{}) or {}
        try:
            request=json.loads(raw)
            if not isinstance(request,dict) or set(request)-{'revision','poolBytes','diskBytes'}: raise ValueError()
            revision=request['revision']
            if not isinstance(revision,str) or not re.fullmatch(r'[A-Za-z0-9-]{1,64}',revision): raise ValueError()
        except (ValueError,KeyError):
            self.record_state({'requestError':'invalid_request'}); return self.status()
        if state.get('appliedRevision')==revision: return self.status()
        try:
            memory=total_memory(); storage=filesystem(layout.var)
            result=self.apply_settings({'poolBytes':normalize_pool(request.get('poolBytes'),memory),
                'diskBytes':normalize_disk(request.get('diskBytes'),storage['totalBytes'])})
            self.record_state({'appliedRevision':revision,'requestError':None,'notes':result['notes']})
        except Failure as error:
            self.record_state({'appliedRevision':revision,'requestError':error.code,'requestDetail':error.detail})
        return self.status()

    def record_state(self,changes):
        state=read_json(self.layout.state,{}) or {}
        state.update(changes); state['updatedAt']=time.time()
        write_root_file(self.layout.state,json.dumps(state,sort_keys=True)+'\n')

    def firewall(self):
        layout=self.layout; config=self.config()
        self.host.run(['nft','-f','-'],input=render_ruleset(layout,config).encode())
        if self.host.which('iptables'): self.accept_forwarding(config)
        if Path('/proc/sys/net/ipv4/ip_forward').read_text().strip()!='1':
            Path('/proc/sys/net/ipv4/ip_forward').write_text('1\n')
        self.record_state({'firewallAppliedAt':time.time(),'firewallTable':'inet '+layout.table})

    def accept_forwarding(self,config):
        # Hosts whose FORWARD policy is DROP (any Docker install sets this)
        # must still pass bot internet traffic. Woven's nft drops run first, so
        # this chain only accepts what the egress policy already allowed.
        chain=self.layout.chain; bridge=self.layout.bridge; run=self.host.run
        if run(['iptables','-w','-S',chain],check=False).returncode: run(['iptables','-w','-N',chain])
        run(['iptables','-w','-F',chain])
        run(['iptables','-w','-A',chain,'-o',bridge,'-m','conntrack','--ctstate','RELATED,ESTABLISHED','-j','ACCEPT'])
        run(['iptables','-w','-A',chain,'-i',bridge,'-s',config['subnet'],'!','-o',bridge,'-j','ACCEPT'])
        if run(['iptables','-w','-C','FORWARD','-j',chain],check=False).returncode: run(['iptables','-w','-I','FORWARD','1','-j',chain])

    def prestart(self):
        layout=self.layout; config=self.config(); run=self.host.run
        if run(['ip','link','show','dev',layout.bridge],check=False).returncode:
            run(['ip','link','add','name',layout.bridge,'type','bridge'])
        run(['ip','addr','replace',bridge_address(config['subnet']),'dev',layout.bridge])
        run(['ip','link','set','dev',layout.bridge,'up'])
        # Never start dockerd without the egress policy in place.
        self.firewall()
        if config.get('diskBytes') is not None and not self.mounted(): fail('storage_unmounted','The bot storage image is not mounted.',70)
        layout.data.mkdir(mode=0o710,exist_ok=True)

    def remove_firewall(self):
        run=self.host.run
        run(['nft','delete','table','inet',self.layout.table],check=False)
        if self.host.which('iptables'):
            while run(['iptables','-w','-C','FORWARD','-j',self.layout.chain],check=False).returncode==0:
                run(['iptables','-w','-D','FORWARD','-j',self.layout.chain],check=False)
            run(['iptables','-w','-F',self.layout.chain],check=False); run(['iptables','-w','-X',self.layout.chain],check=False)

    def uninstall(self,user=None):
        if os.geteuid()!=0: fail('root_required','Removing the bot engine requires administrative access.',77)
        layout=self.layout; config=self.config(required=False) or {}
        if user and config.get('user') not in (None,user): fail('engine_owner_conflict','This bot engine belongs to another account.',73)
        for unit in (layout.apply_path,layout.apply_service,layout.service,layout.containerd,layout.firewall,layout.mount):
            self.systemctl('disable','--now',unit,check=False)
        self.systemctl('stop',layout.slice,check=False)
        # The implicit parent slice stays loaded; stop it only when it is ours alone.
        parent=Path('/sys/fs/cgroup')/(layout.instance+'.slice')
        with contextlib.suppress(OSError):
            if not [p for p in parent.iterdir() if p.is_dir() and p.name!=layout.slice]: self.systemctl('stop',layout.instance+'.slice',check=False)
        with contextlib.suppress(OSError):
            if layout.image.exists(): self.host.run(['umount',str(layout.data)],check=False)
        for name in layout.unit_names():
            with contextlib.suppress(FileNotFoundError): (layout.units/name).unlink()
        control=Path('/etc/systemd/system.control')
        for name in (layout.slice,):
            shutil.rmtree(control/(name+'.d'),ignore_errors=True)
            shutil.rmtree(Path('/run/systemd/system.control')/(name+'.d'),ignore_errors=True)
        self.systemctl('daemon-reload',check=False)
        self.systemctl('reset-failed',*[n for n in layout.unit_names()],check=False)
        self.remove_firewall()
        self.host.run(['ip','link','delete','dev',layout.bridge],check=False)
        if config and not config.get('ipForwardWasEnabled',True) and not Path('/sys/class/net/docker0').exists():
            with contextlib.suppress(OSError): Path('/proc/sys/net/ipv4/ip_forward').write_text('0\n')
        for path in (layout.var,layout.etc,layout.lib,layout.run):
            if path.is_symlink(): path.unlink()
            elif path.exists(): shutil.rmtree(path)
        return {'removed':True,'instance':layout.instance}

    def status(self):
        layout=self.layout; config=self.config(required=False)
        if not config: return {'installed':False,'instance':layout.instance}
        active=self.systemctl('is-active',layout.service,check=False)
        state=read_json(layout.state,{}) or {}
        storage=filesystem(layout.var)
        used=None
        with contextlib.suppress(OSError):
            if layout.data.is_dir() and config.get('diskBytes') is not None and os.path.ismount(layout.data):
                info=os.statvfs(layout.data); used=(info.f_blocks-info.f_bfree)*info.f_frsize
        memory=None
        with contextlib.suppress(OSError,ValueError):
            memory=int(Path('/sys/fs/cgroup',*slice_path(layout.slice),'memory.current').read_text())
        return {'installed':True,'instance':layout.instance,'state':text(active) or 'inactive','running':text(active)=='active',
            'socket':str(layout.socket),'socketReady':layout.socket.is_socket(),'user':config['user'],'dockerVersion':config.get('dockerVersion'),
            'bridge':layout.bridge,'subnet':config['subnet'],'slice':layout.slice,
            'poolBytes':config.get('poolBytes'),'diskBytes':config.get('diskBytes'),'diskImageBytes':self.image_size(),
            'diskUsedBytes':used,'memoryUsedBytes':memory,'memoryTotalBytes':total_memory(),
            'hostDiskTotalBytes':storage['totalBytes'],'hostDiskFreeBytes':storage['freeBytes'],'dataPath':str(layout.var),
            'appliedRevision':state.get('appliedRevision'),'requestError':state.get('requestError'),'notes':state.get('notes') or [],
            'firewallAppliedAt':state.get('firewallAppliedAt')}

def slice_path(name):
    # systemd nests a-b-c.slice under a.slice/a-b.slice/.
    stem=name[:-len('.slice')]; parts=stem.split('-')
    return ['-'.join(parts[:i+1])+'.slice' for i in range(len(parts))]

def main(argv):
    # Root-owned files must be readable by the account's units and server.
    os.umask(0o022)
    instance='wovenmatter'
    if len(argv)>=2 and argv[0]=='--instance': instance,argv=argv[1],argv[2:]
    if not argv: fail('invalid_command','A bot engine command is required.',64)
    command,*rest=argv; options={}
    while rest:
        key=rest.pop(0)
        if not key.startswith('--') or not rest: fail('invalid_command','Invalid bot engine arguments.',64)
        options[key[2:]]=rest.pop(0)
    engine=Engine(Layout(instance))
    if command=='install':
        required={'user','pool','disk','docker-archive','docker-version','docker-sha256'}
        if set(options)!=required: fail('invalid_command','Invalid bot engine install arguments.',64)
        return engine.install(options['user'],options['pool'],options['disk'],options['docker-archive'],options['docker-version'],options['docker-sha256'])
    if options and command!='uninstall': fail('invalid_command','Invalid bot engine arguments.',64)
    if command=='uninstall': return engine.uninstall(options.get('user'))
    if command=='status': return engine.status()
    if os.geteuid()!=0: fail('root_required','This bot engine command runs from its systemd units.',77)
    if command=='apply': return engine.apply_request()
    if command=='firewall': engine.firewall(); return {'firewall':True}
    if command=='prestart': engine.prestart(); return {'ready':True}
    fail('invalid_command','Unknown bot engine command.',64)

if __name__=='__main__':
    try: print(json.dumps(main(sys.argv[1:]),separators=(',',':')),flush=True)
    except Failure as error:
        print(json.dumps({'error':error.code,'detail':error.detail}),file=sys.stderr)
        raise SystemExit(error.status)
