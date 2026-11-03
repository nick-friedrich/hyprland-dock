"""Documentation contracts: real CLI parsing + existing production-host harness.

Only transport/FileView services are substituted. No copied patch validator,
new runtime, or desktop session is involved. The marked guide blocks are inputs.
"""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('docs_cli', ROOT / 'scripts/smartdock_cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
DOCUMENTS = ('AGENT_CONFIGURATION.md', 'CLI_REFERENCE.md', 'CONFIGURATION.md',
             'CLI_RUNTIME_CHECKS.md')

# Replay into the existing harness so every request runs production QML method
# bodies and DockConfigModel/DockIconModel. Replaying keeps this fixture stateless
# between Python processes; it is not a second model implementation.
BRIDGE = """
import fs from 'node:fs';
import { hostHarness } from './tests/host_harness.mjs';
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const h = hostHarness(input.initial, [{id:'code',name:'Editor'},
  {id:'org.gnome.Nautilus',name:'Files'}, {id:'chatgpt',name:'ChatGPT'}]);
let reply;
for (const [command, args] of input.requests) reply = h.request(command, args);
console.log(JSON.stringify(reply));
"""


class ModelTransport:
    def __init__(self):
        self.initial = {
            'pinned': ['org.gnome.Nautilus', 'Missing.App', 'code', 'chatgpt'],
            'hiddenApplications': ['code', 'Missing.App'],
            'iconOverrides': {'other': '/tmp/keep.png', 'legacy': 'untouched-legacy'},
            'hoverGlowOpacity': 0.72, 'clickAction': 'launch',
            'extensionData': {'keep': ['opaque']},
        }
        self.requests = []

    def select(self, runtime='auto', instance_id=None):
        return {'id': 'docs-fixture', 'pid': 123}, self.request(None, 'status')

    def request(self, instance, command, arguments=None):
        self.requests.append([command, arguments or {}])
        result = subprocess.run(['node', '--input-type=module', '-e', BRIDGE],
                                cwd=ROOT, text=True, capture_output=True, timeout=10,
                                input=json.dumps({'initial': self.initial,
                                                  'requests': self.requests}))
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)


class CliDocumentationTests(unittest.TestCase):
    def setUp(self):
        self.guide = (ROOT / 'docs/AGENT_CONFIGURATION.md').read_text(encoding='utf-8')
        self.transport = ModelTransport()
        self.mock = patch.object(cli, 'Transport', return_value=self.transport)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def run_command(self, command):
        args = shlex.split(command)
        self.assertEqual(args.pop(0), 'dockrail')
        reply = cli.execute(cli.build_parser().parse_args(args))
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def block(self, name, language, text=None):
        match = re.search(r'<!-- recipe: ' + re.escape(name) + r' -->\s*```'
                          + language + r'\n(.*?)\n```', self.guide if text is None else text, re.S)
        self.assertIsNotNone(match, 'Missing executable guide recipe: ' + name)
        return match.group(1)

    def test_all_reference_defaults_commands_and_errors_match_implementation(self):
        inventory = ROOT / 'docs/CONFIGURATION.md'
        reference = ROOT / 'docs/CLI_REFERENCE.md'
        for path in (inventory, reference, ROOT / 'docs/CLI_RUNTIME_CHECKS.md',
                     ROOT / 'docs/SETTINGS.md',
                     ROOT / 'docs/plans/2026-09-10-cli-first-migration.md'):
            self.assertTrue(path.is_file(), 'Missing deliverable: ' + str(path))
        rows = re.findall(r'^\| `([^`]+)` \| `([^`]+)` \|', inventory.read_text(), re.M)
        defaults = json.loads((ROOT / 'config/dock.json').read_text())
        self.assertEqual(len(rows), len(defaults), 'Each setting has exactly one inventory row')
        self.assertEqual({key: json.loads(value) for key, value in rows}, defaults)
        metadata = cli.bundled_schema()['data']
        text = reference.read_text()
        for command in metadata['commands']:
            self.assertIn('`' + command.replace('.', ' ') + '`', text)
        # Derive command coverage from the real parser, not a parallel registry.
        def leaves(parser, prefix=()):
            groups = [action for action in parser._actions
                      if isinstance(action, argparse._SubParsersAction)]
            if not groups:
                return {'.'.join(prefix)}
            return set().union(*(leaves(child, prefix + (name,))
                                 for group in groups for name, child in group.choices.items()))
        self.assertEqual(leaves(cli.build_parser()), set(metadata['commands']))
        for code in cli.EXIT_CODES:
            self.assertIn(code, text)
        self.assertEqual(metadata['settings']['controlCommand']['risk'], 'executes-on-use')
        self.assertIn('controlCommand', self.guide)
        self.assertIn('never execute it to validate', self.guide)

    def test_json_recipes_dry_run_apply_preserve_and_project(self):
        for name in ('safe-batch', 'theme', 'calmer-motion', 'workspace-cards'):
            payload = json.loads(self.block(name, 'json'))
            before = self.run_command('dockrail config get --json')['settings']
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / 'patch with spaces.json'
                path.write_text(json.dumps(payload), encoding='utf-8')
                command = 'dockrail config apply --file ' + shlex.quote(str(path))
                dry = self.run_command(command + ' --dry-run --json')
                self.assertFalse(dry['applied'])
                self.assertFalse(dry['persisted'])
                self.assertEqual(self.run_command('dockrail config get --json')['settings'], before)
                applied = self.run_command(command + ' --json')
                self.assertTrue(applied['persisted'])
            after = self.run_command('dockrail config get --json')['settings']
            self.assertEqual(after, dict(before, **payload))
        effective = self.run_command('dockrail config get --effective --json')['settings']
        self.assertEqual(effective['hoverGlowOpacity'], 0.70)
        self.assertEqual(effective['workspaceLayout'], 'grouped')
        self.assertEqual(effective['workspaceMonitorScope'], 'current-monitor')
        self.assertEqual(effective['magnification'], 1)
        self.assertFalse(effective['reserveSpace'])
        self.assertIsNone(effective['backgroundColor'])
        self.assertEqual(after['backgroundColor'], '@menu.background')
        self.assertTrue(after['backgroundColorEnabled'])
        self.assertTrue(after['borderColorEnabled'])
        self.assertEqual(after['clickAction'], 'launch', 'Unrelated legacy intent is preserved')
        # The classic dock is bottom-only; legacy vertical positions are rejected
        # for new writes and the sidebar mode is the vertical presentation.
        rejected_args = shlex.split('dockrail config set position left --json')
        rejected_args.pop(0)
        rejected = cli.execute(cli.build_parser().parse_args(rejected_args))
        self.assertFalse(rejected['ok'], rejected)
        self.assertEqual(rejected['error']['code'], 'E_VALIDATION')
        self.assertEqual(self.run_command('dockrail config get position --effective --json')['settings'],
                         {'position': 'bottom'})
        self.run_command('dockrail config set presentationMode sidebar --json')
        self.assertEqual(self.run_command('dockrail config get presentationMode --json')['settings'],
                         {'presentationMode': 'sidebar'})
        self.run_command('dockrail config set presentationMode classic --json')

    def run_shell_recipe_line(self, command):
        # Parse the documented printf pipeline without invoking a shell or any
        # live command. Only transport is replaced; stdin parsing and the host
        # settings methods are production code.
        args = shlex.split(command)
        if args[0] == 'dockrail':
            return self.run_command(command)
        self.assertEqual(args[:2], ['printf', '%s\\n'])
        self.assertEqual(args[3:5], ['|', 'dockrail'])
        self.assertIn('--stdin', args[5:])
        with io.TextIOWrapper(io.BytesIO((args[2] + '\n').encode())) as stdin:
            with patch.object(cli.sys, 'stdin', stdin):
                reply = cli.execute(cli.build_parser().parse_args(args[5:]))
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def test_readme_sidebar_recipe_preserves_monitor_choices_and_other_settings(self):
        self.transport.initial['presentationModeByMonitor'] = {'DP-1': 'classic'}
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        before = self.run_command('dockrail config get --json')['settings']
        result = self.run_shell_recipe_line(self.block('sidebar-default', 'bash', text))
        self.assertTrue(result['persisted'])
        after = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(after, dict(before, presentationMode='sidebar', sidebarEdge='left'))
        self.assertEqual(after['presentationModeByMonitor'], {'DP-1': 'classic'})
        self.assertIn('per-monitor choices in `presentationModeByMonitor` take precedence', text)

    def test_reference_sidebar_examples_use_the_real_cli_and_host(self):
        text = (ROOT / 'docs/CLI_REFERENCE.md').read_text(encoding='utf-8')
        for line in self.block('sidebar-settings', 'sh', text).splitlines():
            with self.subTest(command=line):
                self.run_shell_recipe_line(line)
        settings = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(settings['sidebarCollapsedByMonitor'], {'DP-1': True, 'HDMI-A-1': False})
        self.assertEqual(settings['presentationMode'], 'classic')
        self.assertEqual(settings['presentationModeByMonitor'], {})
        self.assertEqual(settings['extensionData'], self.transport.initial['extensionData'])
        self.assertEqual(settings['iconOverrides'], self.transport.initial['iconOverrides'])
        self.assertEqual(settings['pinned'], self.transport.initial['pinned'])

    def test_application_recipe_restores_and_orders_without_dropping_unknown_ids(self):
        for line in self.block('applications', 'sh').splitlines():
            self.run_command(line)
        settings = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(settings['pinned'], ['code', 'org.gnome.Nautilus', 'Missing.App', 'chatgpt'])
        self.assertEqual(settings['hiddenApplications'], ['Missing.App'])
        self.assertEqual(settings['extensionData'], self.transport.initial['extensionData'])
        self.assertEqual(settings['iconOverrides'], self.transport.initial['iconOverrides'])

    def test_icon_recipe_updates_only_one_mapping_and_never_claims_rendering(self):
        pins = self.transport.initial['pinned']
        reload_revision = None
        for line in self.block('icons', 'sh').splitlines():
            data = self.run_command(line)
            self.assertFalse(data['renderVerified'])
            if 'icons set ' in line:
                self.assertTrue(data['persisted'])
                reload_revision = data['iconReloadRevision']
                expected = dict(self.transport.initial['iconOverrides'],
                                code=Path('Pictures/My Ícone.svg').absolute().as_uri())
                self.assertEqual(data['requested']['iconOverrides'], expected)
            if 'icons reload ' in line:
                self.assertFalse(data['applied'])
                self.assertTrue(data['reloaded'])
                self.assertGreater(data['iconReloadRevision'], reload_revision)
        settings = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(settings['iconOverrides'], self.transport.initial['iconOverrides'])
        self.assertEqual(settings['pinned'], pins)
        self.assertEqual(settings['extensionData'], self.transport.initial['extensionData'])

    def test_window_icon_recipe_roundtrips_exact_rule_without_touching_app_icons(self):
        before_icons = dict(self.transport.initial['iconOverrides'])
        saw_set = False
        for line in self.block('window-icons', 'sh').splitlines():
            data = self.run_command(line)
            if 'icons ' in line:
                self.assertFalse(data['renderVerified'])
            if 'icons set ' in line:
                saw_set = True
                self.assertTrue(data['persisted'])
                self.assertEqual(data['effectiveWindowOverrides'], [{
                    'appId': 'com.mitchellh.ghostty',
                    'titlePattern': '*solar*',
                    'source': Path('Pictures/solar.svg').absolute().as_uri(),
                }])
            if 'icons reset ' in line:
                self.assertEqual(data['requested']['windowIconOverrides'], [])
        self.assertTrue(saw_set)
        settings = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(settings['windowIconOverrides'], [])
        self.assertEqual(settings['iconOverrides'], before_icons)
        self.assertEqual(settings['extensionData'], self.transport.initial['extensionData'])

    def test_document_shell_syntax_and_relative_links(self):
        for name in DOCUMENTS:
            text = (ROOT / 'docs' / name).read_text(encoding='utf-8')
            for index, block in enumerate(re.findall(r'^```(?:sh|bash)\n(.*?)^```', text, re.M | re.S)):
                # Parse only: never execute a local qualification/lifecycle block.
                result = subprocess.run(['bash', '-n'], input=block, text=True,
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, (name, index, result.stderr))
            for target in re.findall(r'\[[^\]]+\]\(([^)]+\.md)\)', text):
                if '://' not in target:
                    self.assertIn(target, DOCUMENTS, (name, 'Uninstalled documentation link', target))

    def test_settings_policy_and_accepted_design_record(self):
        agents = (ROOT / 'AGENTS.md').read_text(encoding='utf-8')
        reference = (ROOT / 'docs/CLI_REFERENCE.md').read_text(encoding='utf-8')
        record = (ROOT / 'docs/SETTINGS.md').read_text(encoding='utf-8')

        self.assertNotIn('Do not add a settings window', agents)
        self.assertNotIn('Configuration is CLI-only', self.guide)
        for text in (agents, self.guide, reference):
            self.assertIn('AI coding agents', text)
            self.assertIn('Settings', text)
            self.assertIn('single host', text)
        self.assertIn('Change Icon', agents)
        self.assertRegex(agents, r'sole icon\s+editor')
        self.assertIn('does not ship', agents)
        self.assertIn('not shipped', self.guide)
        self.assertIn('does **not** ship', reference)

        for required in (
                'KeyboardPanel', '680 px wide', 'two panes', 'Omarchy 4.0.4',
                'Appearance', 'Layout', 'Behavior', 'Sidebar & Widgets',
                'Features', 'Apps', 'Apply on change',
                'Sliders commit on release', 'Classic visibility rule',
                'One editing slot', 'Changed elsewhere', 'E_STALE',
                'Saving', 'Saved', 'Not saved', 'E_PERSISTENCE',
                'E_VALIDATION', 'E_CONFIG_INVALID',
                '0dbd7c54151577457deb45b3cf282b37fb2fc258',
                '## Decided'):
            self.assertIn(required, record)
        self.assertIn('Change Icon is the sole icon editor', record)
        self.assertIn('single host FileView/settings writer', record)
        self.assertIn('SET-01 is documentation and policy only', record)
        self.assertIn('dockrail-settings-implementation-plan-rev18.md', record)
        self.assertIn('dockrail-settings-design-canvas-2026-10-21.md', record)
        self.assertIn('Partly on', record)
        self.assertIn('Apps › Chrome', record)
        self.assertIn('Classic settings stay visible', record)
        self.assertIn('Settings may start named typed Dockrail actions', record)
        frozen = re.findall(
            r'^\| `([^`]+)` \| (?:Appearance|Layout|Behavior|Sidebar & Widgets|Apps) \|',
            record, re.M)
        self.assertEqual(len(frozen), 62)
        keys = set(json.loads((ROOT / 'config/settings-schema.json').read_text())['settings'])
        self.assertEqual(set(frozen), keys)


    def test_installed_guide_and_reference_are_offline_and_match_source(self):
        with tempfile.TemporaryDirectory(prefix='smartdock docs ') as temporary:
            root = Path(temporary)
            tools = root / 'tools'
            tools.mkdir()
            sentinel = root / 'qs-was-called'
            (tools / 'qs').write_text('#!/bin/sh\ntouch "' + str(sentinel) + '"\nexit 99\n')
            (tools / 'qs').chmod(0o755)
            env = dict(os.environ, HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
                       XDG_CONFIG_HOME=str(root / 'config'), XDG_BIN_HOME=str(root / 'bin'),
                       XDG_CACHE_HOME=str(root / 'cache'), PATH=str(tools) + ':' + os.environ['PATH'])
            subprocess.run(['bash', str(ROOT / 'install.sh'), '--cli-only'], env=env,
                           check=True, capture_output=True, text=True, timeout=10)
            installed = root / 'data/dockrail-cli'
            for name in DOCUMENTS:
                self.assertTrue((installed / 'docs' / name).is_file(), name + ' must be installed')
                self.assertEqual((installed / 'docs' / name).read_bytes(), (ROOT / 'docs' / name).read_bytes())
            # A missing source checkout must not break the installed offline guide.
            (installed / '.source-dir').write_text('/nonexistent/source-checkout\n')
            result = subprocess.run([str(root / 'bin/dockrail'), 'agent-guide', '--json'], env=env,
                                    check=True, capture_output=True, text=True, timeout=10)
            self.assertEqual(json.loads(result.stdout)['data']['text'], self.guide)
            compatibility = subprocess.run([str(root / 'bin/smartdock'), 'help'], env=env,
                                           check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('Usage: dockrail', compatibility.stdout)
            self.assertFalse(sentinel.exists())
            for path in ('config', 'cache', 'data/dockrail', 'data/smartdock', 'data/applications', 'data/icons'):
                self.assertFalse((root / path).exists(), path)


if __name__ == '__main__':
    unittest.main()
