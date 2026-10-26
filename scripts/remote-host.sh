#!/usr/bin/env bash
set -euo pipefail
umask 077
# Runs through the existing Tailnet SSH transport. For install/update invoke with
# bash -c (not bash -s): fd 3 carries one credential line followed by the tar.
command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' '{"error":"python_missing","detail":"Install Python 3 on this Linux host before setup."}' >&2
  exit 69
}
exec 3<&0
exec python3 - "$@" <<'PY'
import contextlib, fcntl, glob, hashlib, io, json, os, platform, pwd, re, shutil, socket, stat, subprocess, sys, tarfile, tempfile, time, urllib.request
from pathlib import Path, PurePosixPath

HOME=Path.home()
ROOT=HOME/'.local/share/wovenmatter'
CONFIG=HOME/'.config/wovenmatter'
ENV_FILE=CONFIG/'service.env'
UNIT=HOME/'.config/systemd/user/wovenmatter.service'
RECORD=ROOT/'installation.json'
TOKEN=os.environ.pop('WOVENMATTER_API_TOKEN','')
UNIT_NAME='wovenmatter.service'
RC_FILES=['.bashrc','.bash_profile','.bash_login','.profile','.zshrc','.zprofile','.zshenv','.config/fish/config.fish']
HARNESS_CONFIGS=['.codex','.claude','.claude.json','.config/opencode','.grok']

class Failure(Exception):
    def __init__(self,code,detail,status=69): self.code,self.detail,self.status=code,detail,status

def fail(code,detail,status=69): raise Failure(code,detail,status)
def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)
def progress(phase): print('WM_PROGRESS '+phase,file=sys.stderr,flush=True)
def run(args,*,check=False,timeout=30,env=None,input=None):
    try:
        p=subprocess.run([str(a) for a in args],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                         timeout=timeout,env=env,stdin=subprocess.DEVNULL if input is None else None)
    except (OSError,subprocess.TimeoutExpired):
        if check: fail('host_command_failed','A required host command could not finish: '+str(args[0]))
        return subprocess.CompletedProcess(args,127,b'',b'')
    if check and p.returncode:
        # Package installers and journals may contain arbitrary text. Diagnostics
        # deliberately name the command without reflecting credentials or argv.
        fail('host_command_failed','A required host command failed: '+str(args[0]))
    return p

def text(result): return result.stdout.decode('utf8','replace').strip()
def valid_id(value):
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,47}',value): fail('invalid_workspace_id','Use a 1-48 character lowercase workspace identifier.',64)
def valid_port(value):
    if not str(value).isdigit() or not 1024<=int(value)<=65535: fail('invalid_loopback_port','The loopback port must be between 1024 and 65535.',64)
    return int(value)
def valid_mode(value):
    if value not in ('fullRoot','user'): fail('invalid_access_mode','Choose Full root or Normal user permissions.',64)
    return value

def owned_directory(path):
    path=Path(path)
    # Reject symlinks at every account-owned path component, not just the leaf.
    current=HOME
    try: parts=path.relative_to(HOME).parts
    except ValueError: fail('unsafe_host_path','Host data must remain under this account home.',78)
    for part in parts:
        current=current/part
        if current.is_symlink(): fail('unsafe_host_path','Host installation directories must not be symlinks.',78)
        if current.exists() and (not current.is_dir() or current.stat().st_uid!=os.getuid()):
            fail('unsafe_host_path','Host installation directories must be owned by the SSH account.',78)
        current.mkdir(mode=0o700,exist_ok=True)
    path.chmod(0o700)

def private_file(path,data):
    owned_directory(path.parent)
    if path.is_symlink(): fail('unsafe_host_path','Host configuration files must not be symlinks.',78)
    fd,temp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temp,path)
    finally:
        with contextlib.suppress(FileNotFoundError): os.unlink(temp)

@contextlib.contextmanager
def lifecycle_lock():
    base=Path(os.environ.get('XDG_RUNTIME_DIR','/tmp'))/('wovenmatter-host-'+str(os.getuid()))
    if base.is_symlink(): fail('unsafe_lock_directory','The lifecycle lock directory is unsafe.',78)
    base.mkdir(mode=0o700,exist_ok=True)
    if not base.is_dir() or base.stat().st_uid!=os.getuid(): fail('unsafe_lock_directory','The lifecycle lock directory is not owned by this account.',78)
    base.chmod(0o700)
    fd=os.open(base/'lifecycle.lock',os.O_WRONLY|os.O_CREAT|getattr(os,'O_NOFOLLOW',0),0o600)
    try:
        deadline=time.monotonic()+15
        while True:
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic()>deadline: fail('workspace_busy','Another host lifecycle operation is running.',75)
                time.sleep(.1)
        yield
    finally: os.close(fd)

def record(required=False):
    try:
        if RECORD.is_symlink(): fail('unsafe_host_path','The installation record is unsafe.',78)
        result=json.loads(RECORD.read_text())
        valid_id(result['id']); valid_port(result['port']); valid_mode(result['accessMode'])
        if not re.fullmatch('[a-f0-9]{64}',result['fingerprint']): raise ValueError()
        return result
    except FileNotFoundError:
        if required: fail('workspace_not_found','No native workspace is installed for this account.',66)
        return None
    except (ValueError,KeyError,TypeError): fail('invalid_installation_record','The host installation record requires repair.',78)

def require_owner(workspace_id):
    valid_id(workspace_id); installed=record(True)
    if installed['id']!=workspace_id: fail('host_workspace_conflict','A different native workspace already belongs to this host account.',73)
    return installed

def parse_env():
    if ENV_FILE.is_symlink(): fail('unsafe_host_path','The host environment is unsafe.',78)
    try:
        info=ENV_FILE.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077: raise ValueError()
        result={}
        for line in ENV_FILE.read_text().splitlines():
            if not line or line.startswith('#'): continue
            key,sep,value=line.partition('=')
            if not sep or not re.fullmatch('[A-Z][A-Z0-9_]*',key): raise ValueError()
            decoded=json.loads(value)
            if not isinstance(decoded,str) or any(c in decoded for c in ('\0','\r','\n')): raise ValueError()
            result[key]=decoded
        return result
    except (OSError,ValueError): fail('invalid_service_environment','The private host environment is unavailable or invalid.',78)

def os_release():
    result={}
    try:
        for line in Path(os.environ.get('WOVENMATTER_OS_RELEASE','/etc/os-release')).read_text().splitlines():
            key,sep,value=line.partition('=')
            if sep: result[key]=value.strip('"\'')
    except OSError: pass
    return result

def user_manager(): return run(['systemctl','--user','show-environment']).returncode==0
def linger(): return text(run(['loginctl','show-user',str(os.getuid()),'--property=Linger','--value']))=='yes'
def unrestricted_root():
    # Prove arbitrary administrative commands are possible, without changing the
    # host or trusting sudo's localized rule listing. No credentials are entered.
    return os.getuid()!=0 and text(run(['sudo','-n','/bin/sh','-c','id -u']))=='0'
def apparmor_restriction():
    try: return int(Path('/proc/sys/kernel/apparmor_restrict_unprivileged_userns').read_text().strip())
    except (OSError,ValueError): return None

def harness_path():
    candidates=[HOME/'.local/bin',HOME/'.npm-global/bin',HOME/'.bun/bin',HOME/'.cargo/bin',
        HOME/'.local/share/mise/shims',HOME/'.asdf/shims',HOME/'.nvm/current/bin',Path('/usr/local/bin')]
    # nvm usually has no current symlink. Include installed versions in newest
    # order; do not run its shell function or source any login/startup files.
    candidates += sorted((HOME/'.nvm/versions/node').glob('v*/bin'),reverse=True)
    candidates += [Path(p) for p in sorted(glob.glob('/opt/*/bin'))]
    candidates += [Path(p) for p in os.environ.get('PATH','/usr/bin:/bin').split(':') if p.startswith('/')]
    return list(dict.fromkeys(str(p) for p in candidates if p.is_dir()))

def inventory(paths):
    result=[]
    try: ownership=json.loads((ROOT/'workspace/.wovenmatter/runtime-preferences.json').read_text())
    except (OSError,ValueError): ownership={}
    specs=[('codex','codex','codex-acp',['codex','login','status']),
           ('claude_code','claude','claude-agent-acp',['claude','auth','status','--json']),
           ('grok_build','grok','grok',['grok','models']),('opencode','opencode','opencode',None)]
    path=':'.join(paths)
    for identity,cli,adapter,status_args in specs:
        components=[]
        for label,command in [('cli',cli),('adapter',adapter)]:
            found=shutil.which(command,path=path)
            component='signin' if label=='cli' and cli!=adapter else 'runtime'
            owned=ownership.get(identity,{}).get('managedComponents',{}).get(component,{})
            managed=bool(found and owned.get('path')==found and owned.get('target')==str(Path(found).resolve()))
            components.append({'id':label,'path':found,'source':'missing' if not found else 'managed' if managed else 'system'})
        status=None
        if components[0]['path'] and status_args:
            checked=run([components[0]['path'],*status_args[1:]],timeout=10,env={**os.environ,'PATH':path})
            logged_in=checked.returncode==0
            if identity=='grok_build': logged_in=logged_in and 'You are logged in' in text(checked)
            status={'exitCode':checked.returncode,'authenticated':logged_in}
        result.append({'id':identity,'cli':components[0],'adapter':components[1],'status':status})
    return result

def tailscale_operator_ready():
    # Serve status is readable even when the account cannot change Serve. Query
    # only the existing operator preference; never return raw preferences or
    # credentials to the Mac, logs, or lifecycle JSON.
    checked=run(['tailscale','debug','prefs'],timeout=10)
    if checked.returncode: return None
    try:
        preferences=json.loads(checked.stdout)
        return preferences.get('OperatorUser','')==pwd.getpwuid(os.getuid()).pw_name
    except (ValueError,AttributeError): return None

def dependency_packages(distro):
    # Kept in sync with remote/host/deps/apt-{ubuntu,debian}.txt. Bootstrap
    # inspect/prepare are self-contained and cannot trust an installed release.
    common='libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0 libnspr4 libnss3 libpango-1.0-0 libwayland-client0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 libfontconfig1 libfreetype6 fonts-liberation fonts-noto-color-emoji util-linux python3 ca-certificates curl'.split()
    identity=distro.get('ID','')
    if identity in ('ubuntu','debian'):
        major=int(re.match(r'\d+',distro.get('VERSION_ID','0')).group())
        if (identity=='ubuntu' and major>=24) or (identity=='debian' and major>=13):
            converted={'libasound2','libatk-bridge2.0-0','libatk1.0-0','libatspi2.0-0','libcups2','libglib2.0-0'}
            common=[p+'t64' if p in converted else p for p in common]
        if identity=='ubuntu' and apparmor_restriction()==1 and not any(Path(p).is_file() for p in ('/usr/sbin/apparmor_parser','/sbin/apparmor_parser')) and not shutil.which('apparmor_parser'):
            common.append('apparmor')
        return common
    if identity in ('arch','omarchy') or 'arch' in distro.get('ID_LIKE','').split():
        return 'alsa-lib at-spi2-core cairo cups libcups dbus libdrm mesa glib2 nspr nss pango wayland libx11 libxcb libxcomposite libxdamage libxext libxfixes libxkbcommon libxrandr fontconfig freetype2 ttf-liberation noto-fonts-emoji util-linux python ca-certificates curl'.split()
    return []

def privileged_actions(distro):
    actions=[]
    if not linger(): actions.append(['loginctl','enable-linger',pwd.getpwuid(os.getuid()).pw_name])
    packages=dependency_packages(distro)
    if packages:
        if distro.get('ID') in ('ubuntu','debian'):
            missing=[p for p in packages if run(['dpkg-query','-W','-f=${db:Status-Status}',p]).stdout!=b'installed']
            if missing: actions += [['apt-get','update'],['apt-get','install','-y','--no-install-recommends',*missing]]
        else:
            missing=[p for p in packages if run(['pacman','-Q',p]).returncode]
            if missing: actions.append(['pacman','-S','--needed','--noconfirm',*missing])
    if distro.get('ID')=='ubuntu' and apparmor_restriction()==1:
        target='/etc/apparmor.d/wovenmatter-chromium-'+str(os.getuid())
        # Fixed profile content below; a stable version glob avoids sudo on updates.
        if not Path(target).exists():
            actions += [['install','-m','0644','<generated-user-Chromium-profile>',target],['apparmor_parser','-r',target]]
    if shutil.which('tailscale') and tailscale_operator_ready() is not True:
        actions.append(['tailscale','set','--operator='+pwd.getpwuid(os.getuid()).pw_name])
    return actions

def inspect(mode='user'):
    valid_mode(mode); distro=os_release(); paths=harness_path(); installed=record(); manager=user_manager(); elevated=unrestricted_root()
    architecture={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(platform.machine(),platform.machine())
    blockers=[]
    if platform.system()!='Linux': blockers.append('Native workspaces require Linux.')
    if architecture not in ('amd64','arm64'): blockers.append('Only amd64 and arm64 hosts are supported.')
    if not manager: blockers.append('A usable systemd user manager is required.')
    if os.getuid()==0: blockers.append('Connect as a regular Linux user; Full root uses that account’s existing unrestricted sudo access.')
    if mode=='fullRoot' and not elevated: blockers.append('Full root requires existing unrestricted passwordless sudo for this SSH account.')
    for binary,label in [('tailscale','Tailscale'),('script','util-linux script'),('setpriv','util-linux setpriv'),('curl','curl')]:
        if not shutil.which(binary) and (binary=='tailscale' or not dependency_packages(distro) or not elevated): blockers.append(label+' is missing.')
    actions=privileged_actions(distro)
    if actions and not elevated: blockers.append('Host preparation requires an account with existing noninteractive administrative access.')
    disk=shutil.disk_usage(HOME)
    containers=[]
    if shutil.which('docker') and run(['docker','info'],timeout=5).returncode==0:
        output=run(['docker','ps','--filter','name=wovenmatter-','--format','{{.Names}}|{{.Ports}}'],timeout=5)
        containers=[line for line in text(output).splitlines() if line]
    supported=distro.get('ID') in ('ubuntu','debian','arch','omarchy') or 'arch' in distro.get('ID_LIKE','').split()
    return {'ready':not blockers and not actions,'runtime':'host','kind':'host','version':distro.get('VERSION_ID','unknown'),
        'architecture':architecture,'capabilities':{'memory':False,'swap':False},'limitations':[] if supported else ['This Linux distribution is best-effort; browser self-test verifies its libraries and sandbox.'],
        'os':{'id':distro.get('ID','unknown'),'version':distro.get('VERSION_ID','unknown')},'systemdUser':manager,'linger':linger(),
        'sudoAvailable':elevated,'apparmorRestrictUnprivilegedUserns':apparmor_restriction(),'tailscaleInstalled':bool(shutil.which('tailscale')),
        'tailscaleOperatorReady':tailscale_operator_ready() if shutil.which('tailscale') else None,
        'scriptInstalled':bool(shutil.which('script')),'installation':installed,
        'workspaceID':installed['id'] if installed else None,'port':installed['port'] if installed else None,
        'fingerprint':installed['fingerprint'] if installed else None,'dataRoot':str(ROOT),'workspaceRoot':str(ROOT/'workspace'),
        'databasesDirectory':str(ROOT/'databases'),'attachmentsDirectory':str(ROOT/'workspace/.wovenmatter/attachments'),
        'containerPorts':containers,'harnesses':inventory(paths),'harnessPath':':'.join(paths),'bestEffort':not supported,
        'requiredPrivilegedActions':['sudo -n '+' '.join(shell_quote(a) for a in action) for action in actions],
        'preparationActions':['sudo -n '+' '.join(shell_quote(a) for a in action) for action in actions],
        'blockingIssues':blockers,'blockers':blockers,'canPrepare':elevated,'preparationRequired':bool(actions),
        'hostStorageCapacityBytes':disk.total,'hostStorageAvailableBytes':disk.free,'hostStorageLow':disk.free<10*1024**3,
        'storageWarning':'Less than 10 GiB of free host storage remains.' if disk.free<10*1024**3 else None}

def shell_quote(value):
    import shlex
    return shlex.quote(str(value))

def prepare(authorization,mode='user'):
    if authorization!='AUTHORIZED': fail('confirmation_required','Review and authorize the listed privileged commands first.',77)
    valid_mode(mode)
    distro=os_release(); actions=privileged_actions(distro)
    if actions and not unrestricted_root(): fail('sudo_unavailable','Preparation requires existing unrestricted noninteractive sudo.',77)
    progress('preparing')
    for action in actions:
        if action[0]=='install' and action[3]=='<generated-user-Chromium-profile>':
            if any(c in str(HOME) for c in ('"','\n','\r','\\','{','}','*','?','[',']')):
                fail('unsupported_home_path','This home path cannot be represented safely in the AppArmor profile.',78)
            profile=('abi <abi/4.0>,\ninclude <tunables/global>\nprofile wovenmatter-chromium-'+str(os.getuid())+' "'+str(ROOT)+'/browsers/playwright-*/**/chrome{,-headless-shell}" flags=(unconfined) {\n  userns,\n}\n')
            with tempfile.NamedTemporaryFile(mode='w') as tmp:
                tmp.write(profile); tmp.flush()
                run(['sudo','-n','install','-m','0644',tmp.name,action[-1]],check=True,timeout=60)
        else: run(['sudo','-n',*action],check=True,timeout=600)
    result=inspect(mode); result['prepared']=not result['preparationRequired'] and not result['blockingIssues']
    return result

def health(port,token):
    try:
        request=urllib.request.Request('http://127.0.0.1:'+str(port)+'/v1/health',headers={'Authorization':'Bearer '+token})
        with urllib.request.urlopen(request,timeout=3) as response: return json.load(response)
    except (OSError,ValueError): return None

def status(workspace_id):
    installed=require_owner(workspace_id); settings=parse_env()
    active=text(run(['systemctl','--user','is-active',UNIT_NAME])); running=active=='active'
    state=health(installed['port'],settings.get('WOVENMATTER_API_TOKEN','')) if running else None
    disk=shutil.disk_usage(ROOT)
    browser=None
    try: browser=json.loads((ROOT/'run/browser-selftest.json').read_text())
    except (OSError,ValueError): pass
    return {'id':workspace_id,'name':'wovenmatter-'+workspace_id,'state':'running' if running else active or 'inactive','systemdState':active,'running':running,
        'health':'healthy' if state else 'unhealthy' if running else None,'startedAt':text(run(['systemctl','--user','show',UNIT_NAME,'--property=ActiveEnterTimestamp','--value'])),
        'image':'native-host:'+installed['fingerprint'],'memoryBytes':0,'swapBytes':0,'swapMode':'default','hostPort':installed['port'],
        'persistentVolume':str(ROOT),'capabilities':{'memory':False,'swap':False},'storageKind':'host','storageUsedBytes':None,
        'hostStorageCapacityBytes':disk.total,'hostStorageAvailableBytes':disk.free,'hostStorageLow':disk.free<10*1024**3,
        'storageWarning':None,'legacyStorage':False,'kind':'host','linger':linger(),'fingerprint':installed['fingerprint'],
        'dataRoot':str(ROOT),'workspaceRoot':str(ROOT/'workspace'),'databasesDirectory':str(ROOT/'databases'),
        'attachmentsDirectory':str(ROOT/'workspace/.wovenmatter/attachments'),'accessMode':installed['accessMode'],'browserSelfTest':browser}

def safe_extract(archive_path,target,expected=None):
    # Validate the entire archive BEFORE creating any extracted paths. All links
    # and special files are rejected, including duplicate directory entries.
    with tarfile.open(archive_path,'r:*') as archive:
        seen=set(); members=archive.getmembers(); total=0
        for member in members:
            path=PurePosixPath(member.name)
            if path.is_absolute() or not path.parts or path.as_posix()=='.' or member.name.rstrip('/')!=path.as_posix() or any(p in ('..','') for p in path.parts) or '\\' in member.name or member.name in seen:
                fail('unsafe_bundle','The source bundle contains an unsafe or duplicate path.',78)
            if not member.isfile() and not member.isdir():
                if expected is not None or not (member.issym() or member.islnk()): fail('unsafe_bundle','The source bundle contains a link or special file.',78)
                import posixpath
                link=PurePosixPath(member.linkname)
                resolved=posixpath.normpath(str(path.parent/link) if member.issym() else member.linkname)
                if link.is_absolute() or resolved=='..' or resolved.startswith('../') or PurePosixPath(resolved).parts[0]!=path.parts[0]:
                    fail('unsafe_bundle','The runtime archive contains an escaping link.',78)
            if path.as_posix() in seen: fail('unsafe_bundle','The source bundle contains duplicate normalized paths.',78)
            seen.add(path.as_posix()); total+=member.size
            if member.size>512*1024**2 or total>2*1024**3: fail('bundle_too_large','The host source bundle exceeds its size limit.',78)
        manifest=None
        if expected is not None:
            try:
                manifest=json.load(archive.extractfile('manifest.json'))
                if manifest['fingerprint']!=expected: raise ValueError()
                records=manifest['files']
                regular={m.name for m in members if m.isfile()}
                if regular!=set(records)|{'manifest.json'}: raise ValueError()
                source_records={}
                for name,entry in records.items():
                    content=archive.extractfile(name).read()
                    if hashlib.sha256(content).hexdigest()!=entry['sha256']: raise ValueError()
                    source=entry['sourcePath']; source_mode=entry['sourceMode']
                    if source in source_records or not isinstance(source_mode,int) or source_mode&~0o111: raise ValueError()
                    if PurePosixPath(source).is_absolute() or '..' in PurePosixPath(source).parts: raise ValueError()
                    if source in ('remote/npm-runtime/package.json','remote/npm-runtime/package-lock.json'): canonical=source[len('remote/'):]
                    elif source=='remote/package.json': canonical='package.json'
                    elif source.startswith('remote/src/'): canonical=source[len('remote/'):]
                    elif source=='remote/host/bin/wm-exec': canonical='bin/wm-exec'
                    elif source.startswith('remote/host/'): canonical=source[len('remote/'):]
                    elif source=='scripts/remote-host.sh': canonical='host/remote-host.sh'
                    elif source.startswith('harnesses/'): canonical=source
                    elif source in ('default-agent/package.json','default-agent/package-lock.json','default-agent/.node-version') or source.startswith('default-agent/src/'): canonical=source
                    else: raise ValueError()
                    expected_mode=0o700 if source_mode else 0o600
                    if canonical!=name or entry.get('mode')!=expected_mode or archive.getmember(name).mode&0o7777!=expected_mode: raise ValueError()
                    source_records[source]=(source_mode,content)
                digest=hashlib.sha256()
                for source,(mode,content) in sorted(source_records.items()):
                    digest.update((source+'\0false\0'+str(mode)+'\0').encode()); digest.update(hashlib.sha256(content).digest())
                if digest.hexdigest()!=expected: raise ValueError()
            except (KeyError,TypeError,ValueError,AttributeError): fail('bundle_verification_failed','The source bundle fingerprint or file integrity did not match.',78)
        target.mkdir(mode=0o700,parents=True,exist_ok=True)
        for member in sorted(members,key=lambda m:bool(m.issym() or m.islnk())):
            destination=target/member.name
            if member.issym():
                destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True); destination.symlink_to(member.linkname)
            elif member.islnk():
                destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True); os.link(target/member.linkname,destination)
            elif member.isdir(): destination.mkdir(mode=0o700,parents=True,exist_ok=True)
            else:
                destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                with destination.open('xb') as output: shutil.copyfileobj(archive.extractfile(member),output)
                destination.chmod(0o700 if member.mode&0o111 else 0o600)
        return manifest

def shell_file_state(path,ancestors=frozenset(),allow_special=False):
    try: info=path.lstat()
    except FileNotFoundError: return {'kind':'missing'}
    identity=(info.st_dev,info.st_ino)
    if identity in ancestors: return {'kind':'cycle'}
    mode=stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        target=os.readlink(path)
        referent=Path(target) if os.path.isabs(target) else path.parent/target
        return {'kind':'link','mode':mode,'target':target,'referent':shell_file_state(referent,ancestors|{identity},allow_special)}
    if stat.S_ISREG(info.st_mode): return {'kind':'file','mode':mode,'bytes':path.read_bytes()}
    if allow_special: return {'kind':'other','mode':mode,'type':stat.S_IFMT(info.st_mode)}
    fail('unsafe_shell_configuration','Shell startup paths must be regular files or symbolic links.',78)

def restore_shell_file(path,state):
    kind=state['kind']
    if kind=='cycle': return
    same_link=kind=='link' and path.is_symlink() and os.readlink(path)==state['target']
    same_file=kind=='file' and not path.is_symlink() and path.is_file()
    if not same_link and not same_file:
        if path.is_symlink() or (path.exists() and not path.is_dir()): path.unlink()
        elif path.is_dir(): shutil.rmtree(path)
    if kind=='missing': return
    path.parent.mkdir(parents=True,exist_ok=True)
    if kind=='link':
        if not same_link: path.symlink_to(state['target'])
        if hasattr(os,'lchmod'):
            with contextlib.suppress(NotImplementedError): os.lchmod(path,state['mode'])
        target=state['target']
        referent=Path(target) if os.path.isabs(target) else path.parent/target
        restore_shell_file(referent,state['referent'])
    elif kind=='file':
        if same_file: path.chmod(state['mode']|0o200)
        path.write_bytes(state['bytes']); path.chmod(state['mode'])

def snapshot_user_files():
    rc={relative:shell_file_state(HOME/relative) for relative in RC_FILES}
    def config_tree():
        # Guard settings by content and permissions. Normal harness sessions,
        # logs and SQLite journals can change while the service is installing;
        # their metadata must not turn a safe update into a false failure.
        tree={}
        def runtime_path(root,parts):
            if not parts: return False
            if root=='.codex':
                if parts[0] in ('tmp','log','logs','sessions','archived_sessions'): return True
                if len(parts)==1 and (parts[0] in ('history.jsonl','session_index.jsonl') or re.fullmatch(r'(?:state|logs)_\d+\.sqlite(?:-(?:wal|shm|journal))?',parts[0])): return True
            return root=='.grok' and parts[0] in ('logs','sessions')
        def visit(path,key,root,parts,ancestors):
            if runtime_path(root,parts): return
            try:
                info=path.lstat()
            except FileNotFoundError:
                tree[key]=None; return
            kind=stat.S_IFMT(info.st_mode); mode=stat.S_IMODE(info.st_mode)
            identity=(info.st_dev,info.st_ino)
            if identity in ancestors:
                tree[key]=[kind,mode,'cycle']; return
            following=ancestors|{identity}
            if stat.S_ISLNK(info.st_mode):
                target=os.readlink(path)
                tree[key]=[kind,mode,target]
                # Follow file and directory aliases, including a symlink at
                # .codex itself. Apply exclusions to the logical harness path,
                # so a config alias into a cache remains a protected config.
                resolved=Path(target) if os.path.isabs(target) else path.parent/target
                visit(resolved,key+'\0target',root,parts,following)
            elif stat.S_ISDIR(info.st_mode):
                tree[key]=[kind,mode]
                for child in sorted(path.iterdir()):
                    visit(child,key+'/'+child.name,root,(*parts,child.name),following)
            elif stat.S_ISREG(info.st_mode):
                tree[key]=[kind,mode,hashlib.sha256(path.read_bytes()).hexdigest()]
            else: tree[key]=[kind,mode]
        for relative in HARNESS_CONFIGS:
            visit(HOME/relative,relative,relative,(),set())
        return tree
    return rc,config_tree,config_tree()

def verify_user_files(snapshot):
    rc,config_tree,before=snapshot; changed=False
    for relative,state in rc.items():
        path=HOME/relative
        if shell_file_state(path,allow_special=True)!=state:
            changed=True
            restore_shell_file(path,state)
    if changed: fail('installer_modified_shell_config','An installer changed shell configuration; the original files were restored.',78)
    if before!=config_tree(): fail('installer_modified_harness_config','An installer changed an existing harness configuration. Installation was rejected.',78)

def atomic_link(path,target):
    if path.exists() and not path.is_symlink(): fail('unsafe_host_path','An activation path is not a managed symbolic link.',78)
    temporary=path.with_name('.'+path.name+'.'+str(os.getpid()))
    with contextlib.suppress(FileNotFoundError): temporary.unlink()
    temporary.symlink_to(str(target)); os.replace(temporary,path)

def choose_port(requested):
    for port in range(requested,min(requested+512,65536)):
        with socket.socket() as probe:
            try: probe.bind(('127.0.0.1',port)); return port
            except OSError: continue
    fail('loopback_port_unavailable','No free loopback port was found.',73)

def prepare_npm_tooling(node_root,release,environment):
    # The downloaded Node runtime is immutable and may be used by the active
    # service. Build npm and its audited vendor replacements only in the new
    # release; activation/rollback then changes npm with the existing current
    # symlink transaction, without modifying system npm or a live Node tree.
    tooling=release/'tooling'
    npm_root=tooling/'lib/node_modules/npm'
    npm_cli=npm_root/'bin/npm-cli.js'
    node=node_root/'bin/node'
    run([node,node_root/'lib/node_modules/npm/bin/npm-cli.js','install','--global','--prefix',tooling,
         '--ignore-scripts','--no-audit','--no-fund','npm@>=12.2.1'],check=True,timeout=600,env=environment)
    try:
        npm_version=json.loads((npm_root/'package.json').read_text())['version']
        parts=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)',npm_version)
        if not parts or tuple(map(int,parts.groups()))<(12,2,1): raise ValueError()
    except (OSError,ValueError,KeyError,TypeError):
        fail('npm_security_verification_failed','The private npm installer does not meet its security floor.',78)
    run([node,npm_cli,'ci','--prefix',release/'npm-runtime','--omit=dev','--ignore-scripts','--no-audit','--no-fund'],check=True,timeout=600,env=environment)
    try:
        graph=json.loads((release/'npm-runtime/package-lock.json').read_text())['packages']
        installed={'npmVersion':npm_version}
        for name in ('undici','ip-address'):
            source=release/'npm-runtime/node_modules'/name
            expected=graph['node_modules/'+name]['version']
            if source.is_symlink() or not source.is_dir() or json.loads((source/'package.json').read_text())['version']!=expected: raise ValueError()
            destination=npm_root/'node_modules'/name
            if destination.is_symlink(): destination.unlink()
            elif destination.exists(): shutil.rmtree(destination)
            shutil.copytree(source,destination)
            if json.loads((destination/'package.json').read_text())['version']!=expected: raise ValueError()
            installed[name]=expected
    except (OSError,ValueError,KeyError,TypeError):
        fail('npm_security_verification_failed','The private npm vendor packages differ from the committed security graph.',78)
    # Exercise the replaced modules under the actual pinned Node executable.
    # Keep credentials out of arguments and verification output.
    probe="import {createRequire} from 'node:module'; const require=createRequire(process.argv[1]); const undici=require('undici'); const ip=require('ip-address'); if(typeof undici.request!=='function'||typeof ip.Address6!=='function') process.exit(1)"
    checked=run([node,'--input-type=module','-e',probe,npm_cli],timeout=30,env=environment)
    if checked.returncode: fail('npm_security_verification_failed','The private npm security packages failed their runtime API check.',78)
    # SDK maintenance already prefers this bundled location over Node's stock
    # npm. The relative link remains correct when the release is activated.
    sdk_npm=release/'default-agent/lib/npm'
    sdk_npm.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    sdk_npm.symlink_to('../../tooling/lib/node_modules/npm')
    private_file(tooling/'security.json',json.dumps(installed,sort_keys=True).encode()+b'\n')
    return npm_cli

def install(workspace_id,requested_port,mode,fingerprint,updating=False):
    global TOKEN
    valid_id(workspace_id); requested_port=valid_port(requested_port); valid_mode(mode)
    if not re.fullmatch('[a-f0-9]{64}',fingerprint): fail('invalid_fingerprint','A SHA-256 deployment fingerprint is required.',64)
    if os.getuid()==0: fail('root_ssh_account_unsupported','Use a regular SSH account; agents receive root access through its existing sudo policy.',78)
    if not user_manager(): fail('systemd_user_unavailable','A usable systemd user manager is required.',78)
    if mode=='fullRoot' and not unrestricted_root(): fail('root_access_unavailable','Full root requires existing unrestricted passwordless sudo.',77)
    if not linger(): fail('host_preparation_required','Enable the user service at boot with the reviewed preparation step first.',78)
    old=record()
    if old and old['id']!=workspace_id: fail('host_workspace_conflict','A different native workspace already belongs to this host account.',73)
    if old and old['accessMode']!=mode: fail('access_mode_change_requires_reinstall','The access level is fixed for this installation. Remove its data explicitly before creating a workspace with another level.',78)
    if updating and not old: fail('workspace_not_found','Install this native workspace before updating it.',66)
    stream=os.fdopen(os.dup(3),'rb',buffering=0)
    if not TOKEN:
        credential=stream.readline(258)
        if not credential.endswith(b'\n'): fail('invalid_api_token','The streamed credential line is invalid.',64)
        TOKEN=credential.rstrip(b'\r\n').decode('ascii','strict')
    if not TOKEN and old: TOKEN=parse_env().get('WOVENMATTER_API_TOKEN','')
    if not re.fullmatch('[A-Za-z0-9+/=_-]{32,256}',TOKEN): fail('invalid_api_token','A 32-256 character generated API credential is required.',64)
    for directory in [ROOT,ROOT/'releases',ROOT/'node',ROOT/'browsers',ROOT/'workspace',ROOT/'databases',ROOT/'browser-profiles',ROOT/'run',CONFIG,UNIT.parent]: owned_directory(directory)
    port=old['port'] if old else choose_port(requested_port)
    stage=Path(tempfile.mkdtemp(prefix='.install-',dir=ROOT/'releases'))
    snapshot=snapshot_user_files(); saved_files={p:p.read_bytes() if p.exists() else None for p in [ENV_FILE,UNIT,RECORD,ROOT/'run/browser-selftest.json']}
    links=[ROOT/'current',ROOT/'node/current',ROOT/'browsers/current']
    saved_links={p:os.readlink(p) if p.is_symlink() else None for p in links}
    old_active=run(['systemctl','--user','is-active','--quiet',UNIT_NAME]).returncode==0
    old_enabled=run(['systemctl','--user','is-enabled','--quiet',UNIT_NAME]).returncode==0
    activated=False
    try:
        archive=stage/'bundle.tar.gz'
        with archive.open('wb') as output:
            total=0
            while True:
                data=stream.read(1024*1024)
                if not data: break
                total+=len(data)
                if total>512*1024**2: fail('bundle_too_large','The compressed source bundle exceeds its size limit.',78)
                output.write(data)
        progress('verifying')
        release=stage/'release'; manifest=safe_extract(archive,release,fingerprint)
        versions=json.loads((release/'host/runtime-versions.json').read_text())
        if manifest['nodeVersion']!=versions['nodeVersion'] or manifest['playwrightVersion']!=versions['playwrightVersion']:
            fail('runtime_record_mismatch','The host manifest runtime versions disagree.',78)
        locked=json.loads((release/'default-agent/package-lock.json').read_text())['packages']['node_modules/playwright-core']['version']
        if locked!=versions['playwrightVersion']: fail('runtime_record_mismatch','The Chromium tooling must match the committed lockfile.',78)
        arch={'x86_64':'x64','aarch64':'arm64','arm64':'arm64'}.get(platform.machine())
        if not arch: fail('unsupported_architecture','Native hosts support amd64 and arm64 only.',78)
        node_version=versions['nodeVersion']
        if not re.fullmatch(r'\d+\.\d+\.\d+',node_version): fail('invalid_runtime_record','Invalid pinned Node version.',78)
        node_root=ROOT/'node'/node_version
        if not (node_root/'bin/node').is_file():
            progress('node')
            node_archive=stage/'node.tar.gz'
            run(['curl','--proto','=https','--tlsv1.2','--fail','--silent','--show-error','--location',
                 'https://nodejs.org/dist/v'+node_version+'/node-v'+node_version+'-linux-'+arch+'.tar.gz','--output',node_archive],check=True,timeout=180)
            if hashlib.sha256(node_archive.read_bytes()).hexdigest()!=versions['nodeSHA256']['linux-'+arch]:
                fail('node_checksum_mismatch','The pinned Node archive failed SHA-256 verification.',78)
            node_stage=stage/'node'; safe_extract(node_archive,node_stage)
            children=list(node_stage.iterdir())
            if len(children)!=1 or not (children[0]/'bin/node').is_file(): fail('invalid_node_archive','The Node archive layout was invalid.',78)
            os.replace(children[0],node_root)
        if text(run([node_root/'bin/node','--version']))!='v'+node_version: fail('node_runtime_mismatch','The installed Node runtime differs from its pinned record.',78)
        environment={**os.environ,'PATH':str(node_root/'bin')+':'+':'.join(harness_path()),'npm_config_cache':str(ROOT/'workspace/.wovenmatter/npm-cache')}
        environment.pop('WOVENMATTER_API_TOKEN',None)
        progress('dependencies')
        npm_cli=prepare_npm_tooling(node_root,release,environment)
        environment['PATH']=str(release/'tooling/bin')+':'+environment['PATH']
        run([node_root/'bin/node',npm_cli,'ci','--prefix',release/'default-agent','--omit=dev','--ignore-scripts','--no-audit','--no-fund'],check=True,timeout=600,env=environment)
        playwright_version=versions['playwrightVersion']
        if not re.fullmatch(r'\d+\.\d+\.\d+',playwright_version): fail('invalid_runtime_record','Invalid pinned Playwright version.',78)
        browser_root=ROOT/'browsers'/('playwright-'+playwright_version)
        owned_directory(browser_root)
        progress('browser')
        environment['PLAYWRIGHT_BROWSERS_PATH']=str(browser_root)
        run([node_root/'bin/node',release/'default-agent/node_modules/playwright-core/cli.js','install','chromium'],check=True,timeout=600,env=environment)
        verify_user_files(snapshot)
        destination=ROOT/'releases'/fingerprint
        if destination.exists() or destination.is_symlink():
            # The fingerprint is an immutable source identity. Reusing a folder
            # is safe only when its actual source bytes and modes still match
            # the independently verified incoming bundle. Never run corrupt code.
            if destination.is_symlink() or not destination.is_dir(): fail('existing_release_corrupt','The existing release path is unsafe. Repair the native installation before updating.',78)
            for name,entry in manifest['files'].items():
                installed_file=destination/name
                cursor=destination
                for part in PurePosixPath(name).parts:
                    cursor=cursor/part
                    if cursor.is_symlink(): fail('existing_release_corrupt','An existing release source became a symbolic link. Repair the native installation before updating.',78)
                try:
                    info=installed_file.stat()
                    intact=stat.S_ISREG(info.st_mode) and info.st_mode&0o7777==entry['mode'] and hashlib.sha256(installed_file.read_bytes()).hexdigest()==entry['sha256']
                except OSError: intact=False
                if not intact: fail('existing_release_corrupt','The existing release source differs from its verified fingerprint. Repair the native installation before updating.',78)
            shutil.rmtree(release)
        else: os.replace(release,destination)
        settings={'WOVENMATTER_RUNTIME_KIND':'host','WOVENMATTER_ACCESS_MODE':mode,'WOVENMATTER_WORKSPACE':str(ROOT/'workspace'),
            'WOVENMATTER_DATA_DIRECTORY':str(ROOT/'databases'),'WOVENMATTER_STATE_DIRECTORY':str(ROOT/'run'),
            'WOVENMATTER_BROWSER_PROFILES':str(ROOT/'browser-profiles'),'PLAYWRIGHT_BROWSERS_PATH':str(ROOT/'browsers/current'),
            'WOVENMATTER_LISTEN_HOST':'127.0.0.1','WOVENMATTER_LISTEN_PORT':str(port),'WOVENMATTER_API_TOKEN':TOKEN,
            'WOVENMATTER_SERVICE_FINGERPRINT':fingerprint,'WOVENMATTER_HARNESS_PATH':':'.join([str(ROOT/'current/tooling/bin'),str(ROOT/'node/current/bin'),*harness_path()]),
            'WOVEN_DEFAULT_AGENT_DIRECTORY':str(ROOT/'workspace/.wovenmatter/default-agent'),
            'PATH':':'.join([str(HOME/'.local/bin'),str(HOME/'.npm-global/bin'),str(ROOT/'current/tooling/bin'),str(ROOT/'node/current/bin'),*harness_path()])}
        if any(any(c in value for c in ('\0','\n','\r')) for value in settings.values()): fail('unsupported_home_path','Host configuration contains an unsupported path.',78)
        unit='[Unit]\nDescription=Woven Matter native workspace\nAfter=network-online.target\n\n[Service]\nEnvironmentFile=%h/.config/wovenmatter/service.env\nWorkingDirectory=%h/.local/share/wovenmatter/workspace\nExecStart=%h/.local/share/wovenmatter/node/current/bin/node %h/.local/share/wovenmatter/current/src/server.mjs\nRestart=always\nRestartSec=3\nUMask=0077\nNoNewPrivileges='+('no' if mode=='fullRoot' else 'yes')+'\nLimitCORE=0\n\n[Install]\nWantedBy=default.target\n'
        progress('activating')
        run(['systemctl','--user','stop',UNIT_NAME])
        activated=True
        atomic_link(ROOT/'current',destination)
        atomic_link(ROOT/'node/current',node_root)
        atomic_link(ROOT/'browsers/current',browser_root)
        private_file(ENV_FILE,(''.join(key+'='+json.dumps(value,ensure_ascii=False)+'\n' for key,value in settings.items())).encode())
        private_file(UNIT,unit.encode())
        run(['systemctl','--user','daemon-reload'],check=True)
        run(['systemctl','--user','enable','--now',UNIT_NAME],check=True)
        deadline=time.monotonic()+45
        while time.monotonic()<deadline:
            response=health(port,TOKEN)
            if response and response.get('serviceFingerprint')==fingerprint and response.get('runtimeKind')=='host': break
            time.sleep(.3)
        else: fail('host_health_failed','The new native service did not become healthy; the previous version was restored.',70)
        progress('selftest')
        environment.update(settings)
        checked=run([node_root/'bin/node',destination/'src/browser-selftest.mjs','--json'],timeout=90,env=environment)
        try: browser=json.loads(text(checked))
        except ValueError: browser={'ok':False,'reason':'sandbox_blocked','missingLibraries':[],'hint':'The browser sandbox could not be verified.'}
        private_file(ROOT/'run/browser-selftest.json',json.dumps(browser).encode()+b'\n')
        if checked.returncode or browser.get('ok') is not True:
            reason=browser.get('reason','sandbox_blocked')
            fail('browser_selftest_failed',str(reason)+': '+str(browser.get('hint','The sandbox could not be verified.')),70)
        installed={'id':workspace_id,'port':port,'accessMode':mode,'fingerprint':fingerprint,'nodeVersion':node_version,'playwrightVersion':playwright_version}
        private_file(RECORD,json.dumps(installed,sort_keys=True).encode()+b'\n')
        verify_user_files(snapshot)
        progress('ready')
        return status(workspace_id)
    except BaseException:
        if activated:
            run(['systemctl','--user','stop',UNIT_NAME])
            for path,target in saved_links.items():
                if target is not None: atomic_link(path,target)
                elif path.is_symlink(): path.unlink()
            for path,value in saved_files.items():
                if value is not None: private_file(path,value)
                else:
                    with contextlib.suppress(FileNotFoundError): path.unlink()
            run(['systemctl','--user','daemon-reload'])
            if old_enabled: run(['systemctl','--user','enable',UNIT_NAME])
            else: run(['systemctl','--user','disable',UNIT_NAME])
            if old_active: run(['systemctl','--user','start',UNIT_NAME])
        verify_user_files(snapshot)
        raise
    finally:
        stream.close(); shutil.rmtree(stage,ignore_errors=True)

def expose(workspace_id,port,https_port='8443'):
    installed=require_owner(workspace_id); port=valid_port(port); https_port=valid_port(https_port)
    if installed['port']!=port: fail('workspace_binding_changed','The native service port differs from the requested loopback target.',78)
    settings=parse_env()
    if settings.get('WOVENMATTER_LISTEN_HOST')!='127.0.0.1' or not health(port,settings.get('WOVENMATTER_API_TOKEN','')):
        fail('workspace_binding_changed','The native service must be healthy on its expected loopback address.',78)
    if tailscale_operator_ready() is False:
        fail('tailscale_operator_required','Review and run host preparation to let this SSH account manage private Tailscale Serve.',77)
    state=run(['tailscale','status','--json'],check=True)
    try:
        state=json.loads(state.stdout); dns=state['Self']['DNSName'].rstrip('.').lower()
        if state.get('BackendState')!='Running' or not re.fullmatch(r'[a-z0-9.-]+\.ts\.net',dns): raise ValueError()
    except (ValueError,KeyError): fail('tailscale_disconnected','Connect Tailscale with a private HTTPS name first.',69)
    route='/wovenmatter-execution/'+workspace_id; target='http://127.0.0.1:'+str(port); endpoint=dns+':'+str(https_port)
    def verified_configuration():
        try: config=json.loads(run(['tailscale','serve','status','--json'],check=True).stdout)
        except ValueError: fail('tailscale_serve_unavailable','Private Tailscale Serve status is unavailable.',69)
        if config.get('AllowFunnel',{}).get(endpoint): fail('tailscale_route_conflict','Public Funnel owns this port. Existing routes were preserved.',78)
        tcp=config.get('TCP',{}).get(str(https_port),{})
        if tcp and tcp.get('HTTPS') is not True: fail('tailscale_route_conflict','Another TCP route owns this port.',78)
        handlers=config.get('Web',{}).get(endpoint,{}).get('Handlers',{})
        for path,handler in handlers.items():
            if path.rstrip('/')==route:
                if handler.get('Proxy')!=target: fail('tailscale_route_conflict','Another service owns this route. Existing routes were preserved.',78)
                return True
        return False
    if not verified_configuration(): run(['tailscale','serve','--bg','--https='+str(https_port),'--set-path='+route,target],check=True)
    if not verified_configuration(): fail('tailscale_serve_unverified','Private sharing could not be verified.',69)
    return {'endpoint':'https://'+endpoint+route}

def cleanup_private_routes(workspace_id,port):
    route='/wovenmatter-execution/'+workspace_id
    target='http://127.0.0.1:'+str(port)
    def configuration():
        response=run(['tailscale','serve','status','--json'])
        if response.returncode:
            fail('tailscale_cleanup_unavailable','Private Tailscale routes could not be checked. Restore Tailscale access and retry uninstall; the workspace was preserved.',69)
        try:
            value=json.loads(response.stdout)
            if not isinstance(value,dict): raise ValueError()
            return value
        except ValueError: fail('tailscale_cleanup_unavailable','Private Tailscale routes returned invalid status. The workspace was preserved.',69)
    def owned(config):
        result=[]
        for endpoint,web in config.get('Web',{}).items():
            name,separator,https_port=endpoint.rpartition(':')
            if not separator or not https_port.isdigit() or config.get('TCP',{}).get(https_port,{}).get('HTTPS') is not True: continue
            for path,handler in web.get('Handlers',{}).items():
                if path.rstrip('/')==route and handler.get('Proxy')==target:
                    result.append((endpoint,path,https_port))
        return result
    before=configuration(); routes=owned(before)
    if not routes: return 0
    # An endpoint changed to Funnel is no longer our private sharing setup.
    # Preserve that configuration and require an explicit repair, not a reset.
    if any(before.get('AllowFunnel',{}).get(endpoint) for endpoint,_,_ in routes):
        fail('tailscale_cleanup_conflict','A matching workspace route now belongs to a Funnel endpoint. Remove that route explicitly before uninstall; other sharing was preserved.',78)
    response=run(['tailscale','status','--json'])
    try:
        status=json.loads(response.stdout); dns=status['Self']['DNSName'].rstrip('.').lower()
        if response.returncode or status.get('BackendState')!='Running' or not re.fullmatch(r'[a-z0-9.-]+\.ts\.net',dns): raise ValueError()
    except (ValueError,KeyError): fail('tailscale_cleanup_unavailable','The current private Tailscale name could not be verified. The workspace was preserved.',69)
    if any(endpoint.rpartition(':')[0].lower()!=dns for endpoint,_,_ in routes):
        fail('tailscale_cleanup_conflict','A matching workspace route uses a former Tailscale name. Remove that exact route explicitly before uninstall; other sharing was preserved.',78)
    identities={(endpoint,path) for endpoint,path,_ in routes}
    protected_handlers={(endpoint,path):handler for endpoint,web in before.get('Web',{}).items() for path,handler in web.get('Handlers',{}).items() if (endpoint,path) not in identities}
    removable_ports={https_port for endpoint,_,https_port in routes if not any(other.rpartition(':')[2]==https_port for other,_ in protected_handlers)}
    protected_tcp={key:value for key,value in before.get('TCP',{}).items() if key not in removable_ports}
    owned_endpoints={endpoint for endpoint,_,_ in routes}
    protected_funnel={key:value for key,value in before.get('AllowFunnel',{}).items() if key not in owned_endpoints}
    other_configuration={key:value for key,value in before.items() if key not in ('Web','TCP','AllowFunnel')}
    removed=0
    for endpoint,path,https_port in routes:
        current=configuration()
        handler=current.get('Web',{}).get(endpoint,{}).get('Handlers',{}).get(path)
        if handler is None: continue
        if handler.get('Proxy')!=target or current.get('TCP',{}).get(https_port,{}).get('HTTPS') is not True or current.get('AllowFunnel',{}).get(endpoint):
            fail('tailscale_cleanup_conflict','Private sharing changed during uninstall. The workspace was preserved; retry after checking that route.',78)
        result=run(['tailscale','serve','--https='+https_port,'--set-path='+path,'off'])
        if result.returncode:
            fail('tailscale_route_cleanup_failed','The workspace private route could not be removed. Restore this account’s Tailscale operator access and retry uninstall; the workspace was preserved.',69)
        removed+=1
    after=configuration()
    if owned(after): fail('tailscale_route_cleanup_failed','Tailscale still reports a matching workspace route. The workspace was preserved.',69)
    if any(after.get('Web',{}).get(endpoint,{}).get('Handlers',{}).get(path)!=handler for (endpoint,path),handler in protected_handlers.items()) or any(after.get('TCP',{}).get(key)!=value for key,value in protected_tcp.items()) or any(after.get('AllowFunnel',{}).get(key)!=value for key,value in protected_funnel.items()) or {key:value for key,value in after.items() if key not in ('Web','TCP','AllowFunnel')}!=other_configuration:
        fail('tailscale_cleanup_unverified','Unrelated Tailscale sharing could not be verified after route removal. The workspace was preserved.',78)
    return removed

def uninstall(workspace_id,remove_data=False):
    installed=require_owner(workspace_id)
    removed_routes=cleanup_private_routes(workspace_id,installed['port'])
    run(['systemctl','--user','disable','--now',UNIT_NAME],check=True)
    with contextlib.suppress(FileNotFoundError): UNIT.unlink()
    with contextlib.suppress(FileNotFoundError): ENV_FILE.unlink()
    run(['systemctl','--user','daemon-reload'],check=True)
    if (ROOT/'current').is_symlink(): (ROOT/'current').unlink()
    shutil.rmtree(ROOT/'releases')
    # Keep the identity/port record with retained data: reconnecting cannot adopt
    # another workspace's persisted execution history by accident.
    if remove_data:
        if ROOT.is_symlink() or ROOT.stat().st_uid!=os.getuid(): fail('unsafe_host_path','The data root is unsafe; no data was removed.',78)
        shutil.rmtree(ROOT)
    return {'deleted':True,'id':workspace_id,'containerExisted':False,'persistentDataRemoved':remove_data,'kind':'host','privateRoutesRemoved':removed_routes,'privateRoutesCleanupVerified':True}

def main(args):
    if not args: fail('invalid_command','A host lifecycle command is required.',64)
    action,*args=args
    if action=='inspect' and len(args)<=1: return inspect(*args)
    if action=='prepare' and 1<=len(args)<=2:
        with lifecycle_lock(): return prepare(*args)
    if action in ('install','update') and len(args)==4:
        with lifecycle_lock(): return install(*args,updating=action=='update')
    if action=='status' and len(args)==1: return status(args[0])
    if action in ('start','stop','restart') and len(args)==1:
        with lifecycle_lock():
            require_owner(args[0]); run(['systemctl','--user',action,UNIT_NAME],check=True)
            return status(args[0])
    if action=='logs' and 1<=len(args)<=2:
        require_owner(args[0]); count=args[1] if len(args)>1 else '100'
        if not count.isdigit() or not 1<=int(count)<=1000: fail('invalid_log_count','Choose between 1 and 1000 log lines.',64)
        output=text(run(['journalctl','--user','-u',UNIT_NAME,'--no-pager','-n',count],check=True))
        secret=parse_env().get('WOVENMATTER_API_TOKEN','')
        if secret: output=output.replace(secret,'[redacted]')
        return {'logs':output,'kind':'host'}
    if action in ('uninstall','delete') and 1<=len(args)<=2:
        if len(args)>1 and args[1]!='--data': fail('invalid_command','Use --data to remove persistent workspace data.',64)
        with lifecycle_lock(): return uninstall(args[0],len(args)>1)
    if action=='expose' and 2<=len(args)<=3:
        with lifecycle_lock(): return expose(*args)
    fail('invalid_command','Invalid host lifecycle command or arguments.',64)

if __name__=='__main__':
    try: emit(main(sys.argv[1:]))
    except Failure as error:
        print(json.dumps({'error':error.code,'detail':error.detail}),file=sys.stderr)
        raise SystemExit(error.status)
    except (OSError,ValueError,KeyError,UnicodeError):
        print(json.dumps({'error':'host_operation_failed','detail':'The native host operation failed. Existing durable data was preserved.'}),file=sys.stderr)
        raise SystemExit(70)
PY
