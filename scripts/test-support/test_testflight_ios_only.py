"""TestFlight groups must end up offering builds only on iPhone and iPad.

Runs scripts/testflight-ios-only.py, directly and through
`prepare-ios-testflight.sh --ios-only-groups`, against a local fake of the App
Store Connect API with a throwaway P-256 key. Nothing reaches Apple. Checks the
signed token, paging, which groups are changed and how, and that failures stop
with Apple's reason and never print the token or key.
"""
import base64
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/testflight-ios-only.py'
WRAPPER = ROOT / 'scripts/prepare-ios-testflight.sh'
KEY_ID, ISSUER = 'ABCDE12345', '57246542-96fe-1a63-e053-0824d011072a'
SETTINGS = ('iosBuildsAvailableForAppleSiliconMac', 'iosBuildsAvailableForAppleVision')


def fail(message):
    raise SystemExit('FAIL: ' + message)


def unb64(text):
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


def raw_to_der(raw):
    def integer(value):
        value = value.lstrip(b'\x00') or b'\x00'
        if value[0] & 0x80:
            value = b'\x00' + value
        return b'\x02' + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b'\x30' + bytes([len(body)]) + body


class FakeAppStoreConnect:
    def __init__(self, work, public_key):
        self.work, self.public_key = work, public_key
        self.groups = {}
        self.patches, self.tokens = [], []
        self.apps = [{'type': 'apps', 'id': '6833596785', 'attributes': {'bundleId': 'com.wovenmatter.wovenmatter'}}]
        self.patch_status, self.ignore_patch = 200, False
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def authorized(self):
                header = self.headers.get('Authorization', '')
                if not header.startswith('Bearer ') or not fake.valid_token(header[7:]):
                    self.reply(401, {'errors': [{'detail': 'bad token'}]})
                    return False
                return True

            def do_GET(self):
                if not self.authorized():
                    return
                url = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(url.query)
                if url.path == '/v1/apps':
                    if query.get('filter[bundleId]') != ['com.wovenmatter.wovenmatter']:
                        return self.reply(400, {'errors': [{'detail': 'wrong filter'}]})
                    return self.reply(200, {'data': fake.apps})
                if url.path == '/v1/apps/6833596785/betaGroups':
                    fields = set(query.get('fields[betaGroups]', [''])[0].split(','))
                    if not set(SETTINGS) <= fields:
                        return self.reply(400, {'errors': [{'detail': 'settings not requested'}]})
                    ids = sorted(fake.groups)
                    page = int(query.get('page', ['0'])[0])
                    body = {'data': [fake.group(i) for i in ids[page * 2:page * 2 + 2]], 'links': {}}
                    if page * 2 + 2 < len(ids):
                        next_query = dict((k, v[0]) for k, v in query.items())
                        next_query['page'] = str(page + 1)
                        body['links']['next'] = f'{fake.base}{url.path}?{urllib.parse.urlencode(next_query)}'
                    return self.reply(200, body)
                self.reply(404, {'errors': [{'detail': 'not found ' + url.path}]})

            def do_PATCH(self):
                if not self.authorized():
                    return
                group_id = self.path.rsplit('/', 1)[-1]
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                fake.patches.append((self.path, body))
                if fake.patch_status != 200:
                    return self.reply(fake.patch_status, {'errors': [{'detail': 'The API key lacks the App Manager role.'}]})
                if not fake.ignore_patch:
                    fake.groups[group_id].update(body['data']['attributes'])
                self.reply(200, {'data': fake.group(group_id)})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.base = f'http://127.0.0.1:{self.server.server_address[1]}'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def group(self, group_id):
        return {'type': 'betaGroups', 'id': group_id, 'attributes': dict(self.groups[group_id])}

    def valid_token(self, token):
        self.tokens.append(token)
        try:
            header_b64, claims_b64, signature_b64 = token.split('.')
            header, claims = json.loads(unb64(header_b64)), json.loads(unb64(claims_b64))
            signature = unb64(signature_b64)
        except ValueError:
            return False
        now = time.time()
        if header != {'alg': 'ES256', 'kid': KEY_ID, 'typ': 'JWT'} or len(signature) != 64:
            return False
        if claims.get('iss') != ISSUER or claims.get('aud') != 'appstoreconnect-v1':
            return False
        if not (now - 60 <= claims['iat'] <= now + 5 and 0 < claims['exp'] - claims['iat'] <= 1200):
            return False
        sig_file = self.work / 'signature.der'
        sig_file.write_bytes(raw_to_der(signature))
        verified = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(self.public_key), '-signature', str(sig_file)],
                                  input=f'{header_b64}.{claims_b64}'.encode(), capture_output=True)
        return verified.returncode == 0


def main():
    with tempfile.TemporaryDirectory() as temporary:
        work = pathlib.Path(temporary)
        key, public_key = work / f'AuthKey_{KEY_ID}.p8', work / 'public.pem'
        generated = subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout'], capture_output=True, check=True)
        key.write_bytes(subprocess.run(['openssl', 'pkcs8', '-topk8', '-nocrypt'], input=generated.stdout,
                                       capture_output=True, check=True).stdout)
        subprocess.run(['openssl', 'ec', '-in', str(key), '-pubout', '-out', str(public_key)], capture_output=True, check=True)
        key_text = key.read_text()
        fake = FakeAppStoreConnect(work, public_key)
        env = {'PATH': f'{pathlib.Path(sys.executable).parent}:/usr/bin:/bin', 'HOME': str(work / 'home'), 'LC_ALL': 'C',
               'ASC_KEY_ID': KEY_ID, 'ASC_ISSUER_ID': ISSUER, 'ASC_KEY_PATH': str(key), 'ASC_API_BASE': fake.base}

        def run(command, extra=None):
            result = subprocess.run(command, capture_output=True, text=True, env={**env, **(extra or {})})
            output = result.stdout + result.stderr
            if any(token in output for token in fake.tokens) or 'PRIVATE KEY' in output or key_text.strip() in output:
                fail('the token or private key was printed')
            return result

        direct = [sys.executable, '-I', str(HELPER)]
        wrapper = ['bash', str(WRAPPER), '--ios-only-groups']

        # No groups yet: nothing to change.
        result = run(direct)
        if result.returncode != 0 or 'No TestFlight groups yet' not in result.stdout or fake.patches:
            fail('with no groups the helper should change nothing: ' + result.stdout + result.stderr)

        # Five groups across three pages: only the ones that offer Macs or Vision Pro change, and both settings go off.
        fake.groups = {
            'a-org': {'name': 'org', SETTINGS[0]: True, SETTINGS[1]: True},
            'b-done': {'name': 'Already iOS', SETTINGS[0]: False, SETTINGS[1]: False},
            'c-vision': {'name': 'Vision only', SETTINGS[0]: False, SETTINGS[1]: True},
            'd-mac': {'name': 'Mac only', SETTINGS[0]: True, SETTINGS[1]: False},
            'e-unknown': {'name': 'Missing settings'},
        }
        result = run(wrapper)
        if result.returncode != 0:
            fail('--ios-only-groups failed: ' + result.stdout + result.stderr)
        changed = sorted(path.rsplit('/', 1)[-1] for path, _ in fake.patches)
        if changed != ['a-org', 'c-vision', 'd-mac', 'e-unknown']:
            fail(f'expected only groups offering Macs or Vision Pro to change, changed {changed}')
        for path, body in fake.patches:
            group_id = path.rsplit('/', 1)[-1]
            if body != {'data': {'type': 'betaGroups', 'id': group_id, 'attributes': {SETTINGS[0]: False, SETTINGS[1]: False}}}:
                fail(f'unexpected change for {group_id}: {body}')
        if any(group.get(setting) is not False for group in fake.groups.values() for setting in SETTINGS):
            fail('a group still offers builds on Macs or Vision Pro')
        if 'TestFlight group "Already iOS": iPhone and iPad only.' not in result.stdout or result.stdout.count('turned off') != 4:
            fail('the summary should name every group and what changed: ' + result.stdout)

        # Running again changes nothing.
        fake.patches.clear()
        result = run(direct)
        if result.returncode != 0 or fake.patches:
            fail('a second run should change nothing')

        # Apple refuses the change: stop with its reason.
        fake.groups['a-org'].update({SETTINGS[0]: True})
        fake.patch_status = 403
        result = run(wrapper)
        if result.returncode == 0 or 'HTTP 403' not in result.stderr or 'App Manager role' not in result.stderr:
            fail('a refused change must fail with Apple\'s reason: ' + result.stdout + result.stderr)

        # Apple accepts but the group still offers Macs: fail rather than report success.
        fake.patch_status, fake.ignore_patch = 200, True
        result = run(direct)
        if result.returncode == 0 or 'still offers builds' not in result.stderr:
            fail('an unchanged group must fail: ' + result.stdout + result.stderr)
        fake.ignore_patch = False

        # The wrong app, or none, is never touched.
        fake.apps = [{'type': 'apps', 'id': '1', 'attributes': {'bundleId': 'com.wovenmatter.wovenmatter.dev'}}]
        fake.patches.clear()
        result = run(direct)
        if result.returncode == 0 or 'found 0' not in result.stderr or fake.patches:
            fail('a missing app must fail without changes: ' + result.stdout + result.stderr)

        # The token only goes to Apple or a local test server; the key is required.
        for base in ('https://example.com', 'http://api.invalid:8080', 'http://127.0.0.1.invalid'):
            result = run(direct, {'ASC_API_BASE': base})
            if result.returncode == 0 or 'local test server' not in result.stderr:
                fail(f'ASC_API_BASE={base} must be refused')
        result = run(direct, {'ASC_KEY_PATH': ''})
        if result.returncode == 0 or 'ASC_KEY_PATH' not in result.stderr:
            fail('a missing key must be refused')
        result = run(wrapper, {'ASC_KEY_ID': '', 'ASC_ISSUER_ID': '', 'ASC_KEY_PATH': '', 'ASC_CONFIG': str(work / 'missing.env')})
        if result.returncode != 69 or 'API key: not configured' not in result.stderr:
            fail('--ios-only-groups without a key must refuse like --upload: ' + result.stdout + result.stderr)
        result = run(wrapper + ['extra'])
        if result.returncode != 64:
            fail('--ios-only-groups takes no arguments')
        fake.server.shutdown()
    print('TestFlight iPhone-and-iPad-only helper passed: signed token, paging, selective changes and failures checked '
          'against a local fake; nothing reached Apple.')


if __name__ == '__main__':
    main()
