"""Exercise the real CEF build phase without downloads or signing credentials."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PIN = json.loads((ROOT / "app/Browser/cef-version.json").read_text())


class BrowserBuildTests(unittest.TestCase):
    def test_clean_build_directories_and_helper_signing(self):
        with tempfile.TemporaryDirectory(prefix="woven browser build ") as temporary:
            root = Path(temporary)
            binaries = root / "bin"
            binaries.mkdir()
            stub = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['BROWSER_BUILD_CALLS'], 'a') as log:
    log.write(json.dumps([name, args]) + '\n')
if name == 'cmake':
    if '--build' in args:
        build = Path(args[args.index('--build') + 1])
        (build / 'libcef_dll_wrapper').mkdir(parents=True, exist_ok=True)
        for file in ('libWovenBrowser.a', 'libcef_dll_wrapper/libcef_dll_wrapper.a', 'WovenBrowserHelper'):
            (build / file).write_text('fixture')
    else:
        Path(args[args.index('-B') + 1]).mkdir(parents=True)
elif name == 'curl':
    sys.exit('Unexpected download in cached build test')
'''
            for name in ("cmake", "codesign", "curl"):
                executable = binaries / name
                executable.write_text(stub)
                executable.chmod(0o755)

            for arch, signed in (("arm64", False), ("x86_64", True)):
                with self.subTest(arch=arch):
                    cache = root / "cache"
                    archive = PIN["archives"][arch]["platform"]
                    sdk = cache / f'cef_binary_{PIN["version"]}_{archive}_minimal'
                    framework = sdk / "Release/Chromium Embedded Framework.framework"
                    (framework / "Libraries").mkdir(parents=True)
                    (sdk / ".verified").touch()
                    (framework / "Libraries/libcef_sandbox.dylib").write_text("fixture")
                    for name in ("LICENSE.txt", "CREDITS.html"):
                        (sdk / name).write_text(name)
                    output = root / arch
                    calls = root / f"{arch}.jsonl"
                    env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                               WOVENMATTER_CMAKE=str(binaries / "cmake"), ARCHS=arch,
                               WOVENMATTER_CEF_CACHE_DIR=str(cache),
                               DERIVED_FILE_DIR=str(output / "Derived Sources"),
                               BUILT_PRODUCTS_DIR=str(output / "Products"), TARGET_BUILD_DIR=str(output),
                               WRAPPER_NAME="Fixture Dev.app", PRODUCT_NAME="Fixture Dev",
                               PRODUCT_BUNDLE_IDENTIFIER="wovenmatter.desktop.dev.fixture",
                               CONFIGURATION="Release" if signed else "Debug",
                               CODE_SIGNING_ALLOWED="YES" if signed else "NO",
                               EXPANDED_CODE_SIGN_IDENTITY="fixture-certificate",
                               BROWSER_BUILD_CALLS=str(calls))
                    result = subprocess.run(["bash", str(ROOT / "scripts/prepare-browser.sh")],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((output / "Derived Sources" / f"cef-{arch}-config.log").exists())
                    self.assertTrue((output / "Products/libWovenBrowser.a").exists())
                    contents = output / "Fixture Dev.app/Contents"
                    for suffix in ("", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)"):
                        helper = contents / "Frameworks" / f"Fixture Dev Helper{suffix}.app/Contents"
                        with (helper / "Info.plist").open("rb") as file:
                            info = plistlib.load(file)
                        self.assertEqual(info["CFBundleExecutable"], f"Fixture Dev Helper{suffix}")
                        self.assertTrue((helper / "MacOS" / info["CFBundleExecutable"]).exists())
                    commands = [json.loads(line) for line in calls.read_text().splitlines()]
                    self.assertFalse(any(name == "curl" for name, _ in commands))
                    signing = [args for name, args in commands if name == "codesign"]
                    self.assertEqual(len(signing), 7)  # library, framework, five helpers
                    for args in signing:
                        self.assertEqual(args[args.index("--sign") + 1], "fixture-certificate" if signed else "-")
                        self.assertIn("--timestamp" if signed else "--timestamp=none", args)
                    self.assertTrue(signing[0][-1].endswith("libcef_sandbox.dylib"))


if __name__ == "__main__":
    unittest.main()
