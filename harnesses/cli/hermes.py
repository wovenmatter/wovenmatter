"""Bind native Hermes requests and terminal calls without changing model messages."""
import hashlib
import json
from pathlib import Path
import shlex
import uuid


def _key(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _directory(session_id):
    from hermes_constants import get_hermes_home
    return Path(get_hermes_home()) / '.wovenmatter' / 'cli' / _key(session_id)


def _write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with temporary.open('x') as output:
        temporary.chmod(0o600)
        json.dump(value, output)
    temporary.replace(path)


def _read(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {}


def _consume(directory, identity, text):
    saved = directory / 'messages' / (_key(identity) + '.json')
    if saved.exists():
        return _read(saved).get('captureID', '')
    pending = sorted((_read(path) | {'path': path}
                      for path in (directory / 'pending').glob('*.json')), key=lambda item: item['submitted'])
    consumed = []
    # Native steering can coalesce several accepted inputs into one user row.
    for start in range(len(pending)):
        for end in range(start + 1, len(pending) + 1):
            if '\n'.join(item['text'] for item in pending[start:end]) == text:
                consumed = pending[start:end]
                break
        if consumed:
            break
    capture = consumed[-1]['captureID'] if consumed else ''
    for item in consumed:
        item['path'].unlink(missing_ok=True)
    _write(saved, {'captureID': capture})
    return capture


def _identity(message):
    # Merges retain the first UID and record the later constituents.
    return (message.get('_absorbed_message_uids') or [message.get('message_uid')])[-1]


def before_turn(*, session_id='', turn_id='', user_message='', conversation_history=(), **_):
    directory = _directory(session_id)
    if not (directory / 'connection.json').exists():
        return
    from agent.conversation_compression import _message_text, _is_real_user_message
    capture = _consume(directory, 'turn:' + turn_id, _message_text({'content': user_message}))
    # Hermes has already staged this turn's user row. Bind its native identity
    # before other plugins add context or later steering adds another user row.
    for message in reversed(conversation_history):
        if _is_real_user_message(message):
            uid = _identity(message)
            if uid:
                _write(directory / 'messages' / (_key(uid) + '.json'), {'captureID': capture})
            break


def before_request(*, session_id='', turn_id='', api_request_id='', conversation_history=(), **_):
    directory = _directory(session_id)
    if not (directory / 'connection.json').exists():
        return
    from agent.conversation_compression import _is_real_user_message, _extract_steer_text_from_message, _message_text
    capture = ''
    for message in reversed(conversation_history):
        if not isinstance(message, dict):
            continue
        steer = _extract_steer_text_from_message(message) if message.get('role') in ('user', 'tool') else None
        if steer or _is_real_user_message(message):
            uid = _identity(message)
            capture = _consume(directory, uid, steer or _message_text(message)) if uid else ''
            break
    _write(directory / 'requests' / (_key(api_request_id) + '.json'), {'captureID': capture, 'turnID': turn_id})


def before_tool(*, tool_name, args, session_id='', api_request_id='', **_):
    if tool_name != 'terminal' or not isinstance(args.get('command'), str):
        return
    directory = _directory(session_id)
    context = _read(directory / 'connection.json')
    if not context:
        return
    capture = _read(directory / 'requests' / (_key(api_request_id) + '.json')).get('captureID', '')
    values = {'WOVENMATTER_CLI': context['executablePath'], 'WOVENMATTER_CONTEXT_ID': capture}
    if context.get('socketPath'):
        values['WOVENMATTER_SOCKET'] = context['socketPath']
    prefix = 'unset WOVENMATTER_SOCKET WOVENMATTER_NOTE_ID; export ' + ' '.join(
        name + '=' + shlex.quote(value) for name, value in values.items())
    prefix += '; export PATH=' + shlex.quote(str(Path(context['executablePath']).parent)) + ':"$PATH";\n'
    return {'action': 'modify', 'args': {'command': prefix + args['command']}}


def after_turn(*, session_id='', turn_id='', **_):
    for path in (_directory(session_id) / 'requests').glob('*.json'):
        if _read(path).get('turnID') == turn_id:
            path.unlink(missing_ok=True)


def register(ctx):
    ctx.register_hook('pre_llm_call', before_turn)
    ctx.register_hook('pre_api_request', before_request)
    ctx.register_hook('pre_tool_call', before_tool)
    ctx.register_hook('post_llm_call', after_turn)


# Invoked by the authenticated native shell RPC, never by the model.
if __name__ == '__main__':
    import base64
    import sys
    import time
    home, session_id, encoded = sys.argv[1:]
    payload = json.loads(base64.b64decode(encoded))
    directory = Path(home) / '.wovenmatter' / 'cli' / _key(session_id)
    context = payload['context']
    _write(directory / 'connection.json', {'executablePath': context['executablePath'], 'socketPath': context.get('socketPath')})
    if payload.get('resetPending'):
        for path in (directory / 'pending').glob('*.json'):
            path.unlink(missing_ok=True)
    pending = directory / 'pending' / (_key(context['captureID']) + '.json')
    if payload.get('removePending'):
        pending.unlink(missing_ok=True)
    elif payload.get('text') is not None:
        _write(pending, {'text': payload['text'], 'captureID': context['captureID'], 'submitted': time.time_ns()})
    print('ready')
