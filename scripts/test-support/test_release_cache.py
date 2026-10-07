"""Exercise pinned CEF archive reuse without downloads, compilation, or signing."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "scripts/prepare-browser.sh").read_text()
# Run the real download/verify/extract phase only; no CMake build or app launch.
source = source[:source.index('\nsdk="$cache/$name"')]
with tempfile.TemporaryDirectory(prefix="wovenmatter-cef-cache-") as folder:
    temp = Path(folder)
    (temp / "scripts").mkdir()
    (temp / "app/Browser").mkdir(parents=True)
    sdk = temp / "cef_binary_fixture_macosarm64_minimal"
    sdk.mkdir()
    (sdk / "fixture").write_text("pinned SDK")
    archive = temp / "source.tar.bz2"
    subprocess.run(["tar", "-cjf", str(archive), "-C", str(temp), sdk.name], check=True)
    pin = dict(version="fixture", archives=dict(arm64=dict(platform="macosarm64", sha1=hashlib.sha1(archive.read_bytes()).hexdigest())))
    (temp / "app/Browser/cef-version.json").write_text(json.dumps(pin))
    script = temp / "scripts/prepare-browser.sh"
    script.write_text(source)
    tools = temp / "tools"
    tools.mkdir()
    curl = tools / "curl"
    curl.write_text('#!/bin/bash\nprintf "download\\n" >> "$CEF_TEST_CALLS"\nwhile [ "$1" != -o ]; do shift; done\ncp "$CEF_TEST_ARCHIVE" "$2"\n')
    curl.chmod(0o755)
    calls = temp / "calls"
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], ARCHS="arm64",
               WOVENMATTER_CMAKE="/usr/bin/true", CEF_TEST_CALLS=str(calls), CEF_TEST_ARCHIVE=str(archive))
    cache = temp / "cache"
    env['WOVENMATTER_CEF_CACHE_DIR'] = str(cache)
    def run(success):
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result
        return result
    run(True)
    cached_archive = cache / "archives" / (sdk.name + ".tar.bz2")
    assert cached_archive.read_bytes() == archive.read_bytes()
    assert (cache / sdk.name / ".verified").exists()
    # A fresh hosted runner restores only the archive, not an extracted marker.
    restored = temp / "restored"
    (restored / "archives").mkdir(parents=True)
    restored_archive = restored / "archives" / cached_archive.name
    restored_archive.write_bytes(cached_archive.read_bytes())
    env['WOVENMATTER_CEF_CACHE_DIR'] = str(restored)
    run(True)
    assert calls.read_text().splitlines() == ["download"]
    # Cache poisoning/corruption cannot bypass the repository checksum pin.
    corrupt = temp / "corrupt"
    (corrupt / "archives").mkdir(parents=True)
    (corrupt / "archives" / cached_archive.name).write_bytes(b"corrupt")
    env['WOVENMATTER_CEF_CACHE_DIR'] = str(corrupt)
    assert "checksum mismatch" in run(False).stderr
    assert not (corrupt / sdk.name / ".verified").exists()
print("Release CEF cache checks passed: cold download, archive-only restore, checksum rejection.")
