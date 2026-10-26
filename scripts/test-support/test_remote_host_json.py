#!/usr/bin/env python3
"""Provider-free lifecycle fixtures, archive attacks and rollback verification."""
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
        self.calls=[]; self.active=True; self.enabled=True; self.fail_selftest=False
        self.patchers=[mock.patch.object(self.m,'run',side_effect=self.command),
            mock.patch.object(self.m.platform,'system',return_value='Linux'),mock.patch.object(self.m.platform,'machine',return_value='x86_64'),
            mock.patch.object(self.m.os,'getuid',return_value=self.actual_uid),mock.patch.object(self.m,'inventory',return_value=[])]
        for patcher in self.patchers: patcher.start()
        self.m.owned_directory=lambda p: Path(p).mkdir(mode=0o700,parents=True,exist_ok=True)
    def tearDown(self):
        for patcher in reversed(self.patchers): patcher.stop()
        self.temp.cleanup()
    def command(self,args,**kwargs):
        args=[str(a) for a in args]; self.calls.append(args); output=b''; code=0
        if args[0]=='sudo': output=b'0\n'
        elif args[0]=='loginctl': output=b'yes\n'
        elif args[0]=='dpkg-query': output=b'installed'
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
        elif args[0]=='journalctl': output=('one '+TOKEN+' line').encode()
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
        self.m.privileged_actions=lambda d:[]; self.m.os_release=lambda:{'ID':'debian','VERSION_ID':'13'}
        self.assertTrue(self.m.main(['prepare','AUTHORIZED','user'])['prepared'])
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
    def test_bundle_fingerprint_binds_content_even_if_manifest_hash_changed(self):
        content=b'fixture'; source='remote/src/server.mjs'; digest=hashlib.sha256()
        digest.update((source+'\0false\0'+'0\0').encode()); digest.update(hashlib.sha256(content).digest()); fp=digest.hexdigest()
        manifest={'fingerprint':fp,'files':{'src/server.mjs':{'sourcePath':source,'sourceMode':0,'mode':0o600,'sha256':hashlib.sha256(content).hexdigest()}}}
        path=self.archive([('src/server.mjs',content,tarfile.REGTYPE,''),('manifest.json',json.dumps(manifest).encode(),tarfile.REGTYPE,'')])
        self.m.safe_extract(path,self.home/'valid',fp)
        content=b'tampered'; manifest['files']['src/server.mjs']['sha256']=hashlib.sha256(content).hexdigest()
        path=self.archive([('src/server.mjs',content,tarfile.REGTYPE,''),('manifest.json',json.dumps(manifest).encode(),tarfile.REGTYPE,'')])
        with self.assertRaises(self.m.Failure): self.m.safe_extract(path,self.home/'tampered',fp)
    def install_bundle(self):
        versions={'nodeVersion':'26.12.1','playwrightVersion':'1.64.1','nodeSHA256':{'linux-x64':'a'*64}}
        files={'host/runtime-versions.json':json.dumps(versions).encode(),
            'default-agent/package-lock.json':json.dumps({'packages':{'node_modules/playwright-core':{'version':'1.64.1'}}}).encode(),
            'src/server.mjs':b'fixture'}
        digest=hashlib.sha256(); records={}
        for name,data in sorted(files.items()):
            source=name if name.startswith('default-agent/') else 'remote/'+name
            digest.update((source+'\0false\0'+'0\0').encode()); digest.update(hashlib.sha256(data).digest())
            records[name]={'sourcePath':source,'sourceMode':0,'mode':0o600,'sha256':hashlib.sha256(data).hexdigest()}
        fp=digest.hexdigest(); manifest={'fingerprint':fp,'nodeVersion':'26.12.1','playwrightVersion':'1.64.1','files':records}
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
            before={p:p.read_bytes() for p in (self.m.ENV_FILE,self.m.UNIT,self.m.RECORD)}
            links={p:os.readlink(p) for p in (self.m.ROOT/'current',self.m.ROOT/'node/current',self.m.ROOT/'browsers/current')}
            self.assertIn(b'NoNewPrivileges=no',before[self.m.UNIT])
            # Update may reuse the existing credential with an empty first line.
            stream.write_bytes(b'\n'+self.home.joinpath('bundle.tar').read_bytes()); source.seek(0); self.m.TOKEN=''; self.fail_selftest=True
            with self.assertRaises(self.m.Failure) as error: self.m.install('fixture','7337','fullRoot',fp,True)
            self.assertEqual(error.exception.code,'browser_selftest_failed')
            self.assertEqual(before,{p:p.read_bytes() for p in before}); self.assertEqual(links,{p:os.readlink(p) for p in links})
            self.assertTrue(self.active); self.assertTrue(self.enabled)
            self.fail_selftest=False; (self.m.ROOT/'current/src/server.mjs').write_text('corrupted')
            source.seek(0); self.m.TOKEN=''
            with self.assertRaises(self.m.Failure) as error: self.m.install('fixture','7337','fullRoot',fp,True)
            self.assertEqual(error.exception.code,'existing_release_corrupt')
            self.assertEqual(before,{p:p.read_bytes() for p in before})
        finally:
            if saved_fd is not None: os.dup2(saved_fd,3); os.close(saved_fd)
            source.close()
    def test_ubuntu_restriction_prepares_missing_apparmor_parser(self):
        with mock.patch.object(self.m,'apparmor_restriction',return_value=1), mock.patch.object(self.m.shutil,'which',return_value=None):
            packages=self.m.dependency_packages({'ID':'ubuntu','VERSION_ID':'24.04'})
        self.assertIn('apparmor',packages); self.assertIn('libasound2t64',packages)
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
    def test_uninstall_keeps_data_and_explicit_data_removal(self):
        self.save_install(); (self.m.ROOT/'releases').mkdir(); (self.m.ROOT/'workspace').mkdir(); (self.m.ROOT/'workspace/keep').write_text('kept')
        self.m.UNIT.parent.mkdir(parents=True); self.m.UNIT.write_text('fixture')
        result=self.m.uninstall('fixture'); self.assertFalse(result['persistentDataRemoved']); self.assertTrue((self.m.ROOT/'workspace/keep').exists())
        (self.m.ROOT/'releases').mkdir(); self.m.ROOT.chmod(0o700)
        with mock.patch.object(self.m.os,'getuid',return_value=self.m.ROOT.stat().st_uid): result=self.m.uninstall('fixture',True)
        self.assertTrue(result['persistentDataRemoved']); self.assertFalse(self.m.ROOT.exists())

if __name__=='__main__': unittest.main()
