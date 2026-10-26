"""Image freshness, forced refresh, and build failures without a Docker daemon."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'remote/build-image.sh'
DIGEST = 'a' * 64
IMAGE = 'sha256:' + 'b' * 64

class RemoteImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        mock = self.root / 'docker'
        mock.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:]
if args[0]=='info':
 if '--format' in args: print('x86_64')
elif args[:2]==['image','inspect']:
 record=os.environ.get('RECORD')
 if not record: sys.exit(1)
 print(record)
elif args[0]=='build':
 Path(os.environ['BUILD_ARGS']).write_text(' '.join(args))
 sys.stdin.buffer.read()
 if os.environ.get('FAIL_BUILD'): sys.exit(42)
 Path(args[args.index('--iidfile')+1]).write_text(os.environ['IMAGE'])
else: sys.exit(99)
''')
        mock.chmod(0o755)
        lock = self.root / 'flock'
        lock.write_text('#!/usr/bin/env python3\nimport fcntl,sys\nfcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)\n')
        lock.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'], XDG_RUNTIME_DIR=str(self.root), IMAGE=IMAGE, BUILD_ARGS=str(self.root/'build-args'))
    def record(self, digest=DIGEST, age=0, arch='amd64'):
        self.env['RECORD'] = f'{IMAGE}|{digest}|{int(time.time())-age}|linux|{arch}'
    def run_script(self, action='inspect', force=False):
        return subprocess.run(['bash',str(SCRIPT),action,DIGEST,str(force).lower()],env=self.env,input=b'archive',capture_output=True)
    def test_freshness_requires_content_age_and_architecture(self):
        self.assertEqual(self.run_script().stdout,b'build\n')
        for options in [dict(digest='c'*64),dict(age=86401),dict(age=-600),dict(arch='arm64')]:
            self.record(**options)
            self.assertEqual(self.run_script().stdout,b'build\n')
        self.record()
        self.assertEqual(self.run_script().stdout.decode().strip(),IMAGE)
        self.assertFalse((self.root/'build-args').exists())
    def test_build_rechecks_under_lock_and_force_bypasses_reuse(self):
        self.record()
        result=self.run_script('build')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(b'WM_PROGRESS reused',result.stderr)
        self.assertFalse((self.root/'build-args').exists())
        result=self.run_script('build',True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.decode().strip(),IMAGE)
        args=(self.root/'build-args').read_text()
        for flag in ['--pull','--no-cache','--progress=plain','--iidfile','com.wovenmatter.bundle-sha256='+DIGEST]: self.assertIn(flag,args)
    def test_failure_never_returns_old_image_or_ready(self):
        self.record()
        self.env['FAIL_BUILD']='1'
        result=self.run_script('build',True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,b'')
        self.assertNotIn(b'WM_PROGRESS ready',result.stderr)
        self.assertEqual(self.run_script().stdout.decode().strip(),IMAGE)
        self.assertEqual(list(self.root.rglob('image-id.*')),[])

if __name__ == '__main__': unittest.main()
