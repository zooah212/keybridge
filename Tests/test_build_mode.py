"""Execute only link_probe with a fake clang: no Apple compiler or device needed."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def probe_flags(configuration=None, benchmark=None, trace=None):
    source = (ROOT / 'Apelin/build.sh').read_text()
    function = source.split('link_probe() {', 1)[1].split('\n}\n', 1)[0]
    script = ('set -eu\nclang() { printf "%s\\n" "$@"; }\n'
              'link_probe() {' + function + '\n}\nlink_probe arm64e /tmp/keybridge-test-objects\n')
    env = os.environ.copy()
    for key in ('APELIN_CONFIGURATION', 'KEYBRIDGE_LOOKUP_BENCHMARK', 'KEYBRIDGE_CANDIDATE_TRACE'):
        env.pop(key, None)
    env.update(SDKROOT='/test/SDK', APELIN_BUILD_ID='test-only')
    if configuration is not None:
        env['APELIN_CONFIGURATION'] = configuration
    if benchmark is not None:
        env['KEYBRIDGE_LOOKUP_BENCHMARK'] = benchmark
    if trace is not None:
        env['KEYBRIDGE_CANDIDATE_TRACE'] = trace
    return subprocess.run(['sh', '-c', script], env=env, text=True, capture_output=True)


class BuildModeTests(unittest.TestCase):
    def test_candidate_trace_stays_opt_in_and_debug_only(self):
        for configuration, option, expected in (
            ('debug', None, 0), ('release', None, 0), ('debug', '0', 0),
            ('debug', '1', 1), ('release', '1', None), ('debug', 'invalid', None),
        ):
            with self.subTest(configuration=configuration, option=option):
                result = probe_flags(configuration, '0', option)
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('Probe/KeyBridgeProbe.m', result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('-DKB_CANDIDATE_TRACE=' + str(expected), result.stdout.splitlines())

    def test_probe_build_has_no_cloud_client(self):
        result = probe_flags('debug', '0')
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = result.stdout.splitlines()
        self.assertNotIn('Probe/KBCloudPinyin.m', arguments)
        self.assertFalse(any(arg.startswith('-DKB_CLOUD_DIAGNOSTICS=') for arg in arguments))

    def test_settings_and_probe_share_build_identity(self):
        source = (ROOT / 'Apelin/build.sh').read_text()
        function = source.split('compile_objc() {', 1)[1].split('\n}\n', 1)[0]
        script = ('set -eu\nclang() { printf "%s\\n" "$@"; }\n'
                  'compile_objc() {' + function + '\n}\ncompile_objc arm64e /tmp/test-objects\n')
        env = dict(os.environ, SDKROOT='/test/SDK', APELIN_BUILD_ID='test-only')
        result = subprocess.run(['sh', '-c', script], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        flag = '-DAPELIN_BUILD_ID="test-only"'
        self.assertIn(flag, result.stdout.splitlines())
        self.assertIn(flag, probe_flags().stdout.splitlines())

    def check_mode(self, configuration, benchmark, expected):
        result = probe_flags(configuration, benchmark)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DKB_LOOKUP_BENCHMARK=' + str(expected), result.stdout.splitlines())
        self.assertIn('Probe/KeyBridgeProbe.m', result.stdout.splitlines())

    def test_debug_is_not_an_automatic_benchmark(self):
        self.check_mode('debug', None, 0)

    def test_missing_configuration_is_not_an_automatic_benchmark(self):
        self.check_mode(None, None, 0)

    def test_release_excludes_reference_algorithm(self):
        self.check_mode('release', None, 0)

    def test_debug_can_explicitly_run_comparison(self):
        self.check_mode('debug', '1', 1)

    def test_explicit_disabled(self):
        self.check_mode('debug', '0', 0)

    def test_release_refuses_benchmark(self):
        result = probe_flags('release', '1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Probe/KeyBridgeProbe.m', result.stdout)

    def test_invalid_option_fails_before_compilation(self):
        result = probe_flags('debug', 'yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Probe/KeyBridgeProbe.m', result.stdout)


if __name__ == '__main__':
    unittest.main()
