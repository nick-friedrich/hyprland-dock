"""CLI-01: exercise the real wrapper/adapter against a narrow qs process fixture."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

FAKE_QS = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['QS_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
f = json.loads(Path(os.environ['QS_FIXTURE']).read_text())
if args == ['list', '--all', '--json']:
    print(f.get('listOutput', json.dumps(f.get('instances', []))))
    sys.exit(f.get('listExit', 0))
if len(args) != 8 or args[:2] != ['ipc', '--pid'] or args[3:7] != ['call', '--', 'smartdock', 'request']:
    print('Unexpected qs invocation: ' + repr(args), file=sys.stderr)
    sys.exit(90)
pid = args[2]
host = f.get('hosts', {}).get(pid)
if host is None:
    print('Target not found.')
    sys.exit(0)
if 'rawReply' in host:
    print(host['rawReply'])
    sys.exit(host.get('exit', 0))
request = json.loads(args[7])
assert request['apiVersion'] == 1
print('fixture diagnostic', file=sys.stderr)
if request['command'] in ('status', 'doctor'):
    data = dict(host['status'])
elif request['command'] == 'mode.toggle':
    data = host.get('modeData', {})
else:
    data = host.get('data', {'settings': {'iconSize': 42}, 'source': 'requested'})
print(json.dumps({'apiVersion': host.get('apiVersion', 1), 'ok': True, 'data': data, 'warnings': []}))
'''


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='smartdock cli ')
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        qs = self.bin / 'qs'
        qs.write_text('#!' + sys.executable + '\n' + FAKE_QS)
        qs.chmod(0o755)
        self.fixture = self.tmp / 'fixture.json'
        self.calls = self.tmp / 'calls.jsonl'
        self.env = dict(os.environ, HOME=str(self.tmp / 'home'),
                        XDG_CONFIG_HOME=str(self.tmp / 'config'),
                        XDG_DATA_HOME=str(self.tmp / 'data'),
                        XDG_CACHE_HOME=str(self.tmp / 'cache'),
                        XDG_BIN_HOME=str(self.tmp / 'user bin'),
                        QS_FIXTURE=str(self.fixture), QS_CALLS=str(self.calls),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.set_hosts()

    def set_hosts(self, *modes, **overrides):
        instances, hosts = [], {}
        for index, mode in enumerate(modes, 101):
            pid = str(index)
            instances.append({'id': 'qs-' + pid, 'pid': index,
                              'config_path': '/a shell/shell.qml',
                              'shell_id': '', 'launch_time': '2026-09-10T12:00:00'})
            if mode is not None:
                hosts[pid] = {'status': {
                    'runtime': {'mode': mode, 'instanceId': pid},
                    'configPath': '/authoritative config/dock.json',
                    'loadState': 'missing', 'loadError': '', 'revision': 0,
                    'writeState': 'idle', 'writeError': '', 'persisted': False,
                    'defaultsInUse': True}}
        fixture = dict(instances=instances, hosts=hosts)
        fixture.update(overrides)
        self.fixture.write_text(json.dumps(fixture))
        return fixture

    def run_cli(self, *args):
        return subprocess.run(['bash', str(ROOT / 'scripts/smartdock'), *args],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def response(self, args, code=0):
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        value = json.loads(result.stdout)
        self.assertEqual(value['apiVersion'], 1)
        self.assertIs(type(value['ok']), bool)
        self.assertIsInstance(value['data'], dict)
        self.assertIsInstance(value['warnings'], list)
        return value

    def assert_no_state(self):
        for key in ('XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME'):
            self.assertFalse(Path(self.env[key]).exists(), key)

    def test_bare_help_and_guide_are_offline(self):
        for args in ((), ('help',), ('agent-guide',)):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip())
        self.assertFalse(self.calls.exists())
        self.assert_no_state()

    def test_typo_and_invalid_arguments_never_launch(self):
        for args in (('statsu', '--json'), ('config', 'get', 'x', 'y', '--json'),
                     ('--runtime', 'wrong', 'status', '--json')):
            value = self.response(args, 2)
            self.assertEqual(value['error']['code'], 'E_USAGE')
        self.assertFalse(self.calls.exists())
        self.assert_no_state()

    def test_mode_toggle_routes_to_selected_host_without_connector(self):
        reply = self.response(('mode', '--json'), 2)
        self.assertEqual(reply['error']['code'], 'E_USAGE')
        self.assertFalse(self.calls.exists())

        self.set_hosts('plugin')
        fixture = json.loads(self.fixture.read_text())
        status = dict(fixture['hosts']['101']['status'])
        status.update({'loadPending': False, 'revision': 1, 'writeState': 'saved',
                       'persisted': True, 'applied': True, 'noop': False,
                       'changedKeys': ['presentationModeByMonitor'],
                       'requested': {}, 'effective': {},
                       'modeSwitch': {'connector': 'DP-2', 'from': 'classic',
                                      'to': 'sidebar'}})
        fixture['hosts']['101']['modeData'] = status
        self.fixture.write_text(json.dumps(fixture))
        response = self.response(('mode', 'toggle', '--json'))
        self.assertEqual(response['data']['modeSwitch']['connector'], 'DP-2')
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        ipc = json.loads(calls[-1][-1])
        self.assertEqual(ipc['command'], 'mode.toggle')
        self.assertEqual(ipc['arguments'], {})

    def test_missing_runtime_and_read_only_doctor(self):
        for command in ('status', 'doctor'):
            value = self.response((command, '--json'), 3)
            self.assertEqual(value['error']['code'], 'E_RUNTIME_NOT_FOUND')
        self.assert_no_state()

    def test_offline_schema_inventory_defaults_and_keyed_read(self):
        value = self.response(('config', 'schema', '--json'))
        self.assertEqual(value['data']['source'], 'bundled')
        self.assertEqual(value['data']['schemaVersion'], 1)
        defaults = json.loads((ROOT / 'config/dock.json').read_text())
        self.assertEqual(set(value['data']['settings']), set(defaults))
        for key, default in defaults.items():
            self.assertEqual(value['data']['settings'][key]['default'], default, key)
        single = self.response(('config', 'schema', 'hoverGlowOpacity', '--json'))
        self.assertEqual(set(single['data']['settings']), {'hoverGlowOpacity'})
        self.assertEqual(single['data']['settings']['hoverGlowOpacity']['default'], .72)
        self.assert_no_state()

    def test_exact_host_status_and_global_flag_positions(self):
        self.set_hosts('plugin')
        for args in (('--runtime', 'plugin', '--instance', '101', '--json', 'status'),
                     ('status', '--json', '--instance', 'qs-101', '--runtime', 'plugin')):
            value = self.response(args)
            self.assertEqual(value['data']['runtime']['instanceId'], '101')
            self.assertEqual(value['data']['configPath'], '/authoritative config/dock.json')
            self.assertFalse(value['data']['persisted'])
            self.assertEqual(value['data']['loadState'], 'missing')
        for call in map(json.loads, self.calls.read_text().splitlines()):
            self.assertTrue(call[:1] == ['list'] or call[:2] == ['ipc', '--pid'], call)
        self.assert_no_state()

    def test_multiple_hosts_require_selection_not_newest(self):
        self.set_hosts('plugin', 'standalone')
        for command in (('status',), ('config', 'schema')):
            value = self.response((*command, '--json'), 3)
            self.assertEqual(value['error']['code'], 'E_RUNTIME_AMBIGUOUS')
        value = self.response(('status', '--runtime', 'standalone', '--json'))
        self.assertEqual(value['data']['runtime']['instanceId'], '102')
        self.set_hosts('plugin', 'plugin')
        value = self.response(('status', '--runtime', 'plugin', '--json'), 3)
        self.assertEqual(value['error']['code'], 'E_RUNTIME_AMBIGUOUS')

    def test_explicit_misses_do_not_fall_back_to_bundled_schema(self):
        self.set_hosts('plugin')
        for selector in (('--instance', 'missing'), ('--runtime', 'standalone')):
            value = self.response(('config', 'schema', *selector, '--json'), 3)
            self.assertEqual(value['error']['code'], 'E_RUNTIME_NOT_FOUND')

    def test_unrelated_quickshell_is_not_a_dock(self):
        self.set_hosts(None, 'plugin')
        value = self.response(('status', '--json'))
        self.assertEqual(value['data']['runtime']['instanceId'], '102')

    def test_protocol_errors_are_not_absence_or_bundled_fallback(self):
        for raw in ('not JSON', 'log noise\n{}', '[]',
                    '{"apiVersion":2,"ok":true,"data":{},"warnings":[]}',
                    '{"apiVersion":1,"ok":"true","data":{},"warnings":[]}',
                    '{"apiVersion":1,"ok":true,"data":{},"warnings":[]}'):
            f = self.set_hosts('plugin')
            f['hosts']['101']['rawReply'] = raw
            self.fixture.write_text(json.dumps(f))
            value = self.response(('config', 'schema', '--json'), 5)
            self.assertEqual(value['error']['code'], 'E_PROTOCOL')

    def test_malformed_instance_list_is_not_absence(self):
        self.set_hosts(listOutput='unsupported JSON option')
        value = self.response(('config', 'schema', '--json'), 5)
        self.assertEqual(value['error']['code'], 'E_PROTOCOL')

    def test_upstream_empty_list_diagnostic_is_supported(self):
        self.set_hosts(listOutput='No running instances.')
        value = self.response(('config', 'schema', '--json'))
        self.assertEqual(value['data']['source'], 'bundled')

    def test_diagnostics_do_not_pollute_json_stdout(self):
        self.set_hosts('plugin')
        result = self.run_cli('status', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['ok'])
        self.assertIn('fixture diagnostic', result.stderr)

    def test_timeout_outcome_is_unknown(self):
        path = ROOT / 'scripts/smartdock_cli.py'
        self.assertTrue(path.is_file(), 'The bounded CLI adapter must be implemented')
        spec = importlib.util.spec_from_file_location('smartdock_cli', path)
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with patch.object(cli.subprocess, 'run', side_effect=subprocess.TimeoutExpired('qs', 2)):
            with self.assertRaises(cli.CliError) as caught:
                cli.Transport().run(['qs', 'list', '--all', '--json'])
        self.assertEqual(caught.exception.code, 'E_TIMEOUT')
        self.assertIsNone(caught.exception.data['applied'])
        self.assertIsNone(caught.exception.data['persisted'])


if __name__ == '__main__':
    unittest.main()
