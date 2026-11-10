#!/usr/bin/env python3
"""The root bot engine helper's rendering and request handling, without root."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
cidr=lambda *octets,prefix: str(__import__('ipaddress').IPv4Network((bytes(octets+(0,)*(4-len(octets))),prefix)))
spec=importlib.util.spec_from_file_location('bots_engine',ROOT/'remote/host/bots-engine.py')
engine=importlib.util.module_from_spec(spec); spec.loader.exec_module(engine)

class RecordingHost:
    def __init__(self): self.calls=[]; self.codes={}
    def run(self,args,check=True,timeout=120,input=None):
        args=[str(a) for a in args]; self.calls.append(args)
        return subprocess.CompletedProcess(args,self.codes.get(tuple(args[:4]),0),b'',b'')
    def which(self,name): return '/usr/sbin/'+name

class Rendering(unittest.TestCase):
    def setUp(self):
        self.layout=engine.Layout('wovenmatter')
        self.config={'user':'trey','group':'trey','subnet':cidr(10,237,prefix=24),'poolBytes':8*1024**3,'diskBytes':50*1024**3}
    def test_production_names_match_the_contract(self):
        layout=self.layout
        self.assertEqual(layout.service,'wovenmatter-docker.service'); self.assertEqual(layout.slice,'wovenmatter-bots.slice')
        self.assertEqual(str(layout.socket),'/run/wovenmatter/docker.sock')
        self.assertEqual(layout.mount,'var-lib-wovenmatter\\x2dbots-docker.mount')
        self.assertLessEqual(len(layout.bridge),15); self.assertTrue(layout.bridge.startswith('br-'))
        test=engine.Layout('wmtest')
        self.assertTrue(set(test.unit_names()).isdisjoint(layout.unit_names()))
        self.assertNotEqual(test.bridge,layout.bridge); self.assertNotEqual(test.table,layout.table)
        self.assertEqual(engine.slice_path('wovenmatter-bots.slice'),['wovenmatter.slice','wovenmatter-bots.slice'])
        for name in ('','A','with-dash','x'*17,'../x'):
            with self.assertRaises(engine.Failure): engine.Layout(name)
    def test_daemon_uses_only_its_own_paths_and_never_edits_iptables(self):
        daemon=engine.render_daemon(self.layout,self.config)
        self.assertEqual(daemon['hosts'],['unix:///run/wovenmatter/docker.sock'])
        self.assertEqual(daemon['data-root'],'/var/lib/wovenmatter-bots/docker')
        self.assertTrue(daemon['exec-root'].startswith('/run/wovenmatter/')); self.assertTrue(daemon['pidfile'].startswith('/run/wovenmatter/'))
        self.assertIs(daemon['iptables'],False); self.assertIs(daemon['ip6tables'],False); self.assertIs(daemon['ip-forward'],False)
        self.assertEqual(daemon['cgroup-parent'],'wovenmatter-bots.slice'); self.assertEqual(daemon['bridge'],self.layout.bridge)
        # Regression: an address pool makes dockerd delete the user's docker0 on restart.
        self.assertNotIn('default-address-pools',daemon); self.assertNotIn('live-restore',daemon)
        self.assertNotIn('/etc/docker',json.dumps(daemon))
        # Never the system containerd at /run/containerd, which the user's Docker shares.
        self.assertEqual(daemon['containerd'],'/run/wovenmatter/containerd/containerd.sock')
        containerd=engine.render_containerd(self.layout)
        self.assertIn('root = "/var/lib/wovenmatter-bots/docker/containerd"',containerd)
        self.assertIn('address = "/run/wovenmatter/containerd/containerd.sock"',containerd)
        self.assertNotIn('/run/containerd/',containerd)
        units=engine.render_units(self.layout,self.config,'/usr/bin/python3')
        self.assertIn('Requires=wovenmatter-containerd.service',units[self.layout.service])
        self.assertIn('Slice=wovenmatter-bots.slice',units[self.layout.containerd])
    def test_egress_ruleset_blocks_tailnet_private_host_and_ipv6(self):
        rules=engine.render_ruleset(self.layout,self.config)
        for network in (cidr(100,64,prefix=10),cidr(10,prefix=8),cidr(172,16,prefix=12),cidr(192,168,prefix=16),cidr(169,254,prefix=16),cidr(127,prefix=8)):
            self.assertIn(network,rules)
        bridge=self.layout.bridge
        self.assertIn(f'iifname "{bridge}" meta nfproto ipv6 drop',rules)
        self.assertIn(f'iifname "{bridge}" drop',rules,'containers cannot reach any host address')
        self.assertIn(f'oifname "{bridge}" drop',rules,'nothing outside connects into the bridge')
        self.assertIn('masquerade',rules)
        self.assertTrue(rules.startswith('table inet wovenmatter_bots {}\ndelete table inet wovenmatter_bots\n'),'reloads replace the table atomically')
        # Bot containers cannot reach each other: frames bridged between two
        # ports of the bot bridge are dropped in its own bridge table.
        self.assertIn('table bridge wovenmatter_bots {}\ndelete table bridge wovenmatter_bots\n',rules)
        self.assertIn(f'meta ibrname "{bridge}" meta obrname "{bridge}" drop',rules)
        self.assertNotIn('docker0',rules)
        # Every rule names the bridge's own network: the address dockerd hands out.
        subnet=cidr(10,237,prefix=24)
        self.assertIn(f'iifname "{bridge}" ip saddr != {subnet} drop',rules)
        self.assertIn(f'ip saddr {subnet} oifname != "{bridge}" masquerade',rules)
        self.assertEqual(engine.bridge_address(self.config['subnet']),engine.address(10,237,0,1)+'/24')
        legacy=engine.render_ruleset(self.layout,{**self.config,'subnet':cidr(10,237,prefix=16)})
        self.assertEqual(legacy,rules,'a /16 recorded by an older install is filtered as its bridge /24')
        self.assertNotIn(f'iifname != "{bridge}" oifname != "{bridge}" drop',rules)
        owned=engine.render_ruleset(self.layout,self.config,drop_foreign=True)
        self.assertIn(f'iifname != "{bridge}" oifname != "{bridge}" drop',owned,'non-bot forwarding is dropped when the engine enabled it')
        self.assertNotIn('icc',engine.render_daemon(self.layout,self.config),'dockerd refuses icc=false without iptables')
    def test_units_apply_pool_and_mount_only_with_a_disk_cap(self):
        units=engine.render_units(self.layout,self.config,'/usr/bin/python3')
        self.assertIn('MemoryMax=8589934592',units[self.layout.slice])
        self.assertIn('Slice=wovenmatter-bots.slice',units[self.layout.service])
        self.assertIn('--config-file /etc/wovenmatter-bots/daemon.json',units[self.layout.service])
        self.assertIn('RequiresMountsFor=/var/lib/wovenmatter-bots/docker',units[self.layout.service])
        self.assertIn('Options=loop,discard,noatime',units[self.layout.mount])
        self.assertIn('PathChanged=/var/lib/wovenmatter-bots/requests/settings.json',units[self.layout.apply_path])
        self.assertIn('PartOf=nftables.service',units[self.layout.firewall])
        uncapped=engine.render_units(self.layout,{**self.config,'poolBytes':None,'diskBytes':None},'/usr/bin/python3')
        self.assertIn('MemoryMax=infinity',uncapped[self.layout.slice])
        self.assertNotIn(self.layout.mount,uncapped); self.assertNotIn('RequiresMountsFor',uncapped[self.layout.service])
    def test_sizes_subnets_and_bounds(self):
        self.assertEqual(engine.normalize_pool('none',16*1024**3),None)
        self.assertEqual(engine.normalize_pool(str(64*1024**3),16*1024**3),16*1024**3,'a pool may not exceed device RAM')
        with self.assertRaises(engine.Failure): engine.normalize_pool(1024,16*1024**3)
        self.assertEqual(engine.normalize_disk(5*1024**3+1,100*1024**3)%(4*1024**2),0)
        with self.assertRaises(engine.Failure): engine.normalize_disk(1024**3,100*1024**3)
        with self.assertRaises(engine.Failure): engine.size_or_none(True,'x')
        self.assertEqual(engine.choose_subnet([cidr(10,237,0,prefix=24),cidr(172,17,prefix=16),cidr(100,83,1,2,prefix=32)]),cidr(10,238,prefix=24))
        self.assertEqual(engine.choose_subnet([cidr(10,237,5,prefix=24)]),cidr(10,237,prefix=24),'only the bridge /24 must be free')
        self.assertEqual(engine.bridge_address(cidr(10,240,prefix=24)),engine.address(10,240,0,1)+'/24')
        # An install that recorded a /16 serves, and filters, only the bridge /24.
        self.assertEqual(engine.bridge_network(cidr(10,240,prefix=16)),cidr(10,240,prefix=24))
        self.assertEqual(engine.bridge_address(cidr(10,240,prefix=16)),engine.address(10,240,0,1)+'/24')
        self.assertIn(cidr(100,64,prefix=10),engine.BLOCKED_IPV4); self.assertEqual(engine.DNS,[engine.address(1,1,1,1),engine.address(8,8,8,8)])

class Requests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); root=Path(self.temp.name)
        self.layout=engine.Layout('wmtest',root); self.host=RecordingHost()
        self.engine=engine.Engine(self.layout,self.host,'/usr/bin/python3')
        self.layout.etc.mkdir(parents=True); self.layout.requests.mkdir(parents=True); self.layout.state_dir.mkdir(parents=True)
        self.engine.save_config({'user':'bots','uid':os.getuid(),'gid':os.getgid(),'group':'bots','subnet':cidr(10,237,prefix=16),'poolBytes':None,'diskBytes':None})
        self.applied=[]
        # Host facts come from /proc and /sys on Linux; fix them for any test host.
        for name,value in (('total_memory',lambda:16*1024**3),):
            patcher=mock.patch.object(engine,name,side_effect=value); patcher.start(); self.addCleanup(patcher.stop)
        self.engine.apply_settings=lambda requested,start=False: self.applied.append(requested) or {'notes':[]}
    def tearDown(self): self.temp.cleanup()
    def request(self,value):
        self.layout.request.write_text(value if isinstance(value,str) else json.dumps(value))
        self.engine.apply_request()
        return json.loads(self.layout.state.read_text())
    def test_valid_requests_apply_once_per_revision(self):
        state=self.request({'revision':'r1','poolBytes':2*1024**3,'diskBytes':None})
        self.assertEqual(state['appliedRevision'],'r1'); self.assertIsNone(state['requestError'])
        self.request({'revision':'r1','poolBytes':4*1024**3,'diskBytes':None})
        self.assertEqual(len(self.applied),1,'a revision applies once')
        self.assertEqual(self.applied[0]['poolBytes'],2*1024**3)
    def test_untrusted_requests_are_rejected(self):
        self.assertEqual(self.request('{not json')['requestError'],'invalid_request')
        self.assertEqual(self.request({'revision':'r2','poolBytes':1,'diskBytes':None,'extra':True})['requestError'],'invalid_request')
        self.assertEqual(self.request({'revision':'bad revision!','poolBytes':None,'diskBytes':None})['requestError'],'invalid_request')
        self.assertEqual(self.request({'revision':'r3','poolBytes':1024,'diskBytes':None})['requestError'],'pool_too_small')
        self.assertEqual(self.applied,[])
        self.layout.request.unlink(); target=Path(self.temp.name)/'secret'; target.write_text('{}')
        self.layout.request.symlink_to(target)
        with self.assertRaises(engine.Failure): self.engine.apply_request()
        self.layout.request.unlink(); self.layout.request.write_text('x'*(engine.REQUEST_LIMIT+1))
        with self.assertRaises(engine.Failure): self.engine.apply_request()
    def test_forwarding_accept_chain_is_idempotent_and_removable(self):
        self.host.codes[('iptables','-w','-S',self.layout.chain)]=1
        self.host.codes[('iptables','-w','-C','FORWARD')]=1
        self.engine.accept_forwarding(self.engine.config())
        joined=[' '.join(call) for call in self.host.calls]
        self.assertIn(f'iptables -w -N {self.layout.chain}',joined)
        self.assertIn(f'iptables -w -I FORWARD 1 -j {self.layout.chain}',joined)
        # The recorded subnet is an older install's /16; the chain accepts only the bridge /24.
        self.assertIn(f'iptables -w -A {self.layout.chain} -i {self.layout.bridge} -s {cidr(10,237,prefix=24)} ! -o {self.layout.bridge} -j ACCEPT',joined)
        self.assertTrue(all(self.layout.bridge in call or 'FORWARD' in call or '-N' in call or '-F' in call or '-S' in call for call in joined))
    def firewall_with(self,forwarding,iptables=True):
        path=Path(self.temp.name)/'ip_forward'; path.write_text(forwarding+'\n'); self.engine.forwarding_path=path
        rendered=[]
        self.engine.host.which=lambda name:('/usr/sbin/'+name) if iptables or name!='iptables' else None
        original=engine.render_ruleset
        with mock.patch.object(engine,'render_ruleset',side_effect=lambda *a,**k: rendered.append(k.get('drop_foreign')) or original(*a,**k)):
            self.engine.firewall()
        return path,rendered,[' '.join(call) for call in self.host.calls]
    def test_forwarding_enabled_by_the_engine_drops_other_forwarding(self):
        path,rendered,calls=self.firewall_with('0')
        self.assertEqual(path.read_text(),'1\n'); self.assertIn('iptables -w -P FORWARD DROP',calls); self.assertEqual(rendered,[False])
        self.assertTrue((self.layout.run/'forwarding-enabled').exists())
        self.assertEqual(json.loads(self.layout.state.read_text())['forwardPolicy'],'iptables')
        # A later reload in the same boot keeps the policy it owns.
        self.host.calls.clear(); path,rendered,calls=self.firewall_with('1')
        self.assertIn('iptables -w -P FORWARD DROP',calls)
    def test_forwarding_that_was_already_on_is_left_to_its_owner(self):
        path,rendered,calls=self.firewall_with('1')
        self.assertFalse(any('-P FORWARD' in call for call in calls),'the user’s Docker or VPN owns the policy')
        self.assertEqual(rendered,[False]); self.assertFalse((self.layout.run/'forwarding-enabled').exists())
        self.assertIsNone(json.loads(self.layout.state.read_text())['forwardPolicy'])
    def test_without_iptables_the_engine_table_drops_other_forwarding(self):
        path,rendered,calls=self.firewall_with('0',iptables=False)
        self.assertEqual(rendered,[True]); self.assertFalse(any(call.startswith('iptables') for call in calls))
        self.assertEqual(json.loads(self.layout.state.read_text())['forwardPolicy'],'nftables')
    def test_commands_and_owner_checks(self):
        with self.assertRaises(engine.Failure): engine.main(['--instance','wmtest','bogus'])
        with self.assertRaises(engine.Failure): engine.main(['--instance','wmtest','install','--user','x'])
        status=self.engine.status()
        self.assertTrue(status['installed']); self.assertEqual(status['socket'],str(self.layout.socket))

if __name__=='__main__': unittest.main()
