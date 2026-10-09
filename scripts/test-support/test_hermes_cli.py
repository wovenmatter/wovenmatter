import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('woven_hermes', Path(__file__).resolve().parents[2] / 'harnesses/cli/hermes.py')
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class HermesBindingTests(unittest.TestCase):
    def test_native_user_identity_advances_only_when_steering_is_consumed(self):
        # The native hooks receive history with stable message_uid values.
        compression = types.ModuleType('agent.conversation_compression')
        compression._message_text = lambda row: row.get('content', '')
        compression._is_real_user_message = lambda row: row.get('role') == 'user'
        compression._extract_steer_text_from_message = lambda row: None
        with tempfile.TemporaryDirectory() as temporary, patch.dict(sys.modules, {
            'agent': types.ModuleType('agent'), 'agent.conversation_compression': compression,
        }), patch.object(plugin, '_directory', return_value=Path(temporary)):
            directory = Path(temporary)
            plugin._write(directory / 'connection.json', {'executablePath': '/tmp/wovenmatter', 'socketPath': '/tmp/session.sock'})
            def stage(capture, text, order):
                plugin._write(directory / 'pending' / (capture + '.json'), {'captureID': capture, 'text': text, 'submitted': order})
            first = {'role': 'user', 'content': 'first', 'message_uid': 'user-a'}
            stage('a', 'first', 1)
            plugin.before_turn(session_id='s', turn_id='t', user_message='first', conversation_history=[first])
            first['content'] += ' native context'
            stage('b', 'second', 2)
            plugin.before_request(session_id='s', turn_id='t', api_request_id='request-a', conversation_history=[first])
            second = {'role': 'user', 'content': 'second', 'message_uid': 'user-b'}
            plugin.before_request(session_id='s', turn_id='t', api_request_id='request-b', conversation_history=[first, second])
            def command(request):
                return plugin.before_tool(tool_name='terminal', args={'command': 'wovenmatter context'}, session_id='s', api_request_id=request)['args']['command']
            self.assertIn('WOVENMATTER_CONTEXT_ID=a', command('request-a'))
            self.assertIn('WOVENMATTER_CONTEXT_ID=b', command('request-b'))
            # Plugin reloads and retries reuse persisted native identities.
            plugin.before_request(session_id='s', turn_id='t', api_request_id='retry', conversation_history=[first, second])
            self.assertIn('WOVENMATTER_CONTEXT_ID=b', command('retry'))
            plugin.after_turn(session_id='s', turn_id='t')
            self.assertEqual(list((directory / 'requests').glob('*.json')), [])


if __name__ == '__main__':
    unittest.main()
