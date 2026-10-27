#!/usr/bin/env python3
"""Opt-in, provider-free acceptance through a running snapshot's real Woven MCP.

Uses the same authenticated same-user backend surface as the native frontend to
create one disposable chat and a Computer Use-only credential. Never opens the
production database, changes global tool defaults, or grants macOS permissions.
Prepare the disposable target with scripts/test-cua-desktop.sh --target-only.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import struct
import subprocess
import time
import urllib.request
import urllib.error
import uuid


class PermissionRequired(Exception):
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--target-root', type=Path, default=Path('/private/tmp/wovenmatter-cua-desktop'))
    parser.add_argument('--report', type=Path, default=Path('/private/tmp/wovenmatter-cua-snapshot-report.json'))
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    instance = info.get('WovenMatterDevelopmentInstance', '')
    assert info.get('WovenMatterDevelopmentMode') == 'snapshot', 'Only snapshot Dev builds may be tested'
    assert info['CFBundleIdentifier'].startswith('wovenmatter.desktop.dev.'), 'A Dev bundle is required'
    assert instance and len(instance) <= 64 and all(c.isascii() and (c.isalnum() or c == '-') for c in instance)
    support = Path.home() / 'Library/Application Support/Woven Matter Dev' / instance / 'snapshot'
    assert support.resolve() == support and (support / 'development-snapshot.json').is_file()
    digest = hashlib.sha256(str(support).encode()).hexdigest()[:16]
    endpoint = '/private/tmp/wovenmatter-backend-' + str(os.getuid()) + '-' + digest + '/control.sock'
    report = {'status': 'running', 'bundleID': info['CFBundleIdentifier']}
    session_id = str(uuid.uuid4()).lower()
    grant_id = None
    connection = None
    enabled = False
    session_created = False
    target_started = False
    target_file = args.target_root / 'target.json'
    target_app = args.target_root / 'Cua Target.app'

    def save():
        args.report.write_text(json.dumps(report, sort_keys=True) + '\n')
        args.report.chmod(0o600)

    def backend(method, payload=None):
        encoded = base64.b64encode(json.dumps(payload).encode()).decode() if payload is not None else ''
        message = json.dumps(dict(id=str(uuid.uuid4()), method=method, payload=encoded)).encode()
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(30)
            client.connect(endpoint)
            client.sendall(struct.pack('>I', len(message)) + message)

            def read(count):
                result = b''
                while len(result) < count:
                    chunk = client.recv(count - len(result))
                    if not chunk:
                        raise RuntimeError('Snapshot backend closed the connection')
                    result += chunk
                return result

            length = struct.unpack('>I', read(4))[0]
            assert 0 < length <= 8 * 1024 * 1024
            response = json.loads(read(length))
        if response.get('error'):
            raise RuntimeError(response['error'])
        return json.loads(base64.b64decode(response['result']))

    def command(value):
        return backend('application.command', value)

    def enable(value):
        command({'toolsMutation': {'_0': {'setEnabled': dict(group='computer', enabled=value,
                 sessionID=session_id, confirmedPausingTimers=False)}}})

    def call(arguments, error=False):
        request = urllib.request.Request(connection['endpointURL'], data=json.dumps(dict(jsonrpc='2.0',
            id=str(uuid.uuid4()), method='tools/call', params=dict(name='woven_computer_use', arguments=arguments))).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + connection['bearerToken']})
        with urllib.request.urlopen(request, timeout=30) as response:
            envelope = json.load(response)
        result = envelope.get('result', {})
        failed = 'error' in envelope or result.get('isError') is True
        # Retain no screenshots, tokens, or typed user content in the report.
        if failed != error:
            detail = envelope.get('error') or result.get('structuredContent', {}).get('error') or 'Unexpected MCP outcome'
            raise RuntimeError(str(detail))
        return result

    def state():
        return json.loads(target_file.read_text())

    def wait(key, value):
        for _ in range(100):
            if state().get(key) == value:
                return
            time.sleep(0.05)
        raise RuntimeError('Independent target state did not confirm ' + key)

    def token(snapshot, label):
        result = snapshot['structuredContent']['result']['structuredContent']
        return next(row['element_token'] for row in result['elements'] if row.get('label') == label)

    def inline_image(result):
        assert any(item.get('type') == 'image' for item in result['content']), 'Missing inline MCP image'

    def settings():
        with sqlite3.connect('file:' + str(support / 'workspace.sqlite') + '?mode=ro', uri=True) as db:
            return json.loads(db.execute('SELECT value FROM workspace_tool_settings WHERE id=1').fetchone()[0])

    defaults_before = settings()
    save()
    try:
        assert backend('application.readiness')['ready']
        assert 'computer' not in defaults_before['enabledByDefault'], 'Computer Use must start off'
        report['defaultOff'] = True
        command({'createSession': dict(runtime='default_agent', conversationID=session_id, title='Cua acceptance - disposable')})
        session_created = True
        access = command({'mcpAccess': {'_0': {'create': dict(label='Cua snapshot acceptance', sessionID=session_id,
                          groups=['computer'], readOnly=False)}}})['mcpAccess']
        connection = access['issuedConnection']
        grant_id = next(grant['id'] for grant in access['clients'] if grant['sessionID'] == session_id)
        call({'action': 'apps'}, error=True)
        report['defaultOffDeniedAtMCP'] = True
        enable(True)
        enabled = True
        status = call({'action': 'status'})
        permissions = json.loads(status['content'][0]['text'])
        report['permissions'] = permissions
        assert permissions['engine'] == 'cua'
        if not all(permissions.get(key) for key in ('accessibility', 'screenRecording')):
            raise PermissionRequired('Enable Accessibility and Screen Recording for ' + info['CFBundleName'] + ', then reopen it')
        target_info = plistlib.loads((target_app / 'Contents/Info.plist').read_bytes())
        assert target_info['CFBundleIdentifier'] == 'wovenmatter.desktop.dev.cua-verification.target'
        subprocess.run(['swift', str(Path(__file__).resolve().parent / 'stop-development.swift'),
                        str(target_app / 'Contents/MacOS' / target_info['CFBundleExecutable'])], check=True)
        target_file.unlink(missing_ok=True)
        subprocess.run(['open', '-n', str(target_app), '--env', 'WM_CUA_FIXTURE_ROOT=' + str(args.target_root),
                        '--env', 'WM_CUA_FIXTURE_ROLE=target'], check=True)
        target_started = True
        for _ in range(100):
            if target_file.exists():
                break
            time.sleep(0.05)
        target = dict(pid=state()['pid'], windowID=state()['windowID'])
        call({'action': 'apps'})
        call({'action': 'launch', 'app': target_info['CFBundleIdentifier']})
        call({'action': 'windows', 'pid': target['pid']})
        report['discoveryAndLaunch'] = True
        inline_image(call({'action': 'screenshot'}))
        first = call(dict(target, action='snapshot', treeFormat='elements'))
        inline_image(first)
        report['desktopAndWindowInlineImages'] = True
        button = token(first, 'Increment')
        call(dict(target, action='click', elementToken=button))
        wait('count', 1)
        report['accessibilityClick'] = True
        fresh = call(dict(target, action='snapshot', treeFormat='elements'))
        call(dict(target, action='click', elementToken=button), error=True)
        report['staleTokenRejected'] = True
        field = token(fresh, 'Fixture text')
        call(dict(target, action='type', elementToken=field, text='Cua verified'))
        wait('text', 'Cua verified')
        call(dict(target, action='press', elementToken=field, key='cmd+a'))
        wait('selected', 12)
        call(dict(target, action='type', elementToken=field, text='Replacement verified'))
        wait('text', 'Replacement verified')
        report['backgroundTypingAndHotkey'] = True
        enable(False)
        enabled = False
        call(dict(target, action='click', elementToken=button), error=True)
        wait('count', 1)
        report['revocationDeniedAtMCP'] = True
        assert settings() == defaults_before, 'Global defaults changed during acceptance'
        report['globalDefaultsUnchanged'] = True
        report['status'] = 'passed'
    except PermissionRequired as error:
        report.update(status='waiting_for_permissions', error=str(error))
    except Exception as error:
        report.update(status='failed', error=str(error))
    finally:
        try:
            if enabled:
                enable(False)
                call({'action': 'apps'}, error=True)
                report['revocationDeniedAtMCP'] = True
            if grant_id:
                command({'mcpAccess': {'_0': {'revoke': {'_0': grant_id}}}})
                try:
                    call({'action': 'status'})
                except urllib.error.HTTPError as error:
                    assert error.code == 401, 'Revoked credential returned an unexpected status'
                else:
                    raise RuntimeError('Revoked MCP credential was still accepted')
                report['revokedCredentialRejected'] = True
            if session_created:
                command({'workspaceMutation': {'_0': {'conversation': dict(id=session_id, mutation={'moveToTrash': {}})}}})
            if target_started:
                subprocess.run(['swift', str(Path(__file__).resolve().parent / 'stop-development.swift'),
                                str(target_app / 'Contents/MacOS' / target_info['CFBundleExecutable'])], check=True)
            report['testAccessRevoked'] = grant_id is not None
            assert settings() == defaults_before, 'Global defaults changed during acceptance'
            report['globalDefaultsUnchanged'] = True
        except Exception as error:
            report.update(status='failed', cleanupError=str(error))
        save()
    print(json.dumps(report, sort_keys=True))
    return {'passed': 0, 'waiting_for_permissions': 77}.get(report['status'], 1)


if __name__ == '__main__':
    raise SystemExit(main())
