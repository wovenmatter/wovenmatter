#!/usr/bin/env python3
"""Host bundle provenance and the literal wm-exec protocol, without providers."""
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
INPUTS=['remote/package.json','remote/src','remote/host','remote/npm-runtime/package.json','remote/npm-runtime/package-lock.json','harnesses','default-agent/package.json',
        'default-agent/package-lock.json','default-agent/src','default-agent/.node-version','scripts/remote-host.sh',
        'bots/package.json','bots/package-lock.json','bots/src','bots/helper','bots/image']

def fingerprint(root):
    files=[]
    for name in INPUTS:
        path=root/name
        files.extend(p for p in (path.rglob('*') if path.is_dir() else [path]) if p.is_file() and p.name!='.DS_Store')
    digest=hashlib.sha256()
    for path in sorted(files,key=lambda p:p.relative_to(root).as_posix()):
        digest.update((path.relative_to(root).as_posix()+'\0false\0'+str(path.stat().st_mode&0o111)+'\0').encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()

class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        for target in ('remote/src','remote/npm-runtime','remote/host/bin','harnesses/mcp','default-agent/src','scripts'):
            (self.root/target).mkdir(parents=True,exist_ok=True)
        for path in ('remote/host/build-bundle.sh','remote/host/bin/wm-exec','remote/host/runtime-versions.json','scripts/remote-host.sh','remote/npm-runtime/package.json','remote/npm-runtime/package-lock.json'):
            shutil.copy2(ROOT/path,self.root/path)
        (self.root/'remote/package.json').write_text('{}\n')
        (self.root/'remote/src/server.mjs').write_text('export const fixture=true\n')
        (self.root/'harnesses/catalog.json').write_text('{"schemaVersion":4}\n')
        (self.root/'harnesses/mcp/adapter.mjs').write_text('export const fixture=true\n')
        (self.root/'default-agent/src/main.mjs').write_text('export const fixture=true\n')
        (self.root/'default-agent/package.json').write_text('{}\n')
        versions=json.loads((ROOT/'remote/host/runtime-versions.json').read_text())
        (self.root/'default-agent/.node-version').write_text(versions['nodeVersion']+'\n')
        (self.root/'default-agent/package-lock.json').write_text(json.dumps({'packages':{'node_modules/playwright-core':{'version':versions['playwrightVersion']}}}))
    def tearDown(self): self.temp.cleanup()
    def build(self,fp=None):
        return subprocess.run(['bash',str(self.root/'remote/host/build-bundle.sh'),fp or fingerprint(self.root)],capture_output=True)
    def test_deterministic_manifest_and_mcp_resources(self):
        first=self.build(); second=self.build()
        self.assertEqual(first.returncode,0,first.stderr.decode()); self.assertEqual(first.stdout,second.stdout)
        with tarfile.open(fileobj=io.BytesIO(first.stdout),mode='r:gz') as archive:
            manifest=json.load(archive.extractfile('manifest.json'))
            self.assertEqual(manifest['fingerprint'],fingerprint(self.root))
            self.assertEqual(manifest['dependencyInstallation'],'target-npm-ci')
            self.assertIn('npm-runtime/package-lock.json',manifest['files']); self.assertIn('npm-runtime/package.json',manifest['files'])
            self.assertIn('bin/wm-exec',manifest['files']); self.assertIn('harnesses/mcp/adapter.mjs',manifest['files'])
            self.assertIn('default-agent/.node-version',manifest['files']); self.assertIn('host/remote-host.sh',manifest['files'])
            self.assertFalse(any('node_modules/' in name for name in archive.getnames()))
            for name,entry in manifest['files'].items():
                self.assertEqual(hashlib.sha256(archive.extractfile(name).read()).hexdigest(),entry['sha256'])
    def test_bots_runtime_ships_when_present_without_its_dependencies_or_tests(self):
        (self.root/'bots/src').mkdir(parents=True); (self.root/'bots/helper').mkdir(); (self.root/'bots/image').mkdir(); (self.root/'bots/test').mkdir(); (self.root/'bots/node_modules/x').mkdir(parents=True)
        for name in ('bots/package.json','bots/package-lock.json','bots/src/cli.ts','bots/helper/agent.mjs','bots/image/Dockerfile','bots/test/fixture.test.ts','bots/node_modules/x/index.js'):
            (self.root/name).write_text('fixture\n')
        result=self.build(); self.assertEqual(result.returncode,0,result.stderr.decode())
        with tarfile.open(fileobj=io.BytesIO(result.stdout),mode='r:gz') as archive:
            names=set(json.load(archive.extractfile('manifest.json'))['files'])
        self.assertTrue({'bots/package.json','bots/package-lock.json','bots/src/cli.ts','bots/helper/agent.mjs','bots/image/Dockerfile'}<=names)
        self.assertFalse(any('node_modules' in name or name.startswith('bots/test') for name in names))
    def test_stale_fingerprint_and_symlink_sources_are_rejected(self):
        fp=fingerprint(self.root); (self.root/'remote/src/server.mjs').write_text('changed')
        self.assertNotEqual(self.build(fp).returncode,0)
        (self.root/'remote/src/link').symlink_to('server.mjs')
        self.assertNotEqual(self.build().returncode,0)
    def test_runtime_records_match_committed_graph_and_official_checksums(self):
        versions=json.loads((ROOT/'remote/host/runtime-versions.json').read_text())
        self.assertEqual(versions['nodeVersion'],(ROOT/'default-agent/.node-version').read_text().strip())
        lock=json.loads((ROOT/'default-agent/package-lock.json').read_text())
        self.assertEqual(versions['playwrightVersion'],lock['packages']['node_modules/playwright-core']['version'])
        self.assertIn('FROM node:'+versions['nodeVersion'].split('.')[0]+'-',(ROOT/'remote/Executor.Dockerfile').read_text())
        self.assertEqual(set(versions['nodeSHA256']),{'linux-x64','linux-arm64'})
        for value in versions['nodeSHA256'].values(): self.assertRegex(value,r'^[a-f0-9]{64}$')
        self.assertRegex(versions['dockerVersion'],r'^\d+\.\d+\.\d+$')
        self.assertEqual(set(versions['dockerSHA256']),{'linux-x64','linux-arm64'})
        for value in versions['dockerSHA256'].values(): self.assertRegex(value,r'^[a-f0-9]{64}$')
        (self.root/'default-agent/.node-version').write_text('0.0.0')
        self.assertNotEqual(self.build().returncode,0)

class ExecTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.home=Path(self.temp.name).resolve(); self.root=self.home/'.local/share/wovenmatter'
        self.environment=self.home/'.config/wovenmatter/service.env'
        self.environment.parent.mkdir(parents=True); (self.root/'run').mkdir(parents=True)
        self.settings={'WOVENMATTER_API_TOKEN':'fixture-'+'x'*48,'WOVENMATTER_LISTEN_PORT':'7337',
            'WOVENMATTER_WORKSPACE':str(self.root/'workspace'),'WOVENMATTER_DATA_DIRECTORY':str(self.root/'databases'),
            'WOVENMATTER_STATE_DIRECTORY':str(self.root/'run'),'WOVENMATTER_HARNESS_PATH':'/fixture path/#literal:$HOME',
            'PLAYWRIGHT_BROWSERS_PATH':str(self.root/'browsers/current'),
            'WOVENMATTER_ACCESS_MODE':'fullRoot','UNTRUSTED_SETTING':'must-not-export'}
        (self.root/'workspace').mkdir(); self.write_environment()
        self.env={**os.environ,'HOME':str(self.home),'WOVENMATTER_UNEXPECTED':'must-not-export'}
    def tearDown(self): self.temp.cleanup()
    def write_environment(self):
        self.environment.write_text(''.join(k+'='+json.dumps(v)+'\n' for k,v in self.settings.items())); self.environment.chmod(0o600)
    def execute(self,*args,input=None):
        return subprocess.run(['bash',str(ROOT/'remote/host/bin/wm-exec'),*args],env=self.env,capture_output=True,input=input)
    def test_environment_allowlist_stdin_and_token_absent_from_arguments(self):
        code='import os,sys,json; print(json.dumps({"env":{k:v for k,v in os.environ.items() if k.startswith("WOVEN") or k=="UNTRUSTED_SETTING"},"argv":sys.argv,"cwd":os.getcwd(),"input":sys.stdin.read()}))'
        result=self.execute('exec',sys.executable,'-c',code,input=b'protocol\n')
        self.assertEqual(result.returncode,0,result.stderr.decode()); value=json.loads(result.stdout)
        self.assertEqual(value['env']['WOVENMATTER_API_TOKEN'],self.settings['WOVENMATTER_API_TOKEN'])
        self.assertNotIn('UNTRUSTED_SETTING',value['env']); self.assertNotIn('WOVENMATTER_UNEXPECTED',value['env'])
        self.assertNotIn(self.settings['WOVENMATTER_API_TOKEN'],' '.join(value['argv']))
        self.assertEqual(value['input'],'protocol\n'); self.assertEqual(value['cwd'],str(self.root/'workspace'))
        self.assertEqual(value['env']['WOVEN_DEFAULT_AGENT_DIRECTORY'],str(self.root/'workspace/.wovenmatter/default-agent'))
    def test_sessions_get_noninteractive_credential_prompts(self):
        code='import os,json; print(json.dumps({k:os.environ.get(k) for k in ("PATH","GIT_TERMINAL_PROMPT","SSH_ASKPASS","SSH_ASKPASS_REQUIRE","SUDO_ASKPASS")}))'
        result=self.execute('exec',sys.executable,'-c',code)
        self.assertEqual(result.returncode,0,result.stderr.decode()); value=json.loads(result.stdout)
        tools=str(self.root/'current/host/session-tools')
        self.assertEqual(value['PATH'].split(':')[0],tools)
        self.assertEqual(value['GIT_TERMINAL_PROMPT'],'0'); self.assertEqual(value['SSH_ASKPASS_REQUIRE'],'force')
        self.assertEqual(value['SSH_ASKPASS'],tools+'/askpass'); self.assertEqual(value['SUDO_ASKPASS'],tools+'/askpass')
    def test_literal_environment_and_no_shell_rc_execution(self):
        marker=self.home/'rc-was-executed'; (self.home/'.bashrc').write_text('touch '+str(marker)+'\n')
        literal='$(touch '+str(marker)+') # value with spaces'
        result=self.execute('--env','WOVENMATTER_ADDITIONAL_INSTRUCTIONS='+literal,'exec',sys.executable,'-c','import os; print(os.environ["WOVENMATTER_ADDITIONAL_INSTRUCTIONS"])')
        self.assertEqual(result.returncode,0,result.stderr.decode()); self.assertEqual(result.stdout.decode().strip(),literal)
        self.assertFalse(marker.exists())
        result=self.execute('--env','LD_PRELOAD=/bad','exec',sys.executable,'-c','pass')
        self.assertNotEqual(result.returncode,0)
    def test_runtime_lock_blocks_launch_with_existing_message(self):
        with (self.root/'run/runtime-operation.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            result=self.execute('exec',sys.executable,'-c','pass')
            self.assertEqual(result.returncode,75)
            self.assertIn('Runtime maintenance is in progress.',result.stderr.decode())
    def test_agent_launch_subcommands_are_gone(self):
        # Agents run in the host's server; the wrapper launches none of them.
        for command in ('harness','default-agent','durable-acp'):
            result=self.execute(command,'--control')
            self.assertEqual(result.returncode,64)
            self.assertIn('Unsupported host execution subcommand.',result.stderr.decode())
        self.assertEqual(self.execute('--env','WOVEN_DURABLE_REMOTE_ACP=1','exec','true').returncode,64)
    def test_child_created_directories_are_private(self):
        created=self.root/'workspace/private-child'
        result=self.execute('exec',sys.executable,'-c','from pathlib import Path; Path("private-child").mkdir()')
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertEqual(created.stat().st_mode&0o777,0o700)
    def test_unsafe_environment_permissions_and_symlink_rejected(self):
        self.environment.chmod(0o644)
        self.assertEqual(self.execute('exec','true').returncode,78)
        target=self.environment.with_name('target'); self.environment.rename(target); self.environment.symlink_to(target)
        self.assertEqual(self.execute('exec','true').returncode,78)

if __name__=='__main__': unittest.main()
