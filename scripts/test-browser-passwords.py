#!/usr/bin/env python3
"""Opt-in real-CEF password fixture; synthetic credentials and no real Keychain.

Usage: test-browser-passwords.py CEF_CMAKE_BUILD BUILT_APP
The built app supplies a framework copy. The fixture has its own helper,
mock encryption key, disposable profile, hidden window and loopback form server.
"""
import http.server
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading


class Forms(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/guards":
            self.respond(f'''<!doctype html><title>Guards</title>
              <form><input name="username"><input type="password" autocomplete="new-password"></form>
              <form action="http://localhost:{self.server.server_port}/done">
              <input name="username"><input type="password"></form>
              <iframe src="/frame"></iframe>'''.encode())
            return
        self.respond(b'''<!doctype html><title>Fixture</title>
          <form method="post" action="/done">
          <input name="username" autocomplete="username">
          <input name="password" type="password" autocomplete="current-password">
          <button>Submit synthetic form</button></form>''')

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.respond(b"<!doctype html><title>Done</title>Fixture submitted.")

    def respond(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def bundle(path, name, binary, identifier):
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy2(binary, contents / "MacOS" / name)
    with (contents / "Info.plist").open("wb") as out:
        plistlib.dump(dict(CFBundleExecutable=name, CFBundleName=name,
                          CFBundleIdentifier=identifier, CFBundlePackageType="APPL",
                          CFBundleVersion="1", LSUIElement=True,
                          NSHighResolutionCapable=True), out)


def main():
    build, source = map(pathlib.Path, sys.argv[1:])
    name = "Woven Password Fixture"
    # TemporaryDirectory is always under /private/tmp and never a user profile.
    with tempfile.TemporaryDirectory(prefix="wm-password-fixture-", dir="/private/tmp") as root:
        root = pathlib.Path(root)
        app = root / (name + ".app")
        bundle(app, name, build / "WovenBrowserPasswordTests", "wovenmatter.password-fixture")
        frameworks = app / "Contents" / "Frameworks"
        frameworks.mkdir()
        framework_name = "Chromium Embedded Framework.framework"
        # CEF's sandbox requires the framework inside this app; an external
        # symlink is intentionally refused. APFS clones keep the copy inexpensive.
        subprocess.run(["/bin/cp", "-cR", str(source / "Contents" / "Frameworks" / framework_name),
                        str(frameworks / framework_name)], check=True)
        for suffix in ["", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)"]:
            helper = name + " Helper" + suffix
            path = frameworks / (helper + ".app")
            bundle(path, helper, build / "WovenBrowserHelper", "wovenmatter.password-fixture.helper" + suffix.strip(" ()").lower())
            # No hardened runtime/library validation in this disposable test app.
            subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Forms)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for phase in ["initial", "restart"]:
                subprocess.run([str(app / "Contents" / "MacOS" / name), str(root),
                                f"http://127.0.0.1:{server.server_port}/", phase],
                               check=True, timeout=60)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
