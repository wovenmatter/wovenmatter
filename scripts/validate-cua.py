#!/usr/bin/env python3
"""Verify the packaged driver's actual metadata contract without desktop access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

FIELDS = {
    'list_apps': set(), 'list_windows': {'pid'}, 'launch_app': {'bundle_id'},
    'get_window_state': {'pid', 'window_id', 'max_dimension', 'max_image_dimension', 'max_elements',
                         'max_depth', 'timeout_ms', 'query', 'since', 'include_screenshot', 'tree_format'},
    'get_desktop_state': {'max_image_dimension'},
    'click': {'target', 'delivery_mode', 'element_token', 'x', 'y', 'capture_id', 'button', 'count'},
    'type_text': {'target', 'delivery_mode', 'element_token', 'x', 'y', 'text'},
    'press_key': {'target', 'delivery_mode', 'element_token', 'x', 'y', 'key'},
    'hotkey': {'target', 'delivery_mode', 'element_token', 'x', 'y', 'keys'},
    'scroll': {'target', 'delivery_mode', 'x', 'y', 'direction', 'amount'},
    'drag': {'target', 'delivery_mode', 'from_x', 'from_y', 'to_x', 'to_y'},
    'move_cursor': {'target', 'delivery_mode', 'x', 'y'},
}


def validate(binary):
    with tempfile.TemporaryDirectory(prefix='woven-cua-metadata-') as home:
        environment = dict(os.environ, CUA_DRIVER_RS_TELEMETRY_ENABLED='false',
            CUA_DRIVER_RS_UPDATE_CHECK='false', DO_NOT_TRACK='1', CUA_DRIVER_RS_HOME=home, CUA_HOME=home)
        for tool, fields in FIELDS.items():
            result = subprocess.run([str(binary), 'describe', tool], env=environment,
                capture_output=True, text=True, check=True, timeout=15)
            schema = json.loads(result.stdout.split('input_schema:\n', 1)[1])
            missing = fields - set(schema['properties'])
            if missing:
                raise ValueError('Cua %s is missing fields: %s' % (tool, sorted(missing)))
        print('Packaged Cua desktop tool schemas verified (no desktop or provider access).')


if __name__ == '__main__':
    validate(Path(sys.argv[1]))
