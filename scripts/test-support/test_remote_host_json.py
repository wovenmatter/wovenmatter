#!/usr/bin/env python3
"""Provider-free lifecycle fixtures, archive attacks and rollback verification."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'scripts/remote-host.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY\n',1)[0]
TOKEN='fixture-'+'x'*48

class HostFixtures(unittest.TestCase):
    def setUp(self):
        self.actual_uid=os.getuid()
        self.temp=tempfile.TemporaryDirectory()
        self.home=Path(self.temp.name)
        self.module=types.ModuleType('remote_host_fixture')
        with mock.patch.dict(os.environ,{'HOME':str(self.home)}):
            exec(compile(SOURCE,'remote-host.sh','exec'),self.module.__dict__)
        self.m=self.module
        self.m.HOME=self.home; self.m.ROOT=self.home/'.local/share/wovenmatter'
        self.m.CONFIG=self.home/'.config/wovenmatter'; self.m.ENV_FILE=self.m.CONFIG/'service.env'
        self.m.UNIT=self.home/'.config/systemd/user/wovenmatter.service'; self.m.RECORD=self.m.ROOT/'installation.json'
        self.calls=[]; self.active=True; self.enabled=True; self.fail_selftest=False; self.bad_npm_vendor=False; self.npm_version='12.2.2'; self.tail_operator=self.m.pwd.getpwuid(self.actual_uid).pw_name
        self.patchers=[mock.patch.object(self.m,'run',side_effect=self.command),
            mock.patch.object(self.m.platform,'system',return_value='Linux'),mock.patch.object(self.m.platform,'machine',return_value='x86_64'),
            mock.patch.object(self.m.os,'getuid',return_value=self.actual_uid),mock.patch.object(self.m,'inventory',return_value=[])]
        for patcher in self.patchers: patcher.start()
        self.m.owned_directory=lambda p: Path(p).mkdir(mode=0o700,parents=True,exist_ok=True)
        # Never read a real engine on the machine running these tests.
        self.m.BOTS_ETC=self.home/'etc/wovenmatter-bots'; self.m.BOTS_VAR=self.home/'var/lib/wovenmatter-bots'
        self.m.BOTS_HELPER=self.home/'usr/local/lib/wovenmatter-bots/bots-engine'
        self.engine_calls=[]; self.fail_migration=False; self.migrations=[]
    def tearDown(self):
        for patcher in reversed(self.patchers): patcher.stop()
        self.temp.cleanup()
    def command(self,args,**kwargs):
        args=[str(a) for a in args]; self.calls.append(args); output=b''; code=0
        if args[0]=='sudo' and len(args)>5 and args[3]=='-I':
            # The root engine helper: record it and act as its installed state.
            self.engine_calls.append(args[4:])
            command=args[7]
            if command=='install':
                self.m.BOTS_ETC.mkdir(parents=True,exist_ok=True)
                self.m.BOTS_ETC.joinpath('instance.json').write_text(json.dumps({'user':self.m.pwd.getpwuid(self.actual_uid).pw_name,'socket':str(self.home/'missing.sock'),
                    'poolBytes':int(args[args.index('--pool')+1]),'diskBytes':int(args[args.index('--disk')+1])}))
            elif command=='uninstall': self.m.BOTS_ETC.joinpath('instance.json').unlink()
            output=b'{"ok":true}\n'
        elif args[0]=='curl':
            Path(args[args.index('--output')+1]).write_bytes(b'docker-fixture')
        elif args[0]=='sudo':
            if args[2:4]==['tailscale','set']:
                self.tail_operator=args[4].removeprefix('--operator=')
            else: output=b'0\n'
        elif args[0]=='loginctl': output=b'yes\n'
        elif args[0]=='dpkg-query': output=b'installed'
        elif args[0]=='systemctl' and args[1]!='--user':
            # System units belong to the bot engine fixture.
            output=b'active\n' if args[1]=='is-active' else b''
        elif args[0]=='systemctl':
            action=args[2]
            if action=='is-active': output=b'active\n' if self.active else b'inactive\n'; code=0 if self.active else 3
            elif action=='is-enabled': code=0 if self.enabled else 1
            elif action=='stop': self.active=False
            elif action in ('start','restart'): self.active=True
            elif action=='enable': self.enabled=True; self.active=self.active or '--now' in args
            elif action=='disable': self.enabled=False; self.active=False if '--now' in args else self.active
        elif args[0]=='tailscale':
            if args[1]=='status': output=json.dumps({'BackendState':'Running','Self':{'DNSName':'fixture.test.ts.net.'}}).encode()
            elif args[1:3]==['serve','status']: output=b'{}'
            elif args[1:3]==['debug','prefs']: output=json.dumps({'OperatorUser':self.tail_operator}).encode()
        elif args[0]=='journalctl': output=('one '+TOKEN+' line').encode()
        elif 'install' in args and '--global' in args and 'npm@>=12.2.2' in args:
            prefix=Path(args[args.index('--prefix')+1]); npm=prefix/'lib/node_modules/npm'
            (npm/'bin').mkdir(parents=True); (npm/'node_modules/undici').mkdir(parents=True)
            (npm/'package.json').write_text(json.dumps({'version':self.npm_version})); (npm/'bin/npm-cli.js').write_text('fixture')
            (npm/'node_modules/undici/package.json').write_text(json.dumps({'version':'6.29.0'}))
        elif 'ci' in args and '--prefix' in args and args[args.index('--prefix')+1].endswith('/npm-runtime'):
            prefix=Path(args[args.index('--prefix')+1]); graph=json.loads((prefix/'package-lock.json').read_text())['packages']
            for key in graph:
                if not key.startswith('node_modules/') or '/node_modules/' in key[13:]: continue
                name=key[13:]
                target=prefix/'node_modules'/name; target.mkdir(parents=True)
                (target/'package.json').write_text(json.dumps({'version':'0.0.0' if self.bad_npm_vendor else graph['node_modules/'+name]['version']}))
        elif '--migrate-only' in args:
            self.migrations.append(args)
            database=Path(args[args.index('--data-root')+1])/'library/workspace.sqlite'; database.parent.mkdir(parents=True,exist_ok=True)
            database.write_bytes(b'migrated-but-failed' if self.fail_migration else b'migrated')
            output,code=(b'',1) if self.fail_migration else (b'{"event":"migrated"}\n',0)
        elif args[-1]=='--version': output=b'v26.12.1\n'
        elif args[-1]=='--json': output=json.dumps({'ok':not self.fail_selftest,'reason':'sandbox_blocked' if self.fail_selftest else None,'missingLibraries':[],'hint':'Fixture sandbox blocked.' if self.fail_selftest else ''}).encode(); code=int(self.fail_selftest)
        return subprocess.CompletedProcess(args,code,output,b'')
    def save_install(self,identity='fixture',fingerprint='a'*64):
        self.m.ROOT.mkdir(parents=True,exist_ok=True); self.m.CONFIG.mkdir(parents=True,exist_ok=True)
        self.m.RECORD.write_text(json.dumps({'id':identity,'port':7337,'accessMode':'fullRoot','fingerprint':fingerprint}))
        settings={'WOVENMATTER_API_TOKEN':TOKEN,'WOVENMATTER_LISTEN_HOST':'127.0.0.1','WOVENMATTER_LISTEN_PORT':'7337'}
        self.m.ENV_FILE.write_text(''.join(k+'='+json.dumps(v)+'\n' for k,v in settings.items())); self.m.ENV_FILE.chmod(0o600)
    def test_inspect_contract(self):
        self.m.os_release=lambda:{'ID':'debian','VERSION_ID':'13'}
        result=self.m.main(['inspect','fullRoot'])
        self.assertEqual(result['kind'],'host'); self.assertEqual(result['runtime'],'host')
        self.assertEqual(result['architecture'],'amd64'); self.assertIn('requiredPrivilegedActions',result)
        self.assertIn('dataRoot',result); self.assertIn('harnesses',result)
        self.assertNotIn(TOKEN,json.dumps(result))
    def test_all_lifecycle_json_shapes(self):
        self.save_install()
        self.m.health=lambda *a:{'status':'ok'}
        for action in ('status','start','stop','restart'):
            result=self.m.main([action,'fixture']); json.dumps(result)
            self.assertEqual(result['kind'],'host'); self.assertEqual(result['id'],'fixture')
            if result['running']: self.assertEqual(result['state'],'running')
        self.assertNotIn(TOKEN,json.dumps(self.m.main(['logs','fixture','10'])))
        self.m.privileged_actions=lambda d,roles=None:[]; self.m.os_release=lambda:{'ID':'debian','VERSION_ID':'13'}
        # inspect() checks binary discovery after prepare. The fixture's fake
        # command runner does not imply these programs exist on the test host.
        required={'tailscale','script','setpriv','curl'}
        with mock.patch.object(self.m.shutil,'which',side_effect=lambda binary: '/fixture/bin/'+binary if binary in required else None):
            prepared=self.m.main(['prepare','AUTHORIZED','user'])
        self.assertEqual(prepared['blockingIssues'],[])
        self.assertTrue(prepared['prepared'])
        self.assertRaises(self.m.Failure,self.m.main,['prepare','NO'])
        self.assertRaises(self.m.Failure,self.m.main,['logs','fixture','1001'])
    def test_unsupported_command_and_identity_are_rejected(self):
        for args in ([],['unknown'],['install','bad/id','7337','user','a'*64],['inspect','sudo']):
            with self.assertRaises(self.m.Failure): self.m.main(args)
        self.save_install()
        with self.assertRaises(self.m.Failure) as error: self.m.main(['status','different'])
        self.assertEqual(error.exception.code,'host_workspace_conflict')
    def test_environment_is_literal_private_data(self):
        self.save_install(); literal='a # dollar$ backslash\\ quote" value'
        self.m.ENV_FILE.write_text('WOVENMATTER_HARNESS_PATH='+json.dumps(literal)+'\n')
        self.assertEqual(self.m.parse_env()['WOVENMATTER_HARNESS_PATH'],literal)
        self.m.ENV_FILE.chmod(0o644)
        with self.assertRaises(self.m.Failure): self.m.parse_env()
    def archive(self,entries):
        path=self.home/'bundle.tar'
        with tarfile.open(path,'w') as archive:
            for name,data,kind,link in entries:
                entry=tarfile.TarInfo(name); entry.type=kind; entry.linkname=link
                entry.mode=0o600; entry.size=len(data); archive.addfile(entry,io.BytesIO(data))
        return path
    def test_tar_rejects_traversal_duplicates_links_and_devices_before_extract(self):
        cases=[('../escape',b'a',tarfile.REGTYPE,''),('/absolute',b'a',tarfile.REGTYPE,''),
            ('dir/./file',b'a',tarfile.REGTYPE,''),('link',b'',tarfile.SYMTYPE,'../escape'),
            ('fifo',b'',tarfile.FIFOTYPE,'')]
        for entry in cases:
            path=self.archive([entry]); target=self.home/'extract'
            with self.assertRaises(self.m.Failure): self.m.safe_extract(path,target,'a'*64)
            self.assertFalse(target.exists())
        path=self.archive([('file',b'a',tarfile.REGTYPE,''),('file',b'b',tarfile.REGTYPE,'')])
        with self.assertRaises(self.m.Failure): self.m.safe_extract(path,self.home/'extract')
    def test_verified_node_archive_preserves_contained_symlinks(self):
        path=self.archive([('node/lib/npm/cli.js',b'node',tarfile.REGTYPE,''),('node/bin/npm',b'',tarfile.SYMTYPE,'../lib/npm/cli.js')])
        target=self.home/'node'; self.m.safe_extract(path,target)
        self.assertEqual((target/'node/bin/npm').read_bytes(),b'node')
    def test_rc_guard_restores_and_rejects_and_detects_harness_change(self):
        rc=self.home/'.bashrc'; rc.write_bytes(b'original\n')
        harness=self.home/'.codex'; harness.mkdir(); auth=harness/'auth.json'; auth.write_text('fixture')
        saved=self.m.snapshot_user_files(); rc.write_bytes(b'changed\n')
        with self.assertRaises(self.m.Failure) as error: self.m.verify_user_files(saved)
        self.assertEqual(error.exception.code,'installer_modified_shell_config'); self.assertEqual(rc.read_bytes(),b'original\n')
        saved=self.m.snapshot_user_files(); auth.write_text('modified')
        with self.assertRaises(self.m.Failure) as error: self.m.verify_user_files(saved)
        self.assertEqual(error.exception.code,'installer_modified_harness_config')
    def test_rc_guard_restores_bytes_and_mode_through_unchanged_nested_symlinks(self):
        target=self.home/'dotfiles/zshrc'; target.parent.mkdir(); target.write_bytes(b'original shell settings\n'); target.chmod(0o640)
        alias=self.home/'shell-alias'; alias.symlink_to('dotfiles/zshrc')
        rc=self.home/'.zshrc'; rc.symlink_to('shell-alias')
        original_link=os.readlink(rc); original_alias=os.readlink(alias)
        snapshot=self.m.snapshot_user_files()
        rc.write_bytes(b'installer mutation\n'); rc.chmod(0o600)
        with self.assertRaises(self.m.Failure) as error: self.m.verify_user_files(snapshot)
        self.assertEqual(error.exception.code,'installer_modified_shell_config')
        self.assertEqual(target.read_bytes(),b'original shell settings\n'); self.assertEqual(target.stat().st_mode&0o777,0o640)
        self.assertEqual(os.readlink(rc),original_link); self.assertEqual(os.readlink(alias),original_alias)
        self.m.verify_user_files(snapshot)
    def test_rc_guard_restores_a_symlink_target_replaced_by_directory(self):
        target=self.home/'real-zshrc'; target.write_bytes(b'original'); target.chmod(0o600)
        rc=self.home/'.zshrc'; rc.symlink_to('real-zshrc'); snapshot=self.m.snapshot_user_files()
        target.unlink(); target.mkdir(); (target/'installer-created').write_text('mutation')
        with self.assertRaises(self.m.Failure) as error: self.m.verify_user_files(snapshot)
        self.assertEqual(error.exception.code,'installer_modified_shell_config')
        self.assertEqual(target.read_bytes(),b'original'); self.assertEqual(target.stat().st_mode&0o777,0o600)
        self.assertEqual(os.readlink(rc),'real-zshrc')
    def test_rc_guard_handles_and_restores_a_symlink_cycle(self):
        rc=self.home/'.zshrc'; alias=self.home/'shell-loop'; rc.symlink_to('shell-loop'); alias.symlink_to('.zshrc')
        snapshot=self.m.snapshot_user_files(); self.m.verify_user_files(snapshot)
        alias.unlink(); alias.write_bytes(b'installer mutation')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
        self.assertEqual(os.readlink(rc),'shell-loop'); self.assertEqual(os.readlink(alias),'.zshrc')
        self.m.verify_user_files(snapshot)
    def test_guard_allows_observed_runtime_activity_and_identical_content_rewrites(self):
        codex=self.home/'.codex'; codex.mkdir()
        grok=self.home/'.grok'; grok.mkdir()
        config=codex/'config.toml'; config.write_text('settings=1\n')
        identity=grok/'agent_id'; identity.write_text('same-agent')
        snapshot=self.m.snapshot_user_files()
        for relative in ('tmp/one','log/events','logs/events','sessions/new/session.jsonl','archived_sessions/session.jsonl','history.jsonl','session_index.jsonl','state_5.sqlite','state_5.sqlite-wal','state_5.sqlite-shm','logs_1.sqlite-journal'):
            path=codex/relative; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('new runtime activity')
        for relative in ('sessions/new.jsonl','logs/new.log'):
            path=grok/relative; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('new runtime activity')
        config.write_text('settings=1\n'); identity.write_text('same-agent')
        self.m.verify_user_files(snapshot)
        identity.write_text('changed-agent')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
    def test_guard_rejects_unknown_config_permissions_and_new_nested_files(self):
        root=self.home/'.codex'; root.mkdir(); config=root/'config.toml'; config.write_text('settings=1')
        snapshot=self.m.snapshot_user_files(); config.chmod(0o700)
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
        config.chmod(0o600); snapshot=self.m.snapshot_user_files()
        unknown=root/'custom/nested/auth.json'; unknown.parent.mkdir(parents=True); unknown.write_text('protected')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
    def test_guard_follows_nested_config_and_auth_aliases_and_directory_aliases(self):
        target=self.home/'linked-configs'; target.mkdir(); auth=target/'auth.json'; auth.write_text('original')
        root=self.home/'.codex'; root.symlink_to(target,target_is_directory=True)
        nested=target/'aliases'; nested.mkdir(); real=self.home/'real-config.toml'; real.write_text('original settings')
        (nested/'config.toml').symlink_to(real)
        snapshot=self.m.snapshot_user_files(); auth.write_text('changed')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
        auth.write_text('original'); snapshot=self.m.snapshot_user_files(); real.write_text('changed settings')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
    def test_guard_protects_config_alias_to_a_runtime_location_and_handles_cycles(self):
        root=self.home/'.codex'; root.mkdir(); runtime=root/'sessions'; runtime.mkdir(); file=runtime/'entry'; file.write_text('original')
        (root/'config.toml').symlink_to(file); (root/'recursive').symlink_to(root,target_is_directory=True)
        snapshot=self.m.snapshot_user_files(); self.m.verify_user_files(snapshot)
        file.write_text('changed')
        with self.assertRaises(self.m.Failure): self.m.verify_user_files(snapshot)
    def test_bundle_fingerprint_binds_content_even_if_manifest_hash_changed(self):
        content=b'fixture'; source='remote/src/server.mjs'; digest=hashlib.sha256()
        digest.update((source+'\0false\0'+'0\0').encode()); digest.update(hashlib.sha256(content).digest()); fp=digest.hexdigest()
        manifest={'fingerprint':fp,'files':{'src/server.mjs':{'sourcePath':source,'sourceMode':0,'mode':0o600,'sha256':hashlib.sha256(content).hexdigest()}}}
        path=self.archive([('src/server.mjs',content,tarfile.REGTYPE,''),('manifest.json',json.dumps(manifest).encode(),tarfile.REGTYPE,'')])
        self.m.safe_extract(path,self.home/'valid',fp)
        content=b'tampered'; manifest['files']['src/server.mjs']['sha256']=hashlib.sha256(content).hexdigest()
        path=self.archive([('src/server.mjs',content,tarfile.REGTYPE,''),('manifest.json',json.dumps(manifest).encode(),tarfile.REGTYPE,'')])
        with self.assertRaises(self.m.Failure): self.m.safe_extract(path,self.home/'tampered',fp)
    def install_bundle(self,bots=False,library=False,release_version=None,packed_library=None):
        versions={'nodeVersion':'26.12.1','playwrightVersion':'1.64.1','nodeSHA256':{'linux-x64':'a'*64},
            'dockerVersion':'29.9.3','dockerSHA256':{'linux-x64':hashlib.sha256(b'docker-fixture').hexdigest(),'linux-arm64':'b'*64}}
        files={'host/runtime-versions.json':json.dumps(versions).encode(),
            'default-agent/package-lock.json':json.dumps({'packages':{'node_modules/playwright-core':{'version':'1.64.1'}}}).encode(),
            'src/server.mjs':b'fixture',
            'npm-runtime/package.json':(ROOT/'remote/npm-runtime/package.json').read_bytes(),
            'npm-runtime/package-lock.json':(ROOT/'remote/npm-runtime/package-lock.json').read_bytes()}
        if bots: files.update({'bots/package.json':b'{"version":"0.1.0"}','bots/package-lock.json':b'{}','bots/src/cli.ts':b'fixture','host/bots-engine.py':b'# fixture helper\n'})
        if library: files['host/library/linux-x86_64/wovenmatter-library']=b'fixture library host'
        if packed_library is not None:
            # As build-linux-library.sh ships it: the gzip and the uncompressed binary's SHA-256.
            binary,recorded=packed_library
            files['host/library/linux-x86_64/wovenmatter-library.gz']=gzip.compress(binary,mtime=0)
            files['host/library/linux-x86_64/wovenmatter-library.sha256']=(recorded+'  wovenmatter-library\n').encode()
        digest=hashlib.sha256(); records={}
        for name,data in sorted(files.items(),key=lambda item:item[0] if item[0].startswith(('default-agent/','bots/')) else 'remote/'+item[0]):
            source=name if name.startswith(('default-agent/','bots/')) else 'remote/'+name
            digest.update((source+'\0false\0'+'0\0').encode()); digest.update(hashlib.sha256(data).digest())
            records[name]={'sourcePath':source,'sourceMode':0,'mode':0o600,'sha256':hashlib.sha256(data).hexdigest()}
        fp=digest.hexdigest(); manifest={'fingerprint':fp,'nodeVersion':'26.12.1','playwrightVersion':'1.64.1','files':records}
        if release_version is not None: manifest['releaseVersion']=release_version
        path=self.archive([(name,data,tarfile.REGTYPE,'') for name,data in files.items()]+[('manifest.json',json.dumps(manifest).encode(),tarfile.REGTYPE,'')])
        data=path.read_bytes(); stream=self.home/'stream'; stream.write_bytes((TOKEN+'\n').encode()+data)
        node=self.m.ROOT/'node/26.12.1/bin/node'; node.parent.mkdir(parents=True,exist_ok=True); node.write_bytes(b'fixture')
        return fp,stream
    def test_install_update_and_failed_selftest_restore_all_activation_state(self):
        self.m.ROOT.mkdir(parents=True)
        fp,stream=self.install_bundle(); self.m.TOKEN=''
        self.m.health=lambda *a:{'serviceFingerprint':fp,'runtimeKind':'host'}
        source=open(stream,'rb'); saved_fd=None
        try:
            try: saved_fd=os.dup(3)
            except OSError: pass
            os.dup2(source.fileno(),3)
            result=self.m.install('fixture','7337','fullRoot',fp)
            self.assertEqual(result['fingerprint'],fp); self.assertEqual(result['state'],'running')
            before={p:p.read_bytes() for p in (self.m.ENV_FILE,self.m.UNIT,self.m.RECORD,self.m.ROOT/'run/browser-selftest.json')}
            links={p:os.readlink(p) for p in (self.m.ROOT/'current',self.m.ROOT/'node/current',self.m.ROOT/'browsers/current')}
            self.assertIn(b'NoNewPrivileges=no',before[self.m.UNIT])
            tooling=self.m.ROOT/'current/tooling/lib/node_modules/npm'
            graph=json.loads((ROOT/'remote/npm-runtime/package-lock.json').read_text())['packages']
            for key in graph:
                if not key.startswith('node_modules/') or '/node_modules/' in key[13:]: continue
                name=key[13:]
                self.assertEqual(json.loads((tooling/'node_modules'/name/'package.json').read_text())['version'],graph['node_modules/'+name]['version'])
            self.assertEqual((self.m.ROOT/'current/default-agent/lib/npm').resolve(),tooling.resolve())
            node_file=self.m.ROOT/'node/26.12.1/bin/node'; before_node=node_file.read_bytes()
            before_tooling=(self.m.ROOT/'current/tooling/security.json').read_bytes()
            for call in self.calls:
                if 'npm@>=12.2.2' in call: self.assertNotIn(str(self.m.ROOT/'node/26.12.1'),call[call.index('--prefix')+1])
            # Update may reuse the existing credential with an empty first line.
            stream.write_bytes(b'\n'+self.home.joinpath('bundle.tar').read_bytes()); source.seek(0); self.m.TOKEN=''; self.fail_selftest=True
            with self.assertRaises(self.m.Failure) as error: self.m.install('fixture','7337','fullRoot',fp,True)
            self.assertEqual(error.exception.code,'browser_selftest_failed')
            self.assertEqual(before,{p:p.read_bytes() for p in before}); self.assertEqual(links,{p:os.readlink(p) for p in links})
            self.assertTrue(self.active); self.assertTrue(self.enabled)
            self.assertTrue(self.m.status('fixture')['browserSelfTest']['ok'])
            self.assertEqual(node_file.read_bytes(),before_node)
            self.assertEqual((self.m.ROOT/'current/tooling/security.json').read_bytes(),before_tooling)
            self.fail_selftest=False; (self.m.ROOT/'current/src/server.mjs').write_text('corrupted')
            source.seek(0); self.m.TOKEN=''
            with self.assertRaises(self.m.Failure) as error: self.m.install('fixture','7337','fullRoot',fp,True)
            self.assertEqual(error.exception.code,'existing_release_corrupt')
            self.assertEqual(before,{p:p.read_bytes() for p in before})
        finally:
            if saved_fd is not None: os.dup2(saved_fd,3); os.close(saved_fd)
            source.close()
    def test_outdated_private_npm_is_rejected_before_vendor_installation(self):
        release=self.home/'candidate'; release.mkdir()
        self.npm_version='12.2.1'
        with self.assertRaises(self.m.Failure) as error:
            self.m.prepare_npm_tooling(self.home/'immutable-node',release,{})
        self.assertEqual(error.exception.code,'npm_security_verification_failed')
        self.assertFalse(any('ci' in call for call in self.calls))
        self.assertFalse((self.m.ROOT/'current').exists())
    def test_incorrect_npm_vendor_is_rejected_before_activation(self):
        release=self.home/'candidate'; release.mkdir()
        prefix=release/'npm-runtime'; prefix.mkdir()
        (prefix/'package-lock.json').write_bytes((ROOT/'remote/npm-runtime/package-lock.json').read_bytes())
        self.bad_npm_vendor=True
        with self.assertRaises(self.m.Failure) as error:
            self.m.prepare_npm_tooling(self.home/'immutable-node',release,{})
        self.assertEqual(error.exception.code,'npm_security_verification_failed')
    def test_readable_serve_status_does_not_hide_missing_operator_and_prepare_is_idempotent(self):
        self.tail_operator=''; self.m.os_release=lambda:{'ID':'debian','VERSION_ID':'13'}
        with mock.patch.object(self.m.shutil,'which',return_value='/usr/bin/tailscale'):
            actions=self.m.privileged_actions(self.m.os_release())
            expected=['tailscale','set','--operator='+self.m.pwd.getpwuid(self.actual_uid).pw_name]
            self.assertEqual(actions,[expected])
            self.assertTrue(self.m.inspect()['preparationRequired'])
            result=self.m.prepare('AUTHORIZED','user')
            self.assertTrue(result['prepared']); self.assertTrue(result['tailscaleOperatorReady'])
            self.assertEqual(self.m.privileged_actions(self.m.os_release()),[])
            self.assertTrue(any(call==['sudo','-n',*expected] for call in self.calls))
    def test_ubuntu_restriction_prepares_missing_apparmor_parser(self):
        parser_paths=('/usr/sbin/apparmor_parser','/sbin/apparmor_parser')
        actual_is_file=Path.is_file
        # Production checks standard sbin locations as well as PATH. Mock both
        # discovery routes so Ubuntu CI's installed parser cannot leak in.
        for available in (None,*parser_paths,'/fixture/bin/apparmor_parser'):
            with self.subTest(available=available):
                def is_file(path,*args,**kwargs):
                    return str(path)==available if str(path) in parser_paths else actual_is_file(path,*args,**kwargs)
                with mock.patch.object(self.m,'apparmor_restriction',return_value=1), \
                     mock.patch.object(self.m.shutil,'which',return_value=available if available=='/fixture/bin/apparmor_parser' else None), \
                     mock.patch.object(Path,'is_file',autospec=True,side_effect=is_file):
                    packages=self.m.dependency_packages({'ID':'ubuntu','VERSION_ID':'24.04'})
                self.assertEqual('apparmor' in packages,available is None)
                self.assertIn('libasound2t64',packages)
        self.assertNotIn('apparmor',self.m.dependency_packages({'ID':'debian','VERSION_ID':'13'}))
    def test_access_mode_cannot_change_under_existing_agent_processes(self):
        self.save_install()
        with self.assertRaises(self.m.Failure) as error:
            self.m.install('fixture','7337','user','a'*64,True)
        self.assertEqual(error.exception.code,'access_mode_change_requires_reinstall')
    def test_private_expose_preserves_routes_and_refuses_funnel(self):
        self.save_install(); self.m.health=lambda *a:{'status':'ok'}
        endpoint='fixture.test.ts.net:8443'; route='/wovenmatter-execution/fixture'
        configuration={'Web':{endpoint:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'},'/unrelated':{'Proxy':'http://127.0.0.1:9000'}}}}}
        def fake(args,**kwargs):
            if list(args[:3])==['tailscale','serve','status']:
                return subprocess.CompletedProcess(args,0,json.dumps(configuration).encode(),b'')
            return self.command(args,**kwargs)
        with mock.patch.object(self.m,'run',side_effect=fake):
            result=self.m.expose('fixture','7337','8443')
            self.assertEqual(result['endpoint'],'https://'+endpoint+route)
            configuration['AllowFunnel']={endpoint:True}
            with self.assertRaises(self.m.Failure) as error: self.m.expose('fixture','7337','8443')
            self.assertEqual(error.exception.code,'tailscale_route_conflict')
            configuration.pop('AllowFunnel'); configuration['Web'][endpoint]['Handlers'][route]['Proxy']='http://127.0.0.1:9001'
            with self.assertRaises(self.m.Failure): self.m.expose('fixture','7337','8443')
        self.assertFalse(any(call[:2]==['tailscale','serve'] for call in self.calls))
    def test_valid_empty_null_serve_status_allows_cleanup_and_first_expose(self):
        self.save_install(); self.m.health=lambda *a:{'status':'ok'}
        configuration=None; endpoint='fixture.test.ts.net:8443'; route='/wovenmatter-execution/fixture'
        def fake(args,**kwargs):
            nonlocal configuration
            if list(args[:3])==['tailscale','serve','status']: return subprocess.CompletedProcess(args,0,json.dumps(configuration).encode(),b'')
            if args[0:2]==['tailscale','serve']:
                configuration={'TCP':{'8443':{'HTTPS':True}},'Web':{endpoint:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'}}}}}
                return subprocess.CompletedProcess(args,0,b'',b'')
            return self.command(args,**kwargs)
        with mock.patch.object(self.m,'run',side_effect=fake):
            self.assertEqual(self.m.cleanup_private_routes('fixture',7337),0)
            result=self.m.expose('fixture','7337','8443')
        self.assertEqual(result['endpoint'],'https://'+endpoint+route)
    def test_uninstall_removes_only_owned_private_routes_and_preserves_foreign_and_funnel(self):
        self.save_install(); (self.m.ROOT/'releases').mkdir(); self.m.UNIT.parent.mkdir(parents=True); self.m.UNIT.write_text('fixture')
        endpoint='fixture.test.ts.net:8443'; second='fixture.test.ts.net:8444'; other='fixture.test.ts.net:9443'; public='fixture.test.ts.net:443'; route='/wovenmatter-execution/fixture'
        configuration={'TCP':{'8443':{'HTTPS':True},'8444':{'HTTPS':True},'9443':{'HTTPS':True},'443':{'HTTPS':True}},
            'Web':{endpoint:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'},'/other':{'Proxy':'http://127.0.0.1:9000'}}},
                second:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'}}},other:{'Handlers':{route:{'Proxy':'http://127.0.0.1:9555'}}},public:{'Handlers':{'/public':{'Proxy':'http://127.0.0.1:8000'}}}},'AllowFunnel':{public:True}}
        removals=[]
        def fake(args,**kwargs):
            if list(args[:3])==['tailscale','serve','status']: return subprocess.CompletedProcess(args,0,json.dumps(configuration).encode(),b'')
            if args[0:2]==['tailscale','serve']:
                removals.append(args); port=args[2].split('=',1)[1]; owned_endpoint='fixture.test.ts.net:'+port
                del configuration['Web'][owned_endpoint]['Handlers'][route]
                if not configuration['Web'][owned_endpoint]['Handlers']:
                    del configuration['Web'][owned_endpoint]; del configuration['TCP'][port]
                return subprocess.CompletedProcess(args,0,b'',b'')
            return self.command(args,**kwargs)
        with mock.patch.object(self.m,'run',side_effect=fake): result=self.m.uninstall('fixture')
        self.assertEqual(result['privateRoutesRemoved'],2); self.assertTrue(result['privateRoutesCleanupVerified'])
        self.assertEqual(removals,[['tailscale','serve','--https=8443','--set-path='+route,'off'],['tailscale','serve','--https=8444','--set-path='+route,'off']])
        self.assertIn('/other',configuration['Web'][endpoint]['Handlers']); self.assertIn(route,configuration['Web'][other]['Handlers'])
        self.assertEqual(configuration['AllowFunnel'],{public:True})
    def test_failed_route_cleanup_preserves_installed_service_and_data(self):
        self.save_install(); (self.m.ROOT/'releases').mkdir(); self.m.UNIT.parent.mkdir(parents=True); self.m.UNIT.write_text('fixture')
        endpoint='fixture.test.ts.net:8443'; route='/wovenmatter-execution/fixture'
        configuration={'TCP':{'8443':{'HTTPS':True}},'Web':{endpoint:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'}}}}}
        def fake(args,**kwargs):
            if list(args[:3])==['tailscale','serve','status']: return subprocess.CompletedProcess(args,0,json.dumps(configuration).encode(),b'')
            if args[0:2]==['tailscale','serve']: return subprocess.CompletedProcess(args,1,b'',b'operator required')
            return self.command(args,**kwargs)
        with mock.patch.object(self.m,'run',side_effect=fake):
            with self.assertRaises(self.m.Failure) as error: self.m.uninstall('fixture',True)
        self.assertEqual(error.exception.code,'tailscale_route_cleanup_failed'); self.assertTrue(self.m.UNIT.exists()); self.assertTrue(self.m.RECORD.exists()); self.assertTrue(self.active)
        self.assertFalse(any(call[:3]==['systemctl','--user','disable'] for call in self.calls))
    def test_unavailable_status_or_owned_funnel_route_never_claims_cleanup_success(self):
        self.save_install()
        with mock.patch.object(self.m,'run',return_value=subprocess.CompletedProcess([],1,b'',b'unavailable')):
            with self.assertRaises(self.m.Failure) as error: self.m.uninstall('fixture')
        self.assertEqual(error.exception.code,'tailscale_cleanup_unavailable')
        endpoint='fixture.test.ts.net:8443'; route='/wovenmatter-execution/fixture'
        config={'TCP':{'8443':{'HTTPS':True}},'Web':{endpoint:{'Handlers':{route:{'Proxy':'http://127.0.0.1:7337'}}}},'AllowFunnel':{endpoint:True}}
        with mock.patch.object(self.m,'run',return_value=subprocess.CompletedProcess([],0,json.dumps(config).encode(),b'')):
            with self.assertRaises(self.m.Failure) as error: self.m.uninstall('fixture')
        self.assertEqual(error.exception.code,'tailscale_cleanup_conflict'); self.assertTrue(self.m.RECORD.exists())
    def test_uninstall_keeps_data_and_explicit_data_removal(self):
        self.save_install(); (self.m.ROOT/'releases').mkdir(); (self.m.ROOT/'workspace').mkdir(); (self.m.ROOT/'workspace/keep').write_text('kept')
        self.m.UNIT.parent.mkdir(parents=True); self.m.UNIT.write_text('fixture')
        result=self.m.uninstall('fixture'); self.assertFalse(result['persistentDataRemoved']); self.assertTrue((self.m.ROOT/'workspace/keep').exists())
        (self.m.ROOT/'releases').mkdir(); self.m.ROOT.chmod(0o700)
        with mock.patch.object(self.m.os,'getuid',return_value=self.m.ROOT.stat().st_uid): result=self.m.uninstall('fixture',True)
        self.assertTrue(result['persistentDataRemoved']); self.assertFalse(self.m.ROOT.exists())

    def feed(self,stream):
        source=open(stream,'rb'); saved=None
        try: saved=os.dup(3)
        except OSError: pass
        os.dup2(source.fileno(),3)
        def restore():
            if saved is not None: os.dup2(saved,3); os.close(saved)
            source.close()
        self.addCleanup(restore)
        return source
    def test_bots_only_install_then_adding_the_workspace_reuses_the_server(self):
        self.m.ROOT.mkdir(parents=True)
        fp,stream=self.install_bundle(bots=True); self.m.TOKEN=''
        self.m.health=lambda *a:{'serviceFingerprint':fp,'runtimeKind':'host'}
        source=self.feed(stream)
        result=self.m.main(['install','fixture','7337','fullRoot',fp,'bots'])
        self.assertEqual(result['roles'],{'workspace':False,'bots':True})
        settings=self.m.parse_env()
        self.assertEqual(settings['WOVENMATTER_WORKSPACE_ENABLED'],'0'); self.assertEqual(settings['WOVENMATTER_BOTS_ENABLED'],'1')
        self.assertEqual(settings['WOVENMATTER_BOTS_DATA'],str(self.m.ROOT/'bots'))
        self.assertFalse(any('playwright-core/cli.js' in ' '.join(call) for call in self.calls),'a bots-only server installs no host browser')
        self.assertFalse((self.m.ROOT/'browsers/current').exists())
        self.assertTrue(any(call[-1].endswith('--no-fund') and str(self.m.ROOT/'releases') in ' '.join(call) and '/bots' in call[call.index('--prefix')+1] for call in self.calls if 'ci' in call))
        [engine]=self.engine_calls
        self.assertEqual(engine[:4],[str(self.m.ROOT/'releases'/fp/'host/bots-engine.py'),'--instance','wovenmatter','install'])
        self.assertEqual(engine[engine.index('--docker-version')+1],'29.9.3')
        self.assertEqual(int(engine[engine.index('--pool')+1]),min(8*1024**3,self.m.memory_total() or 8*1024**3))
        # Adding the workspace is an update of the same server: same data root, no second engine install.
        stream.write_bytes(b'\n'+self.home.joinpath('bundle.tar').read_bytes()); source.seek(0); self.m.TOKEN=''
        self.m.BOTS_HELPER.parent.mkdir(parents=True); self.m.BOTS_HELPER.write_bytes(b'# fixture helper\n')
        updated=self.m.main(['update','fixture','7337','fullRoot',fp,'workspace'])
        self.assertEqual(updated['roles'],{'workspace':True,'bots':True},'roles only grow on update')
        self.assertEqual(len(self.engine_calls),1)
        self.assertEqual(self.m.parse_env()['WOVENMATTER_WORKSPACE_ENABLED'],'1')
        self.assertTrue(any('playwright-core/cli.js' in ' '.join(call) for call in self.calls))
        self.assertEqual(self.m.parse_env()['WOVENMATTER_API_TOKEN'],TOKEN)
    def test_a_bots_only_placeholder_becomes_the_real_workspace_once(self):
        # The Mac records a bots-only host as `bots`; adding the workspace later installs
        # with the real id and must reuse that server, port, token and data root.
        self.m.ROOT.mkdir(parents=True)
        fp,stream=self.install_bundle(bots=True,release_version='1.4.0'); self.m.TOKEN=''
        self.m.health=lambda *a:{'serviceFingerprint':fp,'runtimeKind':'host'}
        source=self.feed(stream)
        first=self.m.main(['install','bots','7337','fullRoot',fp,'bots'])
        self.assertEqual(first['roles'],{'workspace':False,'bots':True})
        self.assertEqual(self.m.parse_env()['WOVENMATTER_RELEASE_VERSION'],'1.4.0')
        self.assertEqual(first['releaseVersion'],'1.4.0')
        port=self.m.record()['port']
        def again():
            stream.write_bytes(b'\n'+self.home.joinpath('bundle.tar').read_bytes()); source.seek(0); self.m.TOKEN=''
        # Only a workspace install may take over the placeholder, never an update or another bots install.
        again()
        with self.assertRaises(self.m.Failure) as conflict: self.m.main(['update','studio','7337','fullRoot',fp,'workspace'])
        self.assertEqual(conflict.exception.code,'host_workspace_conflict')
        again()
        with self.assertRaises(self.m.Failure) as conflict: self.m.main(['install','studio','7337','fullRoot',fp,'bots'])
        self.assertEqual(conflict.exception.code,'host_workspace_conflict')
        self.m.BOTS_HELPER.parent.mkdir(parents=True); self.m.BOTS_HELPER.write_bytes(b'# fixture helper\n')
        again()
        converted=self.m.main(['install','studio','7337','fullRoot',fp,'workspace'])
        self.assertEqual(converted['id'],'studio')
        self.assertEqual(converted['roles'],{'workspace':True,'bots':True})
        record=self.m.record()
        self.assertEqual((record['id'],record['port'],record['previousIDs']),('studio',port,['bots']))
        settings=self.m.parse_env()
        self.assertEqual(settings['WOVENMATTER_API_TOKEN'],TOKEN)
        self.assertEqual((settings['WOVENMATTER_DATA_ROOT'],settings['WOVENMATTER_BOTS_DATA']),(str(self.m.ROOT),str(self.m.ROOT/'bots')))
        self.assertEqual((settings['WOVENMATTER_WORKSPACE_ENABLED'],settings['WOVENMATTER_BOTS_ENABLED']),('1','1'))
        self.assertEqual(len(self.engine_calls),1,'the running engine is kept, not installed again')
        # Once: the placeholder is gone, so a second workspace id is a conflict again.
        again()
        with self.assertRaises(self.m.Failure) as conflict: self.m.main(['install','other','7337','fullRoot',fp,'workspace'])
        self.assertEqual(conflict.exception.code,'host_workspace_conflict')
        self.assertEqual(self.m.status('studio')['roles'],{'workspace':True,'bots':True})
    def test_workspace_install_without_roles_is_unchanged_and_old_records_read_as_workspace(self):
        self.save_install()
        self.assertEqual(self.m.record()['roles'],{'workspace':True,'bots':False})
        self.assertEqual(self.m.status('fixture')['botsState'],'server_without_bots')
        missing=lambda args,**kwargs: subprocess.CompletedProcess(args,1 if args[0]=='pacman' else 0,b'yes\n' if args[0]=='loginctl' else b'',b'')
        with mock.patch.object(self.m,'run',side_effect=missing), mock.patch.object(self.m.shutil,'which',return_value=None):
            packages=self.m.privileged_actions({'ID':'arch'},{'workspace':False,'bots':True})
        self.assertEqual(packages[-1][:3],['pacman','-S','--needed'])
        flat=' '.join(' '.join(action) for action in packages)
        self.assertIn('nftables',flat); self.assertNotIn('nss',flat.split())
        with self.assertRaises(self.m.Failure): self.m.valid_roles('workspace,unknown')
    def test_discovery_reports_no_server_server_without_bots_and_bots_ready(self):
        self.m.os_release=lambda:{'ID':'debian','VERSION_ID':'13'}
        self.assertEqual(self.m.inspect('user')['bots']['state'],'no_server')
        found=self.m.inspect('user','bots')['bots']
        self.assertGreater(found['memoryTotalBytes'] or 1,0); self.assertGreater(found['diskTotalBytes'],0); self.assertIn('diskFreeBytes',found)
        self.save_install()
        self.assertEqual(self.m.inspect('user')['bots']['state'],'server_without_bots')
        record=json.loads(self.m.RECORD.read_text()); record['roles']={'workspace':True,'bots':True}; self.m.RECORD.write_text(json.dumps(record))
        self.m.BOTS_ETC.mkdir(parents=True); socket_path=self.home/'docker.sock'
        import socket as sockets
        listener=sockets.socket(sockets.AF_UNIX); listener.bind(str(socket_path)); self.addCleanup(listener.close)
        self.m.BOTS_ETC.joinpath('instance.json').write_text(json.dumps({'user':self.m.pwd.getpwuid(self.actual_uid).pw_name,'socket':str(socket_path),'poolBytes':None,'diskBytes':None}))
        self.assertEqual(self.m.inspect('user')['bots']['state'],'bots_ready')
        self.m.BOTS_ETC.joinpath('instance.json').write_text(json.dumps({'user':'someone-else','socket':str(socket_path)}))
        other=self.m.inspect('user')['bots']
        self.assertEqual(other['state'],'server_without_bots'); self.assertTrue(other['blockingIssues'])
    def test_bots_configure_writes_a_request_and_uninstall_removes_the_engine_first(self):
        self.save_install(); record=json.loads(self.m.RECORD.read_text()); record['roles']={'workspace':True,'bots':True}; self.m.RECORD.write_text(json.dumps(record))
        self.m.BOTS_ETC.mkdir(parents=True); (self.m.BOTS_VAR/'requests').mkdir(parents=True); (self.m.BOTS_VAR/'state').mkdir(parents=True)
        self.m.BOTS_ETC.joinpath('instance.json').write_text(json.dumps({'user':self.m.pwd.getpwuid(self.actual_uid).pw_name,'socket':'/missing'}))
        result=self.m.main(['bots-configure','fixture','4294967296','none','1'])
        request=json.loads((self.m.BOTS_VAR/'requests/settings.json').read_text())
        self.assertEqual(request,{'revision':result['revision'],'poolBytes':4294967296,'diskBytes':None})
        self.assertTrue(result['pending'])
        with self.assertRaises(self.m.Failure): self.m.main(['bots-configure','fixture','-1','none'])
        self.m.BOTS_HELPER.parent.mkdir(parents=True); self.m.BOTS_HELPER.write_text('# installed helper'); (self.m.ROOT/'releases').mkdir()
        removed=self.m.uninstall('fixture')
        self.assertTrue(removed['botsEngineRemoved'])
        self.assertEqual(self.engine_calls[0][:4],[str(self.m.BOTS_HELPER),'--instance','wovenmatter','uninstall'])

    def test_library_migrates_before_activation_and_a_failed_migration_restores_everything(self):
        self.m.ROOT.mkdir(parents=True)
        fp,stream=self.install_bundle(library=True); self.m.TOKEN=''
        self.m.health=lambda *a:{'serviceFingerprint':fp,'runtimeKind':'host'}
        identity={'deviceID':'6f1c2a5e-8b3d-4c7a-9e21-0d4b5c6a7f80','kind':'linux','name':'Fixture','publicKey':'FcjTkjz8DN0RYScE/kWqgsa7w7ns8c2d0RfOoCRv1n0=','libraryEndpoint':'https://fixture.test.ts.net:10000/wovenmatter'}
        self.m.LIBRARY_STATE.mkdir(parents=True); (self.m.LIBRARY_STATE/'identity.json').write_text(json.dumps(identity))
        source=open(stream,'rb'); saved_fd=None
        try:
            try: saved_fd=os.dup(3)
            except OSError: pass
            os.dup2(source.fileno(),3)
            result=self.m.install('fixture','7337','fullRoot',fp)
            self.assertEqual(result['memberIdentity'],identity)
            migration=self.migrations[-1]
            self.assertEqual(migration[0],str(self.m.ROOT/'releases'/fp/'host/library/linux-x86_64/wovenmatter-library'))
            self.assertEqual(migration[1:4],['--data-root',str(self.m.ROOT),'--migrate-only'])
            # The migration runs with the old service stopped, before the release switch.
            stop=max(i for i,call in enumerate(self.calls) if call[:3]==['systemctl','--user','stop'])
            self.assertLess(stop,self.calls.index(migration))
            database=self.m.ROOT/'library/workspace.sqlite'; database.write_bytes(b'user data')
            links={p:os.readlink(p) for p in (self.m.ROOT/'current',self.m.ROOT/'node/current')}
            stream.write_bytes(b'\n'+self.home.joinpath('bundle.tar').read_bytes()); source.seek(0); self.m.TOKEN=''; self.fail_migration=True
            with self.assertRaises(self.m.Failure) as error: self.m.install('fixture','7337','fullRoot',fp,True)
            self.assertEqual(error.exception.code,'library_migration_failed')
            self.assertEqual(database.read_bytes(),b'user data'); self.assertFalse((self.m.ROOT/'library/workspace.sqlite-wal').exists())
            self.assertEqual(links,{p:os.readlink(p) for p in links}); self.assertTrue(self.active)
            self.assertEqual(self.m.inspect()['memberIdentity'],identity); self.assertEqual(self.m.status('fixture')['memberIdentity'],identity)
        finally:
            if saved_fd is not None: os.dup2(saved_fd,3); os.close(saved_fd)
            source.close()
    def test_a_compressed_library_binary_is_unpacked_and_verified_before_it_runs(self):
        binary=b'\x7fELF fixture library host '*4096
        self.m.ROOT.mkdir(parents=True)
        fp,stream=self.install_bundle(packed_library=(binary,hashlib.sha256(binary).hexdigest())); self.m.TOKEN=''
        self.m.health=lambda *a:{'serviceFingerprint':fp,'runtimeKind':'host'}
        # The installer waits for the library host's identity; this one is already known.
        self.m.LIBRARY_STATE.mkdir(parents=True); (self.m.LIBRARY_STATE/'identity.json').write_text(json.dumps({'deviceID':'6f1c2a5e-8b3d-4c7a-9e21-0d4b5c6a7f80'}))
        source=self.feed(stream)
        self.m.install('fixture','7337','fullRoot',fp)
        unpacked=self.m.ROOT/'releases'/fp/'host/library/linux-x86_64/wovenmatter-library'
        self.assertEqual(self.migrations[-1][0],str(unpacked))
        self.assertEqual(unpacked.read_bytes(),binary)
        self.assertEqual(unpacked.stat().st_mode&0o777,0o700)
        # A tampered unpacked copy is replaced from the verified archive on the next use.
        unpacked.write_bytes(b'tampered')
        self.assertEqual(self.m.library_binary(self.m.ROOT/'releases'/fp),unpacked)
        self.assertEqual(unpacked.read_bytes(),binary)
        # A checksum that does not match the archive never runs.
        directory=self.m.ROOT/'releases'/fp/'host/library/linux-x86_64'
        unpacked.unlink(); (directory/'wovenmatter-library.sha256').write_text('0'*64+'  wovenmatter-library\n')
        with self.assertRaises(self.m.Failure) as error: self.m.library_binary(self.m.ROOT/'releases'/fp)
        self.assertEqual(error.exception.code,'library_verification_failed')
        self.assertFalse(unpacked.exists())
        self.assertEqual([path.name for path in directory.iterdir() if path.name.startswith('.')],[])
    def test_uninstall_removes_only_the_recorded_library_route(self):
        self.save_install(); (self.m.ROOT/'releases').mkdir(); self.m.UNIT.parent.mkdir(parents=True); self.m.UNIT.write_text('fixture')
        endpoint='fixture.test.ts.net:10000'
        configuration={'TCP':{'10000':{'HTTPS':True}},'Web':{endpoint:{'Handlers':{'/wovenmatter':{'Proxy':'http://127.0.0.1:41000'}}}}}
        self.m.LIBRARY_STATE.mkdir(parents=True)
        (self.m.LIBRARY_STATE/'serve.json').write_text(json.dumps({'dns':'fixture.test.ts.net','httpsPort':10000,'target':'http://127.0.0.1:41000','path':'/wovenmatter'}))
        removals=[]
        def fake(args,**kwargs):
            args=[str(a) for a in args]
            if args[:3]==['tailscale','serve','status']: return subprocess.CompletedProcess(args,0,json.dumps(configuration).encode(),b'')
            if args[:2]==['tailscale','serve']:
                removals.append(args); configuration['Web'][endpoint]['Handlers'].pop('/wovenmatter',None); return subprocess.CompletedProcess(args,0,b'',b'')
            return self.command(args,**kwargs)
        with mock.patch.object(self.m,'run',side_effect=fake): result=self.m.uninstall('fixture')
        self.assertEqual(result['privateRoutesRemoved'],1)
        self.assertEqual(removals,[['tailscale','serve','--https=10000','--set-path=/wovenmatter','off']])
        self.assertFalse((self.m.LIBRARY_STATE/'serve.json').exists())
        # A route someone else repointed is left alone.
        self.save_install(); (self.m.ROOT/'releases').mkdir(exist_ok=True)
        configuration['Web'][endpoint]['Handlers']['/wovenmatter']={'Proxy':'http://127.0.0.1:9999'}
        (self.m.LIBRARY_STATE/'serve.json').write_text(json.dumps({'dns':'fixture.test.ts.net','httpsPort':10000,'target':'http://127.0.0.1:41000'}))
        with mock.patch.object(self.m,'run',side_effect=fake): self.assertEqual(self.m.uninstall('fixture')['privateRoutesRemoved'],0)
        self.assertEqual(len(removals),1)

if __name__=='__main__': unittest.main()
