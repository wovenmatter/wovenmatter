"""Exercise simulator ownership, readiness, results and failure propagation offline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STUB = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['WM_RUNNER_CALLS'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'xcrun' and sys.argv[1:3] == ['simctl', 'create']:
    print('fixture-simulator')
if name == 'xcodebuild':
    sys.exit(int(os.environ.get('WM_XCODE_EXIT', '0')))
'''


class IOSRunnerTests(unittest.TestCase):
    def run_script(self, mode, **overrides):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            binary = fixture / 'bin'
            binary.mkdir()
            for name in ['swift', 'xcrun', 'open', 'xcodebuild']:
                path = binary / name
                path.write_text(STUB)
                path.chmod(0o755)
            calls = fixture / 'calls.jsonl'
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith('WOVENMATTER_IOS_')}
            environment.update(PATH=str(binary) + os.pathsep + os.environ['PATH'],
                               WM_RUNNER_CALLS=str(calls),
                               WOVENMATTER_IOS_TEST_CACHE_DIR=str(fixture / 'cache'))
            environment.update(overrides)
            result = subprocess.run(['bash', str(ROOT / 'scripts/test-ios.sh'), mode],
                                    env=environment, capture_output=True, text=True)
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_package_does_not_create_or_open_simulator(self):
        result, calls = self.run_script('--package')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ['swift'])

    def test_owned_device_is_ready_before_testing_and_always_cleaned(self):
        result, calls = self.run_script('--ui')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:3] for call in calls], [
            ['swift', 'test', '--package-path'], ['xcrun', 'simctl', 'create'],
            ['xcrun', 'simctl', 'boot'], ['xcrun', 'simctl', 'bootstatus'],
            ['open', '-a', 'Simulator'], ['xcodebuild', '-project', str(ROOT / 'ios/WovenMatterCompanion.xcodeproj')],
            ['xcrun', 'simctl', 'shutdown'], ['xcrun', 'simctl', 'delete']])
        self.assertIn('-b', calls[3])
        self.assertIn('-CurrentDeviceUDID', calls[4])
        self.assertIn('-resultBundlePath', calls[5])
        self.assertNotIn('-only-testing:CompanionAppTests', calls[5])

    def test_explicit_destination_is_never_booted_opened_or_deleted_and_failure_survives_tee(self):
        result, calls = self.run_script('--simulator', WM_XCODE_EXIT='17',
            WOVENMATTER_IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,id=user-device')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual([call[0] for call in calls], ['swift', 'xcodebuild'])
        self.assertIn('platform=iOS Simulator,id=user-device', calls[1])
        self.assertIn('-only-testing:CompanionAppTests', calls[1])

    def test_both_devices_have_separate_result_bundles(self):
        result, calls = self.run_script('--all-devices')
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in calls if call[0] == 'xcodebuild']
        self.assertEqual(len(builds), 2)
        paths = [call[call.index('-resultBundlePath') + 1] for call in builds]
        self.assertEqual(len(set(paths)), 2)
        creates = [call for call in calls if call[:3] == ['xcrun', 'simctl', 'create']]
        self.assertIn('com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', creates[0])
        self.assertIn('com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB', creates[1])


if __name__ == '__main__':
    unittest.main()
