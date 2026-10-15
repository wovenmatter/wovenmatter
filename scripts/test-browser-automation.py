#!/usr/bin/env python3
"""Opt-in CEF/Playwright compatibility fixture; no user profile or Keychain."""
import http.server
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import threading

spec = importlib.util.spec_from_file_location("password_fixture", pathlib.Path(__file__).with_name("test-browser-passwords.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == "/frame":
            body = b'<!doctype html><label for="frame-name">Frame name</label><input id="frame-name">'
            self.send_response(200); self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path == "/download":
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
            self.send_header("Content-Length", "5"); self.end_headers(); self.wfile.write(b"hello"); return
        body = b'''<!doctype html><title>Automation fixture</title>
          <label for="name">Name</label><input id="name">
          <button id="submit" onclick="document.querySelector('#result').textContent=document.querySelector('#name').value">Submit</button>
          <output id="result"></output><input id="file" type="file"><a id="download" href="/download">Download</a>
          <iframe id="subframe"></iframe><script>document.querySelector('#subframe').src=location.href.replace('127.0.0.1','localhost').split('?')[0]+'frame'</script>'''
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

def main():
    build, source, node, script = map(pathlib.Path, sys.argv[1:])
    name = "Woven Automation Fixture"
    with tempfile.TemporaryDirectory(prefix="wm-automation-fixture-", dir="/private/tmp") as temporary:
        root = pathlib.Path(temporary); app = root / (name + ".app")
        fixture.bundle(app, name, build / "WovenBrowserAutomationTests", "wovenmatter.automation-fixture")
        frameworks = app / "Contents/Frameworks"; frameworks.mkdir()
        framework = "Chromium Embedded Framework.framework"
        subprocess.run(["/bin/cp", "-cR", str(source / "Contents/Frameworks" / framework), str(frameworks / framework)], check=True)
        for suffix in ["", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)"]:
            helper = name + " Helper" + suffix; path = frameworks / (helper + ".app")
            fixture.bundle(path, helper, build / "WovenBrowserHelper", "wovenmatter.automation-fixture.helper" + suffix.strip(" ()").lower())
            subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([str(app / "Contents/MacOS" / name), str(root), f"http://127.0.0.1:{server.server_port}/", str(node), str(script)], check=True, timeout=180)
        finally:
            server.shutdown(); server.server_close()

if __name__ == "__main__": main()
