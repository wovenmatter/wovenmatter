"""Cache integrity and invalidation tests, without credentials or upstream access."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

downloads = load('downloads', 'cached-download.py')
browser = load('browser', 'browser-build-cache.py')
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    archive = b'locked upstream archive'
    expected = hashlib.sha256(archive).hexdigest()
    calls = []
    def fetch(command, **kwargs):
        calls.append(command)
        Path(command[-1]).write_bytes(archive)
    with patch.object(downloads.subprocess, 'run', side_effect=fetch):
        path = downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads')
        assert len(calls) == 1
        assert downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads') == path
        assert len(calls) == 1
        path.write_bytes(b'corrupt restore')
        downloads.download('https://example.invalid/archive', 'sha256', expected, root / 'downloads')
        assert len(calls) == 2 and path.read_bytes() == archive
        try:
            downloads.download('https://example.invalid/archive', 'sha256', '0' * 64, root / 'downloads')
            raise AssertionError('Unpinned download accepted')
        except ValueError:
            pass
        assert not list((root / 'downloads').glob('.download-*'))
    build, cache, restored = root / 'build', root / 'browser', root / 'restored'
    for name in browser.PRODUCTS:
        path = build / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(name.encode())
        path.chmod(0o755)
    assert browser.transfer('save', cache, build)
    assert not cache.exists(), 'A release consumer must not write the shared cache'
    with patch.dict(os.environ, WOVENMATTER_WRITE_BROWSER_CACHE='1'):
        assert browser.transfer('save', cache, build)
    assert browser.transfer('restore', cache, restored)
    assert (restored / 'WovenBrowserHelper').stat().st_mode == (build / 'WovenBrowserHelper').stat().st_mode
    (cache / 'WovenBrowserHelper').write_bytes(b'corrupt')
    assert not browser.transfer('restore', cache, root / 'bad')
    assert not (root / 'bad').exists()
    source = root / 'source'
    (source / 'app/Browser').mkdir(parents=True)
    (source / 'scripts').mkdir()
    (source / 'app/Browser/Helper.cc').write_text('first')
    for name in ('prepare-browser.sh', 'browser-build-cache.py'):
        (source / 'scripts' / name).write_text('script')
    with patch.object(browser, 'ROOT', source), patch.object(browser.subprocess, 'check_output', return_value=b'toolchain 1'):
        original = browser.key('arm64', 'cmake')
        assert browser.key('x86_64', 'cmake') != original
        with patch.dict(os.environ, CXXFLAGS='-DCHANGED'):
            assert browser.key('arm64', 'cmake') != original
        (source / 'app/Browser/Helper.cc').write_text('second')
        assert browser.key('arm64', 'cmake') != original
print('Release cache: verified hits, corruption recovery, pin rejection, read-only consumer, source/architecture/flags invalidation passed.')
