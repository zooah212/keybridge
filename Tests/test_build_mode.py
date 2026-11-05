"""Execute only link_probe with a fake clang: no Apple compiler or device needed."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def probe_flags(configuration=None, benchmark=None):
    source = (ROOT / 'Apelin/build.sh').read_text()
    function = source.split('link_probe() {', 1)[1].split('\n}\n', 1)[0]
    script = ('set -eu\nclang() { printf "%s\\n" "$@"; }\n'
              'link_probe() {' + function + '\n}\nlink_probe arm64e /tmp/keybridge-test-objects\n')
    env = os.environ.copy()
    for key in ('APELIN_CONFIGURATION', 'KEYBRIDGE_LOOKUP_BENCHMARK'):
        env.pop(key, None)
    env.update(SDKROOT='/test/SDK', APELIN_BUILD_ID='test-only')
    if configuration is not None:
        env['APELIN_CONFIGURATION'] = configuration
    if benchmark is not None:
        env['KEYBRIDGE_LOOKUP_BENCHMARK'] = benchmark
    return subprocess.run(['sh', '-c', script], env=env, text=True, capture_output=True)


class BuildModeTests(unittest.TestCase):
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
