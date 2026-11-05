"""Execute only link_probe and kb_resolve_scheme with a fake clang: no Apple compiler or device needed."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def probe_flags(configuration=None, benchmark=None):
    source = (ROOT / 'Apelin/build.sh').read_text(encoding='utf-8')
    function = source.split('link_probe() {', 1)[1].split('\n}\n', 1)[0]
    script = ('set -eu\nclang() { printf "%s\\n" "$@"; }\n'
              'link_probe() {' + function + '\n}\nlink_probe arm64e /tmp/keybridge-test-objects\n')
    env = os.environ.copy()
    for key in ('APELIN_CONFIGURATION', 'KEYBRIDGE_LOOKUP_BENCHMARK', 'KEYBRIDGE_MIN_IOS'):
        env.pop(key, None)
    env.update(SDKROOT='/test/SDK', APELIN_BUILD_ID='test-only')
    if configuration is not None:
        env['APELIN_CONFIGURATION'] = configuration
    if benchmark is not None:
        env['KEYBRIDGE_LOOKUP_BENCHMARK'] = benchmark
    return subprocess.run(['sh', '-c', script], env=env, text=True, encoding='utf-8',
                          errors='replace', capture_output=True)


def scheme_vars(scheme=None, prefix=None, min_ios=None, version=None):
    """跑 build.sh 里的形态派生，拿到 scheme/prefix/min_ios/version/firmware 一份解析结果。"""
    source = (ROOT / 'Apelin/build.sh').read_text(encoding='utf-8')
    function = source.split('kb_resolve_scheme() {', 1)[1].split('\n}\n', 1)[0]
    script = 'set -eu\nkb_resolve_scheme() {' + function + '\n}\nkb_resolve_scheme\n'
    env = os.environ.copy()
    for key in ('KEYBRIDGE_SCHEME', 'APELIN_PREFIX', 'KEYBRIDGE_MIN_IOS', 'KEYBRIDGE_VERSION'):
        env.pop(key, None)
    for name, value in (('KEYBRIDGE_SCHEME', scheme), ('APELIN_PREFIX', prefix),
                        ('KEYBRIDGE_MIN_IOS', min_ios), ('KEYBRIDGE_VERSION', version)):
        if value is not None:
            env[name] = value
    return subprocess.run(['sh', '-c', script], env=env, text=True, encoding='utf-8',
                          errors='replace', capture_output=True)


def fields(result):
    if result.returncode != 0:
        raise AssertionError('exit=%s stderr=%s' % (result.returncode, result.stderr))
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


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

    def test_probe_defaults_to_ios_15_min(self):
        result = probe_flags('debug', None)
        self.assertIn('-mios-version-min=15.0', result.stdout.splitlines())


class SchemeTests(unittest.TestCase):
    def test_rootless_prefix_is_var_jb(self):
        vars_ = fields(scheme_vars(scheme='rootless', prefix='/var/jb'))
        self.assertEqual(vars_['scheme'], 'rootless')
        self.assertEqual(vars_['prefix'], '/var/jb')
        self.assertEqual(vars_['min_ios'], '15.0')

    def test_rootless_without_prefix_still_gets_var_jb(self):
        vars_ = fields(scheme_vars(scheme='rootless', prefix=''))
        self.assertEqual(vars_['prefix'], '/var/jb')

    def test_roothide_layout_has_no_prefix(self):
        vars_ = fields(scheme_vars(prefix=''))
        self.assertEqual(vars_['scheme'], 'roothide')
        self.assertEqual(vars_['prefix'], '')

    def test_non_empty_prefix_is_inferred_as_rootless(self):
        vars_ = fields(scheme_vars(prefix='/var/jb'))
        self.assertEqual(vars_['scheme'], 'rootless')

    def test_firmware_dep_has_lower_bound_only(self):
        # 只声明下限：iOS 15/16/17 都能装；旧包写死 firmware (<< 17.0)，把 15 直接挡在门外。
        vars_ = fields(scheme_vars(scheme='rootless', prefix='/var/jb'))
        self.assertEqual(vars_['firmware'], 'firmware (>= 15.0)')
        self.assertNotIn('<', vars_['firmware'])

    def test_unknown_scheme_fails(self):
        result = scheme_vars(scheme='rootful')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rootless or roothide', result.stderr)

    def test_version_can_be_overridden(self):
        vars_ = fields(scheme_vars(scheme='rootless', prefix='/var/jb', version='0.0.9'))
        self.assertEqual(vars_['version'], '0.0.9')


if __name__ == '__main__':
    unittest.main()
