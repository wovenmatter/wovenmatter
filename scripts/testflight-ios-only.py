#!/usr/bin/env python3
"""Keeps every TestFlight group of the Woven Matter iOS app to iPhone and iPad.

App Store Connect offers iOS builds to testers on Apple silicon Macs and Apple
Vision Pro unless each beta group turns that off, and new groups start with it
on. This turns both off for every group of com.wovenmatter.wovenmatter.

Run through `scripts/prepare-ios-testflight.sh --ios-only-groups`, which also
runs it after every upload. Authenticates only with the App Store Connect API
key in ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH; the key and the signed token
are never printed. Changes nothing but those two settings on beta groups.

The App Store's own Mac and Vision Pro checkboxes (Pricing and Availability) are
not in Apple's API; ios/README.md lists them.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = 'com.wovenmatter.wovenmatter'
API = 'https://api.appstoreconnect.apple.com'
SETTINGS = ('iosBuildsAvailableForAppleSiliconMac', 'iosBuildsAvailableForAppleVision')


class Failure(Exception):
    pass


def api_base():
    # Tests point this at a local fake; the signed token never goes anywhere else.
    base = os.environ.get('ASC_API_BASE', API).rstrip('/')
    host = urllib.parse.urlsplit(base).hostname
    if base != API and not (base.startswith('http://') and host in ('127.0.0.1', 'localhost')):
        raise Failure('ASC_API_BASE may only point at a local test server.')
    return base


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def der_signature_to_raw(der):
    """openssl writes ECDSA signatures as DER; JWT ES256 wants raw r || s."""
    if len(der) < 8 or der[0] != 0x30:
        raise Failure('openssl returned an unexpected signature.')
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    raw = b''
    for _ in range(2):
        if der[index] != 0x02:
            raise Failure('openssl returned an unexpected signature.')
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b'\x00')
        if len(value) > 32:
            raise Failure('openssl returned an unexpected signature.')
        raw += value.rjust(32, b'\x00')
        index += 2 + length
    return raw


def token(key_id, issuer_id, key_path):
    header = b64(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}, separators=(',', ':')).encode())
    now = int(time.time())
    claims = b64(json.dumps({'iss': issuer_id, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
                            separators=(',', ':')).encode())
    signing_input = f'{header}.{claims}'
    result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key_path], input=signing_input.encode(),
                            capture_output=True)
    if result.returncode != 0:
        raise Failure('openssl could not sign with the App Store Connect API key.')
    return f'{signing_input}.{b64(der_signature_to_raw(result.stdout))}'


class Client:
    def __init__(self, bearer):
        self.base = api_base()
        self.bearer = bearer

    def request(self, method, path, body=None):
        url = path if path.startswith(self.base) else self.base + path
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            'Authorization': 'Bearer ' + self.bearer, 'Content-Type': 'application/json', 'Accept': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            raise Failure(f'App Store Connect answered {method} {urllib.parse.urlsplit(url).path} with '
                          f'HTTP {error.code}: {apple_error(error.read())}') from None
        except urllib.error.URLError as error:
            raise Failure(f'Could not reach App Store Connect: {error.reason}') from None
        try:
            return json.loads(payload) if payload else {}
        except ValueError:
            raise Failure(f'App Store Connect returned something other than JSON for {method} {path}.') from None


def apple_error(payload):
    try:
        errors = json.loads(payload).get('errors') or []
        details = [e.get('detail') or e.get('title') for e in errors if isinstance(e, dict)]
        return '; '.join(d for d in details if d) or 'no details'
    except (ValueError, AttributeError):
        return 'no details'


def app_id(client):
    query = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID, 'fields[apps]': 'bundleId', 'limit': '200'})
    apps = [a for a in client.request('GET', '/v1/apps?' + query).get('data') or []
            if (a.get('attributes') or {}).get('bundleId') == BUNDLE_ID]
    if len(apps) != 1:
        raise Failure(f'Expected one App Store Connect app for {BUNDLE_ID}, found {len(apps)}.')
    return apps[0]['id']


def beta_groups(client, app):
    query = urllib.parse.urlencode({'fields[betaGroups]': 'name,' + ','.join(SETTINGS), 'limit': '200'})
    path, groups = f'/v1/apps/{app}/betaGroups?{query}', []
    while path:
        page = client.request('GET', path)
        groups += page.get('data') or []
        path = (page.get('links') or {}).get('next')
        if path and not path.startswith(client.base + '/'):
            raise Failure('App Store Connect returned a next page on another host.')
    return groups


def main():
    key_id, issuer_id, key_path = (os.environ.get(name, '') for name in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'))
    if not (key_id and issuer_id and key_path):
        raise Failure('Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH; '
                      'scripts/prepare-ios-testflight.sh --ios-only-groups does this from the saved key.')
    client = Client(token(key_id, issuer_id, key_path))
    groups = beta_groups(client, app_id(client))
    if not groups:
        print('No TestFlight groups yet. Run scripts/prepare-ios-testflight.sh --ios-only-groups after creating one.')
        return
    for group in groups:
        name = (group.get('attributes') or {}).get('name') or group['id']
        if all((group.get('attributes') or {}).get(setting) is False for setting in SETTINGS):
            print(f'TestFlight group "{name}": iPhone and iPad only.')
            continue
        updated = client.request('PATCH', f'/v1/betaGroups/{group["id"]}', {'data': {
            'type': 'betaGroups', 'id': group['id'], 'attributes': {setting: False for setting in SETTINGS}}})
        attributes = (updated.get('data') or {}).get('attributes') or {}
        if any(attributes.get(setting) is not False for setting in SETTINGS):
            raise Failure(f'TestFlight group "{name}" still offers builds on Macs or Apple Vision Pro after the change.')
        print(f'TestFlight group "{name}": turned off testing on Macs and Apple Vision Pro; iPhone and iPad only.')


if __name__ == '__main__':
    try:
        main()
    except Failure as failure:
        print(f'TestFlight groups not updated: {failure}', file=sys.stderr)
        sys.exit(1)
