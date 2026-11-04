"""Settings CLI routing exercises the real parser and the fixed IPC argv."""
import importlib.util
import json
import shlex
import tempfile
from pathlib import Path
from unittest import TestCase, mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dockrail_settings_cli', ROOT / 'scripts/smartdock_cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
# Reuse the documentation fixture: it runs the production DockHost/DockControl
# method bodies through the real host harness, so typed validation, readback and
# persistence are not reimplemented here.
from test_cli_docs import ModelTransport  # noqa: E402


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.message = 'opened'
    def select(self, runtime, instance_id):
        self.calls.append(('select',runtime,instance_id))
        return ({'id':'fixture','pid':641}, {'apiVersion':1,'ok':True,'data': {
            'runtime': {'mode':'plugin','instanceId':'fixture'},
            'loadState':'loaded', 'writeState':'idle',
        },'warnings':[]})
    def run(self, argv):
        self.calls.append(('run',argv))
        return self.message


class SettingsCliTests(TestCase):
    def test_settings_opens_one_host_without_writing_any_config(self):
        transport = FakeTransport()
        with mock.patch.object(cli, 'Transport', return_value=transport):
            result = cli.execute(cli.build_parser().parse_args(['settings','--runtime','plugin']))
        self.assertTrue(result['ok'])
        self.assertTrue(result['data']['opened'])
        self.assertEqual(transport.calls, [
            ('select','plugin',None),
            ('run',['qs','ipc','--pid','641','call','--','dockrail-settings','open']),
        ])
    def test_missing_real_anchor_is_not_claimed_as_success(self):
        transport = FakeTransport()
        transport.message = 'no-anchor'
        with mock.patch.object(cli, 'Transport', return_value=transport):
            with self.assertRaises(cli.CliError) as caught:
                cli.execute(cli.build_parser().parse_args(['settings']))
        self.assertEqual(caught.exception.code,'E_RUNTIME_NOT_FOUND')


class DragHoverSettingsCliTests(TestCase):
    def setUp(self):
        self.transport = ModelTransport()
        self.mock = mock.patch.object(cli, 'Transport', return_value=self.transport)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def run_command(self, command):
        args = shlex.split(command)
        self.assertEqual(args.pop(0), 'dockrail')
        return cli.execute(cli.build_parser().parse_args(args))

    def requested(self, key=None):
        arguments = {} if key is None else {'key': key}
        return self.transport.request(None, 'config.get', arguments)['data']['settings']

    def test_defaults_are_true_and_500_with_unknown_keys_preserved(self):
        settings = self.requested()
        self.assertIs(settings['dragHoverNavigationEnabled'], True)
        self.assertEqual(settings['dragHoverDelayMs'], 500)
        self.assertEqual(settings['extensionData'], {'keep': ['opaque']})

    def test_typed_set_write_readback_and_persistence(self):
        disabled = self.run_command('dockrail config set dragHoverNavigationEnabled false')
        self.assertTrue(disabled['ok'], disabled)
        self.assertTrue(disabled['data']['applied'])
        self.assertTrue(disabled['data']['persisted'])
        self.assertEqual(disabled['data']['requested']['dragHoverNavigationEnabled'], False)
        self.assertEqual(self.requested('dragHoverNavigationEnabled'),
                         {'dragHoverNavigationEnabled': False})

        delayed = self.run_command('dockrail config set dragHoverDelayMs 700')
        self.assertTrue(delayed['ok'], delayed)
        self.assertTrue(delayed['data']['applied'])
        self.assertTrue(delayed['data']['persisted'])
        self.assertEqual(self.requested('dragHoverDelayMs'), {'dragHoverDelayMs': 700})
        effective = self.transport.request(
            None, 'config.get', {'key': 'dragHoverDelayMs', 'effective': True})
        self.assertEqual(effective['data']['settings']['dragHoverDelayMs'], 700)
        # Unrelated legacy/unknown intent survives both canonical writes.
        self.assertEqual(self.requested()['extensionData'], {'keep': ['opaque']})
        self.assertEqual(self.requested()['clickAction'], 'launch')

    def test_dry_run_reports_requested_without_persisting(self):
        with tempfile.TemporaryDirectory(prefix='drag-hover patch ') as temporary:
            patch = Path(temporary) / 'patch.json'
            patch.write_text(json.dumps({'dragHoverDelayMs': 900}), encoding='utf-8')
            dry = self.run_command(
                'dockrail config apply --file ' + shlex.quote(str(patch)) + ' --dry-run')
        self.assertTrue(dry['ok'], dry)
        self.assertTrue(dry['data']['dryRun'])
        self.assertFalse(dry['data']['applied'])
        self.assertFalse(dry['data']['persisted'])
        self.assertEqual(dry['data']['requested']['dragHoverDelayMs'], 900)
        self.assertEqual(dry['data']['effective']['dragHoverDelayMs'], 900)
        self.assertEqual(self.requested('dragHoverDelayMs'), {'dragHoverDelayMs': 500})

    def test_invalid_type_and_bounds_are_rejected_by_the_host(self):
        with self.assertRaises(cli.CliError) as caught:
            self.run_command('dockrail config set dragHoverNavigationEnabled 1')
        self.assertEqual(caught.exception.code, 'E_VALIDATION')
        too_short = self.run_command('dockrail config set dragHoverDelayMs 50')
        self.assertFalse(too_short['ok'], too_short)
        self.assertEqual(too_short['error']['code'], 'E_VALIDATION')
        too_long = self.run_command('dockrail config set dragHoverDelayMs 2500')
        self.assertFalse(too_long['ok'], too_long)
        self.assertEqual(too_long['error']['code'], 'E_VALIDATION')
        self.assertEqual(self.requested('dragHoverDelayMs'), {'dragHoverDelayMs': 500})
