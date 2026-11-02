#!/usr/bin/env python3
"""Dockrail's stdlib-only IPC client. Never starts a host or edits its config."""
import argparse
import hashlib
import importlib.util
import http.client
import json
import math
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import time

BUNDLE = Path(__file__).resolve().parents[1]
EXIT_CODES = {
    'E_USAGE': 2, 'E_VALIDATION': 2,
    'E_RUNTIME_NOT_FOUND': 3, 'E_RUNTIME_AMBIGUOUS': 3,
    'E_PERSISTENCE': 4, 'E_EXPORT': 4,
    'E_TRANSPORT': 5, 'E_PROTOCOL': 5, 'E_TIMEOUT': 5, 'E_SETUP': 5,
    'E_BUSY': 6, 'E_CONFIG_INVALID': 6, 'E_STALE': 6,
}
HELP = '''Usage: dockrail [OPTIONS] COMMAND

Read-only commands (never launch or restart the dock):
  help                         Show this help
  agent-guide                  Print the bundled agent configuration guide
  status                       Show the selected host and persistence state
  doctor                       Check core health and optional feature readiness
  config schema [KEY]          Describe settings; bundled fallback when offline
  config get [KEY] [--effective]
                               Read requested or normalized live settings

Local terminal-agent launchers (no host required):
  launchers add | launchers remove
                                Own only matching recorded files

Guided setup (requires one selected running host):
  setup                        Interactive readiness + optional feature setup on a TTY
  setup --feature NAME --yes   Script one feature: chrome | herdr | launcher-counts |
                               agent-launchers

Live presentation (the selected host is the only writer):
  mode toggle                  Toggle dock/sidebar on Hyprland's focused monitor

Live configuration (the selected host is the only writer):
  config set KEY VALUE         Parse VALUE using the live setting's declared type
  config apply (--stdin | --file PATH) [--dry-run]
                               Validate one atomic JSON object patch
  config reset (KEY | --preferences)
                               Reset one key, or preferences without pins/hidden/margin/icons
  config retry                 Save the complete current live snapshot again
  config export --output PATH  Save a NEW snapshot, never overwrite a file or live config

Applications (exact desktop IDs, not fuzzy application names):
  apps list [--query TEXT | --pinned | --hidden]
                               Discover host applications, including unavailable stored IDs
  apps pin ID | apps unpin ID  Change pinned membership without changing hidden state
  apps hide ID                Hide without unpinning or closing windows
  apps show (ID | --all)       Clear hidden membership, preserving pins and their order
  apps move ID (--before OTHER | --after OTHER)
                               Move one pinned ID relative to another, including hidden pins

Artwork (Dockrail-only; local static PNG/SVG files referenced in place):
  icons list                  Read requested/effective mappings, not rendering success
  icons set ID PATH           Resolve a local relative path and send one host intent
  icons reset ID              Remove only this application's mapping
  icons reload ID             Refresh an existing mapping after same-path file replacement
                               Reload uses the global artwork revision; never writes config
  --profile DIR               With set/reset/reload, target one browser profile:
                               key ID@profile:DIR (DIR is the on-disk profile directory,
                               e.g. Profile 1); matches a browser-profile provider badge

Options may appear before or after the command:
  --json                       Emit one versioned JSON object on stdout
  --runtime auto|plugin|standalone
                               Select the host kind (default: auto)
  --instance ID                Exact qs ID or host process ID; never newest

Standalone lifecycle (explicit; not plugin configuration):
  launch [--daemonize] | --daemonize
  restart | stop | update | uninstall | autostart enable|disable|status

Local development (existing Omarchy plugin, no second dock):
  dev use PATH|BRANCH         Switch to a local checkout, including uncommitted edits
  dev list | status | reload | reset

Bare dockrail shows help. Unknown commands exit 2, without starting anything.
Install just this client with: bash ./install.sh --cli-only
'''


class CliError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code = code
        self.data = {} if data is None else data



FEATURE_ORDER = (
    'sidebar', 'herdrAgents', 'chromeProfilesTabs',
    'launcherCounts', 'agentLaunchers', 'cliFreshness',
)
FEATURE_LABELS = {
    'sidebar': 'Sidebar',
    'herdrAgents': 'Herdr agents',
    'chromeProfilesTabs': 'Chrome profiles/tabs',
    'launcherCounts': 'Launcher counts',
    'agentLaunchers': 'Agent launchers',
    'cliFreshness': 'CLI freshness',
}
HERDR_MIN_VERSION = (0, 9, 1)
AGENT_LAUNCHERS = (
    'smartdock-agent-pi',
    'smartdock-agent-oh-my-pi',
    'smartdock-agent-command-code',
    'smartdock-agent-cursor',
    'smartdock-agent-claude-code',
    'smartdock-agent-kilo-code',
    'smartdock-agent-cline',
    'smartdock-agent-herdr',
)
AGENT_COMMANDS = ('pi', 'omp', 'commandcode', 'cursor-agent', 'claude', 'kilo', 'cline', 'herdr')
SETUP_FEATURES = ('chrome', 'herdr', 'launcher-counts', 'agent-launchers')
LAUNCHER_COUNTS_ARCH_PREREQUISITES = 'sudo pacman -S --needed cmake gcc qt6-base'


class ReadinessProbes:
    """Read-only local facts used by doctor and future guided setup."""

    def __init__(self, environ=None, bundle=None):
        self.environ = os.environ if environ is None else environ
        self.bundle = Path(BUNDLE if bundle is None else bundle)

    def _home(self):
        return Path(self.environ.get('HOME') or Path.home())

    def _data_home(self):
        value = self.environ.get('XDG_DATA_HOME')
        return Path(value) if value else self._home() / '.local/share'

    def _config_home(self):
        value = self.environ.get('XDG_CONFIG_HOME')
        return Path(value) if value else self._home() / '.config'

    def which(self, command):
        return shutil.which(command, path=self.environ.get('PATH'))

    def herdr_version(self, executable):
        try:
            result = subprocess.run(
                [executable, '--version'], stdin=subprocess.DEVNULL,
                capture_output=True, text=True, encoding='utf-8',
                timeout=1.0, check=False)
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            return None
        output = (result.stdout + '\n' + result.stderr).strip()
        match = re.search(r'(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)', output)
        if match is None:
            return None
        return tuple(int(part) for part in match.groups())

    def _executable(self, path):
        try:
            return path.is_file() and os.access(path, os.X_OK)
        except OSError:
            return False

    def _process_for_path(self, path):
        target = os.path.realpath(str(path))
        try:
            processes = list(Path('/proc').iterdir())
        except OSError:
            return None
        for process in processes:
            if not process.name.isdigit():
                continue
            try:
                raw = (process / 'cmdline').read_bytes()
            except OSError:
                continue
            argv = [os.fsdecode(part) for part in raw.split(b'\0') if part]
            for argument in argv:
                if not os.path.isabs(argument):
                    continue
                try:
                    if os.path.realpath(argument) == target:
                        return argv
                except OSError:
                    continue
        return None

    def provider(self, kind):
        names = {
            'browser': 'smartdock-browser-profile-provider',
            'launcher': 'smartdock-launcher-badge-provider',
        }
        name = names[kind]
        data_home = self._data_home()
        candidates = (
            data_home / 'dockrail/providers' / name,
            data_home / 'smartdock/providers' / name,
        )
        path = next((candidate for candidate in candidates if self._executable(candidate)),
                    candidates[0])
        installed = self._executable(path)
        argv = self._process_for_path(path) if installed else None
        return {
            'path': str(path),
            'installed': installed,
            'running': argv is not None,
            'argv': [] if argv is None else argv,
        }

    def devtools_reachable(self, port):
        if type(port) is not int or port <= 0 or port > 65535:
            return False
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=0.5)
        try:
            connection.request(
                'GET', '/json/version', headers={'Host': '127.0.0.1:' + str(port)})
            response = connection.getresponse()
            body = response.read(65537)
            if response.status != 200 or len(body) > 65536:
                return False
            value = json.loads(body.decode('utf-8'))
            socket_url = value.get('webSocketDebuggerUrl') if isinstance(value, dict) else None
            if not isinstance(socket_url, str):
                return False
            return (socket_url.startswith('ws://127.0.0.1:' + str(port) + '/')
                    or socket_url.startswith('ws://localhost:' + str(port) + '/'))
        except (OSError, UnicodeError, ValueError, http.client.HTTPException):
            return False
        finally:
            connection.close()

    def missing_agent_launchers(self):
        data_roots = [self._data_home()]
        for entry in (self.environ.get('XDG_DATA_DIRS')
                      or '/usr/local/share:/usr/share').split(':'):
            path = Path(entry) if entry else None
            if path is not None and path not in data_roots:
                data_roots.append(path)
        missing = []
        for command, launcher in zip(AGENT_COMMANDS, AGENT_LAUNCHERS):
            if not self.which(command):
                continue
            if not any((root / 'applications' / (launcher + '.desktop')).is_file()
                       for root in data_roots):
                missing.append(launcher)
        return missing

    def _same_path(self, left, right):
        try:
            return os.path.realpath(str(left)) == os.path.realpath(str(right))
        except OSError:
            return False

    def _runtime_root(self, runtime_mode):
        if runtime_mode == 'plugin':
            candidates = [
                self._config_home() / 'omarchy/plugins/io.github.fernandodamaso.dockrail',
                self._home() / '.config/omarchy/plugins/io.github.fernandodamaso.dockrail',
            ]
            for candidate in candidates:
                if candidate.exists():
                    return candidate
            if self.bundle.name == 'io.github.fernandodamaso.dockrail':
                return self.bundle
            return candidates[0]
        if runtime_mode == 'standalone':
            return self._data_home() / 'dockrail'
        return None

    def _client_source_root(self):
        marker = self.bundle / '.source-dir'
        try:
            source = marker.read_text(encoding='utf-8').strip()
        except (OSError, UnicodeError):
            return self.bundle
        return Path(source) if source else self.bundle

    def _git_revision(self, root):
        if root is None:
            return None
        try:
            result = subprocess.run(
                ['git', '-C', str(root), 'rev-parse', 'HEAD'],
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                encoding='utf-8', timeout=0.75, check=False)
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            return None
        revision = result.stdout.strip()
        return (revision if result.returncode == 0
                and re.fullmatch(r'[0-9a-fA-F]{40,64}', revision) else None)

    def _client_fingerprint(self, root):
        if root is None:
            return None
        digest = hashlib.sha256()
        for relative in (
                'scripts/smartdock_cli.py',
                'config/settings-schema.json',
                'config/dock.json',
                'docs/AGENT_CONFIGURATION.md',
                'docs/CLI_REFERENCE.md'):
            path = Path(root) / relative
            try:
                value = path.read_bytes()
            except OSError:
                return None
            digest.update(relative.encode('utf-8'))
            digest.update(b'\0')
            digest.update(value)
            digest.update(b'\0')
        return digest.hexdigest()

    def cli_sync(self, runtime_mode):
        runtime_root = self._runtime_root(runtime_mode)
        if runtime_root is None:
            return 'unknown'
        if self._same_path(self.bundle, runtime_root):
            return 'live'
        client_source = self._client_source_root()
        client_revision = self._git_revision(client_source)
        runtime_revision = self._git_revision(runtime_root)
        if (client_revision is not None and runtime_revision is not None
                and client_revision != runtime_revision):
            return 'stale'
        client_hash = self._client_fingerprint(self.bundle)
        runtime_hash = self._client_fingerprint(runtime_root)
        if client_hash is not None and runtime_hash is not None:
            return 'match' if client_hash == runtime_hash else 'stale'
        if client_revision is not None and runtime_revision is not None:
            return 'match'
        return 'unknown'


def readiness(status, reason, next_step):
    return {'status': status, 'reason': reason, 'nextStep': next_step}


def provider_port(provider):
    argv = provider.get('argv') if isinstance(provider, dict) else None
    argv = argv if isinstance(argv, list) else []
    for index, argument in enumerate(argv):
        text = str(argument)
        value = None
        if text.startswith('--port='):
            value = text.split('=', 1)[1]
        elif text == '--port' and index + 1 < len(argv):
            value = str(argv[index + 1])
        if value is not None:
            try:
                port = int(value)
            except ValueError:
                break
            if 0 < port <= 65535:
                return port
            break
    return 9222


def feature_readiness(status_data, settings, probes=None):
    """Return stable optional-feature readiness without changing machine state."""
    probes = ReadinessProbes() if probes is None else probes
    status_data = status_data if isinstance(status_data, dict) else {}
    settings = settings if isinstance(settings, dict) else {}
    presentation = status_data.get('presentation')
    presentation = presentation if isinstance(presentation, dict) else {}
    features = {}

    monitors = presentation.get('perMonitor')
    if not isinstance(monitors, list) or not monitors:
        features['sidebar'] = readiness(
            'degraded',
            'No connected monitor is available to verify the effective presentation.',
            'Connect a display and rerun dockrail doctor.')
        sidebar_ready = False
    else:
        sidebar_monitors = [
            str(row.get('connector')) for row in monitors
            if isinstance(row, dict) and row.get('mode') == 'sidebar'
        ]
        if sidebar_monitors:
            features['sidebar'] = readiness(
                'ready',
                'Sidebar is effective on: ' + ', '.join(sidebar_monitors) + '.',
                'No action needed.')
            sidebar_ready = True
        else:
            features['sidebar'] = readiness(
                'missing',
                'No connected monitor currently resolves to Sidebar.',
                'Switch one connected output to Sidebar, then rerun dockrail doctor.')
            sidebar_ready = False

    herdr_path = probes.which('herdr')
    sidebar_widgets = settings.get('sidebarWidgets')
    sidebar_widgets = sidebar_widgets if isinstance(sidebar_widgets, list) else []
    widget_enabled = 'herdr.agents' in sidebar_widgets
    widgets = presentation.get('widgets')
    rows = widgets.get('rows') if isinstance(widgets, dict) else None
    rows = rows if isinstance(rows, list) else []
    herdr_row = next((row for row in rows
                      if isinstance(row, dict) and row.get('id') == 'herdr.agents'), None)
    lease_active = isinstance(herdr_row, dict) and herdr_row.get('active') is True
    herdr_detected_version = probes.herdr_version(herdr_path) if herdr_path else None
    if not herdr_path:
        features['herdrAgents'] = readiness(
            'missing',
            'Herdr is not available on PATH.',
            'Install Herdr 0.9.1 or newer, then rerun dockrail doctor.')
    else:
        version = herdr_detected_version
        if version is None:
            features['herdrAgents'] = readiness(
                'degraded',
                'Herdr is installed, but its version could not be verified.',
                'Verify that herdr --version works, then rerun dockrail doctor.')
        elif version < HERDR_MIN_VERSION:
            features['herdrAgents'] = readiness(
                'degraded',
                'Herdr ' + '.'.join(map(str, version))
                + ' is installed; click-to-focus requires Herdr 0.9.1 or newer.',
                'Upgrade Herdr to 0.9.1 or newer.')
        elif not widget_enabled:
            features['herdrAgents'] = readiness(
                'missing',
                'Herdr is compatible, but herdr.agents is not enabled in sidebarWidgets.',
                'Enable herdr.agents while preserving the current sidebarWidgets order.')
        elif not lease_active:
            features['herdrAgents'] = readiness(
                'degraded',
                'herdr.agents is enabled, but its current provider lease is not active.',
                ('Switch a connected output to Sidebar so herdr.agents can activate.'
                 if not sidebar_ready else
                 'Show the configured Sidebar and rerun dockrail doctor.'))
        else:
            features['herdrAgents'] = readiness(
                'ready',
                'Herdr is compatible, herdr.agents is enabled, and its provider lease is active.',
                'No action needed.')

    browser_provider = probes.provider('browser')
    badges_enabled = settings.get('browserProfileBadgesEnabled') is True
    tabs_enabled = settings.get('sidebarBrowserTabsEnabled') is True
    chrome_probe_reachable = None
    if not browser_provider.get('installed'):
        features['chromeProfilesTabs'] = readiness(
            'missing',
            'The Dockrail Chrome profile provider is not installed.',
            'Install the Dockrail Chrome profile provider, then rerun dockrail doctor.')
    elif not badges_enabled and not tabs_enabled:
        features['chromeProfilesTabs'] = readiness(
            'missing',
            'Chrome profile badges and sidebar browser tabs are both disabled.',
            'Enable browserProfileBadgesEnabled or sidebarBrowserTabsEnabled.')
    elif not browser_provider.get('running'):
        features['chromeProfilesTabs'] = readiness(
            'degraded',
            'The Chrome profile provider is installed but is not running.',
            'Reload the running Dockrail host so the installed Chrome provider can start.')
    else:
        port = provider_port(browser_provider)
        chrome_probe_reachable = probes.devtools_reachable(port)
        if not chrome_probe_reachable:
            features['chromeProfilesTabs'] = readiness(
                'degraded',
                'Chrome DevTools is not reachable on localhost:' + str(port) + '.',
                'Launch Chrome with --remote-debugging-port=' + str(port)
                + ' and a separate --user-data-dir. Follow docs/browser-activity.md '
                + 'for profile setup and the local-access security note, then rerun dockrail doctor.')
        else:
            enabled = []
            if badges_enabled:
                enabled.append('profile badges')
            if tabs_enabled:
                enabled.append('sidebar tabs')
            features['chromeProfilesTabs'] = readiness(
                'ready',
                'Chrome provider and localhost DevTools are reachable; enabled: '
                + ', '.join(enabled) + '.',
                'No action needed.')

    launcher_provider = probes.provider('launcher')
    if launcher_provider.get('installed'):
        features['launcherCounts'] = readiness(
            'ready',
            'The Dockrail launcher-count provider binary is installed.',
            'No action needed.')
    else:
        features['launcherCounts'] = readiness(
            'missing',
            'The Dockrail launcher-count provider binary is not installed.',
            'Install the Dockrail launcher-count provider, then rerun dockrail doctor.')

    missing_launchers = probes.missing_agent_launchers()
    if missing_launchers:
        features['agentLaunchers'] = readiness(
            'missing',
            str(len(missing_launchers)) + ' terminal-agent launcher(s) are missing: '
            + ', '.join(missing_launchers) + '.',
            'Install Dockrail terminal-agent launchers, then rerun dockrail doctor.')
    else:
        features['agentLaunchers'] = readiness(
            'ready',
            'All detected terminal agents have Dockrail desktop entries.',
            'No action needed.')

    runtime = status_data.get('runtime')
    runtime_mode = runtime.get('mode') if isinstance(runtime, dict) else None
    sync = probes.cli_sync(runtime_mode)
    if sync == 'live':
        features['cliFreshness'] = readiness(
            'ready',
            'The CLI reads directly from the running Dockrail installation.',
            'No action needed.')
    elif sync == 'match':
        features['cliFreshness'] = readiness(
            'ready',
            'The CLI source revision/client surface matches the running Dockrail installation.',
            'No action needed.')
    elif sync == 'stale':
        features['cliFreshness'] = readiness(
            'degraded',
            'The CLI source revision/client surface differs from the running Dockrail installation.',
            'Reinstall the CLI from the running Dockrail installation, then rerun doctor.')
    else:
        features['cliFreshness'] = readiness(
            'degraded',
            'CLI freshness could not be compared with the running Dockrail installation.',
            'Install the CLI from the running Dockrail installation, then rerun doctor.')

    # Add orthogonal Settings dimensions without replacing the stable doctor
    # status/reason/nextStep contract. A disabled feature does not mean that the
    # integration binary or Chrome's endpoint disappeared.
    def enrich(feature, configuration, installation, runtime, action, text):
        value = features[feature]
        value['configuration'] = configuration
        value['installation'] = installation
        value['runtime'] = runtime
        value['nextAction'] = {'kind': action, 'text': text}

    def pair_state(left, right):
        return 'on' if left and right else 'off' if not left and not right else 'partly-on'

    herdr_version = herdr_detected_version
    herdr_installed = bool(herdr_path)
    herdr_compatible = herdr_installed and herdr_version is not None and herdr_version >= HERDR_MIN_VERSION
    herdr_config = pair_state(widget_enabled, settings.get('dockHerdrIndicators') is True)
    herdr_runtime = ('unavailable' if not herdr_installed else
                     'ready' if herdr_compatible and lease_active else 'limited')
    enrich('herdrAgents', herdr_config, 'installed' if herdr_installed else 'missing',
           herdr_runtime,
           'install' if not herdr_installed else
           'configure' if not herdr_compatible else
           'enable' if herdr_config != 'on' else 'learn-more',
           features['herdrAgents']['nextStep'])

    chrome_config = pair_state(badges_enabled, tabs_enabled)
    chrome_installed = bool(browser_provider.get('installed'))
    chrome_running = chrome_installed and bool(browser_provider.get('running'))
    chrome_reachable = chrome_running and (chrome_probe_reachable if chrome_probe_reachable is not None
                                           else probes.devtools_reachable(provider_port(browser_provider)))
    enrich('chromeProfilesTabs', chrome_config, 'installed' if chrome_installed else 'missing',
           'ready' if chrome_reachable else 'limited' if chrome_installed else 'unavailable',
           'install' if not chrome_installed else
           'configure' if not chrome_reachable else
           'enable' if chrome_config != 'on' else 'learn-more',
           features['chromeProfilesTabs']['nextStep'])

    counts_installed = bool(launcher_provider.get('installed'))
    enrich('launcherCounts',
           'off' if settings.get('launcherBadgeMode') == 'dots-only' else 'on',
           'installed' if counts_installed else 'missing',
           'ready' if counts_installed else 'unavailable',
           'install' if not counts_installed else 'learn-more',
           features['launcherCounts']['nextStep'])
    # One read-only inventory for the Features agent list. Reuse the same PATH
    # and missing-launcher probes as doctor; QML must not inspect the OS.
    agent_labels = {
        'claude': 'Claude Code', 'pi': 'Pi', 'cursor-agent': 'Cursor Agent',
        'herdr': 'Herdr', 'omp': 'Oh My Pi', 'commandcode': 'Command Code',
        'kilo': 'Kilo Code', 'cline': 'Cline',
    }
    agent_rows = []
    for command, launcher in zip(AGENT_COMMANDS, AGENT_LAUNCHERS):
        found = bool(probes.which(command))
        agent_rows.append({
            'label': agent_labels[command], 'command': command,
            'found': found,
            'launcherInstalled': found and launcher not in missing_launchers,
        })
    # Show the frozen design's eight-agent order, independent of PATH order.
    agent_order = ['claude', 'pi', 'cursor-agent', 'herdr',
                   'omp', 'commandcode', 'kilo', 'cline']
    agent_rows.sort(key=lambda row: agent_order.index(row['command']))

    # Installation is checked for detected agents only; runtime remains independent.
    launchers_installed = not missing_launchers
    enrich('agentLaunchers', 'on' if launchers_installed else 'off',
           'installed' if launchers_installed else 'missing',
           'ready' if launchers_installed else 'unavailable',
           'install' if not launchers_installed else 'learn-more',
           features['agentLaunchers']['nextStep'])
    features['agentLaunchers']['agents'] = agent_rows

    for key in ('sidebar', 'cliFreshness'):
        legacy = features[key]
        good = legacy['status'] == 'ready'
        enrich(key, 'on', 'installed', 'ready' if good else 'limited',
               'learn-more', legacy['nextStep'])
    return {key: features[key] for key in FEATURE_ORDER}


def format_doctor(data):
    runtime = data.get('runtime') if isinstance(data, dict) else {}
    checks = data.get('checks') if isinstance(data, dict) else {}
    features = data.get('features') if isinstance(data, dict) else {}
    lines = ['Dockrail doctor']
    if isinstance(runtime, dict):
        lines.append('Runtime: ' + str(runtime.get('mode', 'unknown'))
                     + ' (' + str(runtime.get('instanceId', 'unknown')) + ')')
    lines.append('Core checks:')
    if isinstance(checks, dict):
        for name in ('python', 'quickshell', 'omarchyShell', 'liveRuntime'):
            lines.append('  ' + name + ': ' + ('ready' if checks.get(name) is True else 'missing'))
    lines.append('Feature readiness:')
    for key in FEATURE_ORDER:
        item = features.get(key) if isinstance(features, dict) else None
        if not isinstance(item, dict):
            continue
        lines.append('  ' + FEATURE_LABELS[key] + ': ' + str(item.get('status', 'degraded')))
        lines.append('    Reason: ' + str(item.get('reason', 'Unknown.')))
        lines.append('    Next: ' + str(item.get('nextStep', 'Rerun dockrail doctor.')))
    return '\n'.join(lines)


class SetupActions:
    """Explicit local install actions used only after setup has a selected host."""

    def __init__(self, runtime_mode, probes=None, environ=None):
        self.probes = ReadinessProbes(environ=environ) if probes is None else probes
        self.environ = os.environ if environ is None else environ
        root = self.probes._runtime_root(runtime_mode)
        self.root = Path(BUNDLE if root is None else root)

    def _run_script(self, relative, arguments, label):
        script = self.root / relative
        if not script.is_file():
            raise CliError(
                'E_SETUP',
                label + ' installer is unavailable in the selected running Dockrail tree: '
                + str(script))
        try:
            completed = subprocess.run(
                ['bash', str(script), *arguments],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding='utf-8',
                env=self.environ,
                timeout=120,
                check=False)
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            raise CliError('E_SETUP', label + ' installer could not run: ' + str(error)) from error
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            if len(detail) > 600:
                detail = detail[:600] + '...'
            suffix = '' if not detail else ': ' + detail
            raise CliError('E_SETUP', label + ' installer failed' + suffix)
        return {
            'script': str(script),
            'stdout': completed.stdout.strip(),
            'stderr': completed.stderr.strip(),
        }

    def install_browser_provider(self):
        return self._run_script(
            'scripts/install-browser-profile-provider', [], 'Chrome profile provider')

    def install_agent_launchers(self):
        return self._run_script(
            'install.sh', ['--agent-assets-only'], 'Terminal-agent launcher')

    def launcher_counts_command(self):
        return 'bash ' + shlex.quote(str(self.root / 'scripts/build-launcher-badge-provider'))


def setup_require_ok(reply):
    if not reply['ok']:
        error = reply['error']
        raise CliError(error['code'], error['message'], reply.get('data') or {})
    return reply


def setup_status(transport, instance, reply=None):
    reply = setup_require_ok(
        transport.request(instance, 'status') if reply is None else reply)
    validate_status(reply, instance)
    data = reply['data']
    if data['loadState'] == 'invalid':
        raise CliError('E_CONFIG_INVALID', data['loadError'], data)
    if data['writeState'] == 'error':
        raise CliError('E_PERSISTENCE', data['writeError'], data)
    return reply


def setup_requested_settings(transport, instance):
    reply = validate_read(
        transport.request(instance, 'config.get', {'effective': False}), 'get')
    setup_require_ok(reply)
    return reply['data']['settings']


def setup_snapshot(transport, instance, checks, probes, status_reply=None):
    status = setup_status(transport, instance, status_reply)
    settings = setup_requested_settings(transport, instance)
    data = dict(status['data'])
    data['checks'] = dict(checks, liveRuntime=True)
    data['features'] = feature_readiness(data, settings, probes)
    return data, settings


def setup_apply_patch(transport, instance, patch):
    """Dry-run one minimal host patch, apply it once, then read it back."""
    dry = validate_mutation(
        transport.request(instance, 'config.apply', {'patch': patch, 'dryRun': True}),
        instance)
    setup_require_ok(dry)
    if dry['data'].get('applied') is not False:
        raise CliError('E_PROTOCOL', 'Setup dry-run unexpectedly reported an applied mutation.')

    actual = None
    if not dry['data']['noop']:
        actual = validate_mutation(
            transport.request(instance, 'config.apply', {'patch': patch, 'dryRun': False}),
            instance)
        setup_require_ok(actual)
        mutation = actual['data']
        if not mutation['noop'] and mutation['applied'] is not True:
            raise CliError('E_PROTOCOL', 'Setup apply did not acknowledge the requested mutation.')
        if mutation['applied'] and mutation['persisted'] is not True:
            raise CliError(
                'E_PERSISTENCE',
                'Setup was applied live but was not confirmed persisted.',
                mutation)

    settings = setup_requested_settings(transport, instance)
    for key, expected in patch.items():
        if key not in settings or settings[key] != expected:
            raise CliError(
                'E_PROTOCOL',
                'Setup readback did not match the requested value for ' + key + '.')
    status = setup_status(transport, instance)
    if (actual is not None and actual['data']['applied']
            and (status['data']['writeState'] != 'saved'
                 or status['data']['persisted'] is not True)):
        raise CliError(
            'E_PERSISTENCE',
            'Setup write was not durably confirmed by host readback.',
            status['data'])
    return {
        'changed': not dry['data']['noop'],
        'applied': False if actual is None else actual['data']['applied'],
        'persisted': status['data']['persisted'],
        'settings': settings,
    }


def format_feature_readiness(features):
    lines = ['Feature readiness:']
    for key in FEATURE_ORDER:
        item = features.get(key) if isinstance(features, dict) else None
        if not isinstance(item, dict):
            continue
        lines.append('  ' + FEATURE_LABELS[key] + ': ' + str(item.get('status', 'degraded')))
        lines.append('    ' + str(item.get('reason', 'Unknown.')))
        lines.append('    Next: ' + str(item.get('nextStep', 'Rerun dockrail doctor.')))
    return '\n'.join(lines)


def setup_prompt(input_fn, prompt):
    try:
        answer = input_fn(prompt)
    except (EOFError, KeyboardInterrupt):
        return False
    return str(answer).strip().lower() in ('y', 'yes')


def setup_choose_monitor(status_data, input_fn):
    presentation = status_data.get('presentation')
    rows = presentation.get('perMonitor') if isinstance(presentation, dict) else None
    rows = rows if isinstance(rows, list) else []
    connectors = []
    for row in rows:
        connector = row.get('connector') if isinstance(row, dict) else None
        if isinstance(connector, str) and connector and connector not in connectors:
            connectors.append(connector)
    if not connectors:
        return None
    if len(connectors) == 1:
        return connectors[0]
    choices = ', '.join(str(index + 1) + '=' + name
                        for index, name in enumerate(connectors))
    while True:
        try:
            answer = str(input_fn('Choose a monitor (' + choices + ', blank cancels): ')).strip()
        except (EOFError, KeyboardInterrupt):
            return None
        if not answer:
            return None
        if answer in connectors:
            return answer
        if answer.isdigit() and 1 <= int(answer) <= len(connectors):
            return connectors[int(answer) - 1]
        print('Choose one listed number or connector name.')


def setup_chrome_guidance(probes):
    flags_file = probes._config_home() / 'chrome-flags.conf'
    profile_dir = probes._home() / '.config/google-chrome-debug'
    return (
        'Add these Chrome flags yourself to ' + str(flags_file) + ':\n'
        '  --user-data-dir=' + str(profile_dir) + '\n'
        '  --remote-debugging-port=9222\n'
        'The separate user-data directory is a fresh Chrome profile; sign in and '
        'configure extensions there separately. Security: while the localhost '
        'DevTools port is open, any local process can control that Chrome profile '
        'and read its pages and cookies. Dockrail never edits chrome-flags.conf or '
        'restarts Chrome. After adding the lines, quit all Chrome windows and '
        'restart Chrome yourself.')


def setup_action(feature, status, message, mutation=None):
    value = {'feature': feature, 'status': status, 'message': message}
    if mutation is not None:
        value['mutation'] = {
            'changed': mutation['changed'],
            'applied': mutation['applied'],
            'persisted': mutation['persisted'],
        }
    return value


def launcher_counts_missing_prerequisites(probes):
    """Check the build tools without installing or starting a provider build."""
    missing = []
    if not probes.which('cmake'):
        missing.append('CMake')
    if not any(probes.which(name) for name in ('c++', 'g++', 'clang++')):
        missing.append('C++ compiler')
    return missing


def run_setup(transport, instance, initial_status, args, checks, probes=None,
              actions=None, input_fn=input, stdin_is_tty=None):
    """Run guided setup only after execute() selected a real running host."""
    # Discovery is already complete. Human prompts and installers must not
    # consume the discovery deadline; each IPC call keeps its own timeout.
    transport.deadline = None
    probes = ReadinessProbes() if probes is None else probes
    initial, settings = setup_snapshot(
        transport, instance, checks, probes, status_reply=initial_status)
    initial_features = initial['features']
    scripted = args.feature is not None
    interactive = not scripted
    tty = sys.stdin.isatty() if stdin_is_tty is None else stdin_is_tty

    if args.yes and not scripted:
        raise CliError(
            'E_USAGE',
            '--yes requires --feature. Interactive setup asks before each action.')
    if scripted and not args.yes:
        raise CliError(
            'E_USAGE',
            '--feature requires --yes. For guided prompts run dockrail setup.')
    if interactive and getattr(args, 'json', False):
        raise CliError(
            'E_USAGE',
            'Interactive setup cannot use --json. Use --feature NAME --yes --json.')
    if interactive and not tty:
        raise CliError(
            'E_USAGE',
            'dockrail setup requires a TTY. For scripts use '
            'dockrail setup --feature NAME --yes.')

    if interactive:
        print(format_feature_readiness(initial_features))

    runtime = initial.get('runtime') if isinstance(initial, dict) else {}
    runtime_mode = runtime.get('mode') if isinstance(runtime, dict) else None
    actions = SetupActions(runtime_mode, probes=probes) if actions is None else actions
    records = []
    reload_needed = False
    chrome_restart_needed = False

    if interactive and initial_features['sidebar']['status'] != 'ready':
        if setup_prompt(
                input_fn,
                'Sidebar uses one selected monitor override. Enable Sidebar on a monitor? [y/N] '):
            connector = setup_choose_monitor(initial, input_fn)
            if connector is None:
                records.append(setup_action(
                    'sidebar', 'skipped', 'No monitor was selected; no setting changed.'))
            else:
                current = setup_requested_settings(transport, instance)
                modes = current.get('presentationModeByMonitor')
                if not isinstance(modes, dict):
                    raise CliError(
                        'E_CONFIG_INVALID',
                        'presentationModeByMonitor must be repaired before guided setup.')
                updated = dict(modes)
                updated[connector] = 'sidebar'
                mutation = setup_apply_patch(
                    transport, instance, {'presentationModeByMonitor': updated})
                settings = mutation['settings']
                records.append(setup_action(
                    'sidebar',
                    'changed' if mutation['changed'] else 'unchanged',
                    'Sidebar selected for ' + connector
                    + '; all other monitor entries were preserved.',
                    mutation))
        else:
            records.append(setup_action(
                'sidebar', 'skipped', 'Sidebar was left unchanged.'))

    wants_herdr = (args.feature == 'herdr') if scripted else (
        initial_features['herdrAgents']['status'] != 'ready')
    if wants_herdr:
        if initial_features['herdrAgents']['status'] == 'ready':
            records.append(setup_action(
                'herdr', 'ready', 'Herdr agents are already ready; no change was made.'))
        else:
            herdr_path = probes.which('herdr')
            if not herdr_path:
                records.append(setup_action(
                    'herdr', 'unavailable',
                    'Herdr is not on PATH. Install Herdr 0.9.1 or newer, confirm '
                    'herdr --version works, then rerun dockrail setup --feature herdr --yes. '
                    'No setting was changed.'))
            else:
                version = probes.herdr_version(herdr_path)
                version_text = ('unknown' if version is None
                                else '.'.join(map(str, version)))
                proceed = scripted or setup_prompt(
                    input_fn,
                    'Herdr agents reads local/attached Herdr sessions. '
                    'Enable herdr.agents in sidebarWidgets? [y/N] ')
                if not proceed:
                    records.append(setup_action(
                        'herdr', 'skipped', 'Herdr widget selection was left unchanged.'))
                else:
                    current = setup_requested_settings(transport, instance)
                    widgets = current.get('sidebarWidgets')
                    if not isinstance(widgets, list):
                        raise CliError(
                            'E_CONFIG_INVALID',
                            'sidebarWidgets must be repaired before guided setup.')
                    if 'herdr.agents' in widgets:
                        mutation = None
                        changed = False
                    else:
                        updated = list(widgets)
                        updated.append('herdr.agents')
                        mutation = setup_apply_patch(
                            transport, instance, {'sidebarWidgets': updated})
                        settings = mutation['settings']
                        changed = mutation['changed']
                    warning = ''
                    if version is None:
                        warning = (
                            ' Herdr version could not be verified; run herdr --version. '
                            'Click-to-focus requires 0.9.1 or newer.')
                    elif version < HERDR_MIN_VERSION:
                        warning = (
                            ' Herdr ' + version_text
                            + ' is below 0.9.1; update Herdr to use click-to-focus.')
                    records.append(setup_action(
                        'herdr',
                        'changed' if changed else 'unchanged',
                        ('herdr.agents was appended without reordering existing widgets.'
                         if changed else
                         'herdr.agents is already present; widget order was left unchanged.')
                        + warning,
                        mutation))

    wants_chrome = (args.feature == 'chrome') if scripted else (
        initial_features['chromeProfilesTabs']['status'] != 'ready')
    if wants_chrome:
        if initial_features['chromeProfilesTabs']['status'] == 'ready':
            records.append(setup_action(
                'chrome', 'ready', 'Chrome profiles/tabs are already ready; no action ran.'))
        else:
            proceed = scripted or setup_prompt(
                input_fn,
                'Chrome profiles/tabs uses a separate debug profile and a localhost '
                'DevTools port visible to local processes. Install the Dockrail provider '
                'and show the manual Chrome flags? [y/N] ')
            if not proceed:
                records.append(setup_action(
                    'chrome', 'skipped', 'Chrome setup was left unchanged.'))
            else:
                provider = probes.provider('browser')
                installed_now = False
                if not provider.get('installed'):
                    actions.install_browser_provider()
                    installed_now = True
                    reload_needed = True
                elif not provider.get('running'):
                    reload_needed = True
                endpoint_ready = (provider.get('running') is True
                                  and probes.devtools_reachable(provider_port(provider)))
                guidance = setup_chrome_guidance(probes)
                if (settings.get('browserProfileBadgesEnabled') is not True
                        and settings.get('sidebarBrowserTabsEnabled') is not True):
                    guidance += (
                        '\nBoth Dockrail Chrome display settings are currently disabled. '
                        'Guided setup preserves that preference; enable '
                        'browserProfileBadgesEnabled or sidebarBrowserTabsEnabled explicitly '
                        'through the host writer if you want display output.')
                chrome_restart_needed = not endpoint_ready
                records.append(setup_action(
                    'chrome',
                    'installed' if installed_now else 'manual',
                    ('The browser-profile provider was installed from the selected running '
                     'Dockrail tree.\n' if installed_now else
                     'The browser-profile provider is already installed; it was not reinstalled.\n')
                    + guidance))

    wants_agents = (args.feature == 'agent-launchers') if scripted else (
        initial_features['agentLaunchers']['status'] != 'ready')
    if wants_agents:
        if initial_features['agentLaunchers']['status'] == 'ready':
            records.append(setup_action(
                'agent-launchers', 'ready',
                'Terminal-agent launchers are already installed; no action ran.'))
        else:
            proceed = scripted or setup_prompt(
                input_fn,
                'Agent launchers install Dockrail desktop entries and icons for supported '
                'terminal agents. Install them now? [y/N] ')
            if not proceed:
                records.append(setup_action(
                    'agent-launchers', 'skipped',
                    'Terminal-agent launchers were left unchanged.'))
            else:
                actions.install_agent_launchers()
                reload_needed = True
                records.append(setup_action(
                    'agent-launchers', 'installed',
                    'Terminal-agent launchers were installed from the selected running '
                    'Dockrail tree. No host configuration key was replaced.'))

    wants_counts = (args.feature == 'launcher-counts') if scripted else (
        initial_features['launcherCounts']['status'] != 'ready')
    if wants_counts:
        if initial_features['launcherCounts']['status'] == 'ready':
            records.append(setup_action(
                'launcher-counts', 'ready',
                'Launcher counts are already installed; no build ran.'))
        else:
            proceed = scripted or setup_prompt(
                input_fn,
                'Launcher counts need CMake, a C++20 compiler, and Qt 6.6+ Core/DBus. '
                'Show the manual build command? [y/N] ')
            if not proceed:
                records.append(setup_action(
                    'launcher-counts', 'skipped',
                    'Launcher-count provider was not built.'))
            else:
                missing = launcher_counts_missing_prerequisites(probes)
                if missing:
                    records.append(setup_action(
                        'launcher-counts', 'unavailable',
                        'Missing launcher-count build prerequisites: '
                        + ', '.join(missing) + '.\n'
                        'Install them on Omarchy/Arch with:\n  '
                        + LAUNCHER_COUNTS_ARCH_PREREQUISITES
                        + '\nNo provider build was started.'))
                else:
                    records.append(setup_action(
                        'launcher-counts', 'manual',
                        'Dockrail never builds launcher counts automatically. Run this yourself '
                        'after reviewing the optional build requirements:\n  '
                        + actions.launcher_counts_command()))

    final, settings = setup_snapshot(transport, instance, checks, probes)
    return envelope({
        'interactive': interactive,
        'initialFeatures': initial_features,
        'actions': records,
        'doctor': final,
        'reloadNeeded': reload_needed,
        'chromeRestartNeeded': chrome_restart_needed,
    })


def format_setup(data):
    lines = ['Dockrail setup']
    if not data.get('interactive'):
        lines.append(format_feature_readiness(data.get('initialFeatures', {})))
    lines.append('Actions:')
    actions = data.get('actions')
    if not actions:
        lines.append('  None.')
    else:
        for action in actions:
            message_lines = str(action.get('message', '')).splitlines() or ['']
            lines.append(
                '  ' + str(action.get('feature', 'setup')) + ': '
                + str(action.get('status', 'unknown')) + ' - ' + message_lines[0])
            for extra in message_lines[1:]:
                lines.append('    ' + extra)
    lines.append('')
    lines.append('Final doctor summary:')
    lines.append(format_doctor(data.get('doctor', {})))
    if data.get('reloadNeeded'):
        lines.append('Next: run omarchy restart shell once to load newly installed Dockrail assets.')
    else:
        lines.append('No Dockrail shell reload is required by the actions that ran.')
    if data.get('chromeRestartNeeded'):
        lines.append(
            'Chrome: after adding the printed flags yourself, quit all Chrome windows '
            'and restart Chrome yourself.')
    return '\n'.join(lines)


def envelope(data, warnings=None):
    return {'apiVersion': 1, 'ok': True, 'data': data,
            'warnings': [] if warnings is None else warnings}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError('Non-finite JSON number: ' + text)
    return value


def decode_json(text, origin, code='E_PROTOCOL'):
    try:
        value = json.loads(text, object_pairs_hook=unique_object, parse_float=finite_float,
                           parse_constant=lambda token: (_ for _ in ()).throw(
                               ValueError('Non-finite JSON number: ' + token)))
        # Ensure escaped unpaired surrogates cannot later break clean UTF-8 IPC/output.
        json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8')
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise CliError(code, origin + ' did not contain valid JSON: ' + str(error)) from error


def validate_response(text):
    reply = decode_json(text, 'Dockrail IPC')
    if (not isinstance(reply, dict) or type(reply.get('apiVersion')) is not int
            or reply['apiVersion'] != 1 or type(reply.get('ok')) is not bool
            or not isinstance(reply.get('data'), dict)
            or not isinstance(reply.get('warnings'), list)):
        raise CliError('E_PROTOCOL', 'Expected a Dockrail apiVersion=1 response envelope.')
    if not reply['ok']:
        error = reply.get('error')
        if (not isinstance(error, dict) or error.get('code') not in EXIT_CODES
                or not isinstance(error.get('message'), str)):
            raise CliError('E_PROTOCOL', 'Dockrail returned an invalid error envelope.')
    return reply


def validate_status(reply, instance):
    data = reply['data']
    runtime = data.get('runtime')
    if (not isinstance(runtime, dict) or runtime.get('mode') not in ('plugin', 'standalone')
            or runtime.get('instanceId') != str(instance['pid'])
            or not isinstance(data.get('configPath'), str) or not data['configPath']
            or data.get('loadState') not in ('missing', 'loaded', 'invalid')
            or data.get('writeState') not in ('idle', 'saving', 'saved', 'error')
            or not isinstance(data.get('loadError'), str)
            or not isinstance(data.get('writeError'), str)
            or type(data.get('revision')) is not int or data['revision'] < 0
            or type(data.get('persisted')) is not bool
            or type(data.get('defaultsInUse')) is not bool):
        raise CliError('E_PROTOCOL', 'Host status is incomplete or does not match the selected process.')
    runtime['quickshellId'] = instance['id']


def validate_read(reply, action, key=None):
    if reply['ok']:
        data = reply['data']
        if (not isinstance(data.get('settings'), dict)
                or (key is not None and set(data['settings']) != {key})):
            raise CliError('E_PROTOCOL', 'Expected a keyed settings object from the selected host.')
        if action == 'schema' and (type(data.get('schemaVersion')) is not int
                                   or data['schemaVersion'] != 1
                                   or not isinstance(data.get('commands'), list)):
            raise CliError('E_PROTOCOL', 'Expected versioned schema and command metadata.')
    return reply


def validate_mutation(reply, instance):
    if reply['ok']:
        validate_status(reply, instance)
        data = reply['data']
        if (type(data.get('applied')) is not bool or type(data.get('noop')) is not bool
                or not isinstance(data.get('changedKeys'), list)
                or any(not isinstance(key, str) for key in data['changedKeys'])
                or not isinstance(data.get('requested'), dict)
                or not isinstance(data.get('effective'), dict)
                or data['writeState'] in ('saving', 'error') and not data.get('dryRun')
                or data['applied'] and not data['persisted']):
            raise CliError('E_PROTOCOL', 'Mutation response is incomplete or claims success before saving.')
    return reply


def validate_applications(reply, instance):
    if not reply['ok']:
        return reply
    validate_status(reply, instance)
    rows = reply['data'].get('applications')
    if not isinstance(rows, list):
        raise CliError('E_PROTOCOL', 'Expected application rows from the selected host.')
    for row in rows:
        if (not isinstance(row, dict) or not isinstance(row.get('id'), str) or not row['id']
                or not isinstance(row.get('name'), str)
                or any(type(row.get(key)) is not bool for key in ('available', 'pinned', 'hidden'))
                or 'pinnedIndex' not in row
                or (row['pinned'] and (type(row['pinnedIndex']) is not int or row['pinnedIndex'] < 0))
                or (not row['pinned'] and row['pinnedIndex'] is not None)):
            raise CliError('E_PROTOCOL', 'Application identity or membership fields are incomplete.')
    return reply


def validate_icons(reply, instance, action):
    if not reply['ok']:
        return reply
    if action == 'list':
        validate_status(reply, instance)
        if not isinstance(reply['data'].get('overrides'), dict):
            raise CliError('E_PROTOCOL', 'Expected the configured icon override map.')
    else:
        validate_mutation(reply, instance)
        if type(reply['data'].get('reloaded')) is not bool:
            raise CliError('E_PROTOCOL', 'Missing icon reload acknowledgement.')
    data = reply['data']
    if (data.get('renderVerified') is not False
            or type(data.get('iconReloadRevision')) is not int or data['iconReloadRevision'] < 0):
        raise CliError('E_PROTOCOL', 'Icon acknowledgement cannot establish rendering success.')
    return reply


class Transport:
    """Bounded argv transport using upstream qs list JSON and explicit PID IPC.

    Omarchy's omarchy-shell wrapper selects the newest config instance. It cannot
    express --instance, so use qs's supported --pid selector for both host kinds.
    A single deadline bounds discovery even when several unrelated shells run.
    """
    def __init__(self, timeout=2.0, deadline=8.0):
        self.timeout = timeout
        self.deadline = time.monotonic() + deadline

    def run(self, argv):
        timeout = (self.timeout if self.deadline is None
                   else min(self.timeout, self.deadline - time.monotonic()))
        if timeout <= 0:
            raise CliError('E_TIMEOUT', 'Discovery deadline exceeded. Read status before retrying.',
                           {'applied': None, 'persisted': None})
        try:
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                                    text=True, encoding='utf-8', timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise CliError('E_TIMEOUT', 'IPC timed out; outcome is unknown. Read status before retrying.',
                           {'applied': None, 'persisted': None}) from error
        except FileNotFoundError as error:
            raise CliError('E_RUNTIME_NOT_FOUND', 'qs is unavailable. Install Quickshell and enable the plugin explicitly.') from error
        except UnicodeError as error:
            raise CliError('E_PROTOCOL', 'qs returned invalid UTF-8.') from error
        except OSError as error:
            raise CliError('E_TRANSPORT', 'Could not execute qs: ' + str(error)) from error
        if result.stderr.strip():
            print(result.stderr.rstrip(), file=sys.stderr)
        if len(result.stdout.encode('utf-8')) > 1024 * 1024:
            raise CliError('E_PROTOCOL', 'qs response exceeds the 1 MiB response limit.')
        if result.returncode != 0:
            raise CliError('E_TRANSPORT', 'qs exited with status ' + str(result.returncode)
                           + '. Check the selected instance and installed qs CLI compatibility.',
                           {'applied': None, 'persisted': None})
        return result.stdout.strip()

    def instances(self):
        text = self.run(['qs', 'list', '--all', '--json'])
        if text in ('', 'No running instances.'):
            return []
        values = decode_json(text, 'qs list --all --json')
        if not isinstance(values, list):
            raise CliError('E_PROTOCOL', 'qs list must return an array.')
        ids, pids = set(), set()
        for item in values:
            if (not isinstance(item, dict) or not isinstance(item.get('id'), str)
                    or not item['id'] or type(item.get('pid')) is not int or item['pid'] <= 0
                    or not isinstance(item.get('config_path'), str)
                    or item['id'] in ids or item['pid'] in pids):
                raise CliError('E_PROTOCOL', 'qs list contains an invalid or duplicate instance.')
            ids.add(item['id'])
            pids.add(item['pid'])
        return values

    def request(self, instance, command, arguments=None, probe=False):
        try:
            payload = json.dumps({'apiVersion': 1, 'command': command,
                                  'arguments': {} if arguments is None else arguments},
                                 ensure_ascii=False, allow_nan=False, separators=(',', ':'))
            size = len(payload.encode('utf-8'))
        except (ValueError, UnicodeError, RecursionError) as error:
            raise CliError('E_VALIDATION', 'Request is not finite UTF-8 JSON: ' + str(error)) from error
        if size > 65536:
            raise CliError('E_VALIDATION', 'Request exceeds the 64 KiB IPC request limit.')
        text = self.run(['qs', 'ipc', '--pid', str(instance['pid']), 'call', '--',
                         'smartdock', 'request', payload])
        if probe and text == 'Target not found.':
            return None
        return validate_response(text)

    def select(self, runtime='auto', instance_id=None):
        instances = self.instances()
        if instance_id is not None:
            instances = [item for item in instances if instance_id in (item['id'], str(item['pid']))]
        candidates = []
        for item in instances:
            reply = self.request(item, 'status', probe=True)
            if reply is None:
                continue
            if not reply['ok']:
                raise CliError(reply['error']['code'], reply['error']['message'], reply['data'])
            validate_status(reply, item)
            if runtime == 'auto' or reply['data']['runtime']['mode'] == runtime:
                candidates.append((item, reply))
        if not candidates:
            raise CliError('E_RUNTIME_NOT_FOUND',
                           'No matching Dockrail host. Enable the plugin explicitly or select the correct --runtime/--instance.')
        if len(candidates) != 1:
            raise CliError('E_RUNTIME_AMBIGUOUS', 'More than one Dockrail host. Repeat with an exact --instance ID.',
                           {'candidates': [reply['data']['runtime'] for _, reply in candidates]})
        return candidates[0]


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise CliError('E_USAGE', message + '. Run dockrail help.')


def add_globals(parser):
    parser.add_argument('--json', action='store_true', default=argparse.SUPPRESS)
    parser.add_argument('--runtime', choices=('auto', 'plugin', 'standalone'), default=argparse.SUPPRESS)
    parser.add_argument('--instance', default=argparse.SUPPRESS)
    parser.add_argument('-h', '--help', dest='help_requested', action='store_true', default=argparse.SUPPRESS)


def child_parser(commands, name):
    child = commands.add_parser(name, add_help=False, allow_abbrev=False)
    add_globals(child)
    return child


def build_parser():
    parser = Parser(prog='dockrail', add_help=False, allow_abbrev=False)
    add_globals(parser)
    commands = parser.add_subparsers(dest='group')
    for name in ('help', 'agent-guide', 'status', 'doctor', 'settings'):
        child_parser(commands, name)
    mode = child_parser(commands, 'mode').add_subparsers(dest='action')
    child_parser(mode, 'toggle')
    launchers = child_parser(commands, 'launchers').add_subparsers(dest='action')
    child_parser(launchers, 'add')
    child_parser(launchers, 'remove')
    setup = child_parser(commands, 'setup')
    setup.add_argument('--feature', choices=SETUP_FEATURES)
    setup.add_argument('--yes', action='store_true')
    config = child_parser(commands, 'config')
    actions = config.add_subparsers(dest='action')
    for name in ('schema', 'get', 'reset'):
        child = child_parser(actions, name)
        child.add_argument('key', nargs='?')
        if name == 'get':
            child.add_argument('--effective', action='store_true')
        if name == 'reset':
            child.add_argument('--preferences', action='store_true')
    child = child_parser(actions, 'set')
    child.add_argument('key')
    child.add_argument('value')
    child = child_parser(actions, 'apply')
    sources = child.add_mutually_exclusive_group(required=True)
    sources.add_argument('--stdin', action='store_true')
    sources.add_argument('--file')
    child.add_argument('--dry-run', action='store_true')
    child_parser(actions, 'retry')
    child = child_parser(actions, 'export')
    child.add_argument('--output', required=True)
    apps = child_parser(commands, 'apps').add_subparsers(dest='action')
    listing = child_parser(apps, 'list')
    filters = listing.add_mutually_exclusive_group()
    filters.add_argument('--query')
    filters.add_argument('--pinned', action='store_true')
    filters.add_argument('--hidden', action='store_true')
    for name in ('pin', 'unpin', 'hide', 'show', 'move'):
        child = child_parser(apps, name)
        child.add_argument('id', nargs='?' if name == 'show' else None)
        if name == 'show':
            child.add_argument('--all', action='store_true')
        if name == 'move':
            placement = child.add_mutually_exclusive_group(required=True)
            placement.add_argument('--before')
            placement.add_argument('--after')
    icons = child_parser(commands, 'icons').add_subparsers(dest='action')
    child_parser(icons, 'list')
    for name in ('set', 'reset', 'reload'):
        child = child_parser(icons, name)
        child.add_argument('id')
        if name == 'set':
            child.add_argument('source')
        selector = child.add_mutually_exclusive_group()
        selector.add_argument('--profile',
                              help='Target one browser profile: "ID@profile:DIR" key '
                                   '(DIR is the on-disk profile directory, e.g. "Profile 1")')
        if name in ('set', 'reset'):
            selector.add_argument('--title-pattern',
                                  help='Target raw Wayland app ID + title wildcard rule; only * is special')
    return parser


def bundled_schema(key=None):
    try:
        metadata = json.loads((BUNDLE / 'config/settings-schema.json').read_text(encoding='utf-8'))
        defaults = json.loads((BUNDLE / 'config/dock.json').read_text(encoding='utf-8'))
        settings = metadata['settings']
        if metadata['schemaVersion'] != 1 or set(settings) != set(defaults):
            raise ValueError('Schema/default key mismatch')
        if key is not None and key not in settings:
            raise CliError('E_VALIDATION', 'Unknown setting: ' + key)
        selected = settings if key is None else {key: settings[key]}
        return envelope({'source': 'bundled', 'schemaVersion': 1, 'commands': metadata['commands'],
                         'settings': {name: dict(spec, default=defaults[name]) for name, spec in selected.items()}},
                        ['Bundled metadata only; this is not the running configuration.'])
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise CliError('E_PROTOCOL', 'Bundled schema is unavailable or inconsistent: ' + str(error)) from error


def scalar_value(text, spec):
    kind = spec.get('type') if isinstance(spec, dict) else None
    if kind == 'string':
        return text
    if kind not in ('boolean', 'integer', 'number', 'array', 'object'):
        raise CliError('E_PROTOCOL', 'Live schema returned an unsupported value type.')
    value = decode_json(text, 'Setting value', 'E_VALIDATION')
    numeric = type(value) in (int, float)
    try:
        numeric = numeric and math.isfinite(value)
    except OverflowError:
        numeric = False
    valid = (kind == 'boolean' and type(value) is bool
             or kind in ('integer', 'number') and numeric
             or kind == 'array' and isinstance(value, list)
             or kind == 'object' and isinstance(value, dict))
    if not valid:
        raise CliError('E_VALIDATION', 'Value must have the declared type: ' + kind)
    if kind == 'array' and spec.get('format') == 'sidebar-widget-ids':
        registered = spec.get('registeredIds')
        if not isinstance(registered, list) or any(type(item) is not str for item in registered):
            raise CliError('E_PROTOCOL', 'Live schema did not provide the internal widget registry.')
        seen = set()
        for item in value:
            if type(item) is not str or item not in registered or item in seen:
                raise CliError('E_VALIDATION', 'Widget IDs must be registered, unique strings.')
            seen.add(item)
        # Authentication/readiness is deliberately not a validation prerequisite.
        # The host repeats authoritative validation, including config.apply.
    return value


def read_patch(args):
    try:
        if args.stdin:
            raw = sys.stdin.buffer.read(65537)
        else:
            with open(args.file, 'rb') as source:
                raw = source.read(65537)
        if len(raw) > 65536:
            raise CliError('E_VALIDATION', 'Patch exceeds the 64 KiB input limit.')
        return decode_json(raw.decode('utf-8'), 'Patch input', 'E_VALIDATION')
    except (OSError, UnicodeError) as error:
        raise CliError('E_VALIDATION', 'Cannot read the explicit UTF-8 patch input: ' + str(error)) from error


def export_snapshot(reply, output):
    """Create an owner-only NEW file. Never replace a target, including on error."""
    data = reply['data']
    fd = None
    owned_stat = None
    destination = None
    try:
        source_text = data.get('configPath')
        if not output or not isinstance(source_text, str) or not Path(source_text).is_absolute():
            raise CliError('E_EXPORT', 'Export requires an output path and an absolute authoritative host config path.')
        destination = Path(os.path.abspath(os.path.expanduser(output)))
        live = Path(source_text)
        # Resolving parents also protects a nonexistent live target through a
        # directory-symlink alias. O_EXCL is the final no-overwrite protection.
        if destination.resolve() == live.resolve():
            raise CliError('E_EXPORT', 'Refusing to export onto the live configuration or an alias of it.')
        if os.path.lexists(destination):
            raise CliError('E_EXPORT', 'Export destination already exists (files and symlinks are never overwritten).')
        text = json.dumps(data['settings'], ensure_ascii=False, allow_nan=False, indent=2) + '\n'
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        owned_stat = os.fstat(fd)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            fd = None
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
    except (OSError, ValueError, KeyError, RuntimeError, CliError) as error:
        if fd is not None:
            os.close(fd)
        if owned_stat is not None:
            try:
                current = destination.lstat()
                if (current.st_dev, current.st_ino) == (owned_stat.st_dev, owned_stat.st_ino):
                    destination.unlink()
            except OSError:
                pass
        if isinstance(error, CliError):
            raise
        raise CliError('E_EXPORT', 'Snapshot could not be written: ' + str(error)) from error
    return envelope({'exportWritten': True, 'exportPath': str(destination),
                     'sourcePersisted': data['persisted'], 'sourceRevision': data['revision'],
                     'sourceRuntime': data['runtime'], 'configPath': data['configPath'], 'applied': False},
                    reply['warnings'])


def app_icon_request(transport, instance, args):
    """Send a primitive intent. The host owns IDs, validation and latest-state edits."""
    arguments = {}
    if args.group == 'apps' and args.action == 'list':
        for key in ('query', 'pinned', 'hidden'):
            value = getattr(args, key)
            if value is not None and value is not False:
                arguments[key] = value
    elif args.action != 'list':
        if args.group == 'apps' and args.action == 'show' and args.all:
            arguments['all'] = True
        else:
            arguments['id'] = args.id
        if args.group == 'apps' and args.action == 'move':
            key = 'before' if args.before is not None else 'after'
            arguments[key] = getattr(args, key)
        if args.group == 'icons':
            title_pattern = getattr(args, 'title_pattern', None)
            if title_pattern is not None:
                arguments['titlePattern'] = title_pattern
            profile = getattr(args, 'profile', None)
            if profile is not None:
                profile = str(profile).strip()
                if (not profile or re.search(r'[\x00-\x1f\x7f/\\@]', profile)
                        or '@profile:' in arguments['id']):
                    raise CliError('E_VALIDATION',
                                   'Profile must be a non-empty directory name without '
                                   'path separators, control characters or "@profile:".')
                arguments['id'] = arguments['id'] + '@profile:' + profile
        if args.group == 'icons' and args.action == 'set':
            source = args.source
            if not source:
                raise CliError('E_VALIDATION', 'Select a local PNG or SVG file.')
            # URL acceptance belongs to DockIconModel. Preserve schemes as-is,
            # including unsupported ones, so they cannot become local filenames.
            if not re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', source):
                try:
                    source = os.path.abspath(source)
                except (OSError, ValueError) as error:
                    raise CliError('E_VALIDATION', 'Cannot resolve local artwork path: ' + str(error)) from error
            arguments['source'] = source
    reply = transport.request(instance, args.group + '.' + args.action, arguments)
    if args.group == 'icons':
        return validate_icons(reply, instance, args.action)
    if args.action == 'list':
        return validate_applications(reply, instance)
    return validate_mutation(reply, instance)


def manage_local_launchers(action):
    spec = importlib.util.spec_from_file_location(
        'dockrail_launcher_manager', BUNDLE / 'scripts/smartdock_launchers.py')
    if spec is None or spec.loader is None:
        raise CliError('E_SETUP', 'Bundled launcher manager is unavailable.')
    manager = importlib.util.module_from_spec(spec)
    # A selected plugin tree is read-only deployment state. Prevent importlib
    # from materializing __pycache__ under the plugin's scripts directory.
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(manager)
        return envelope(manager.manage(action, bundle=BUNDLE))
    except (OSError, ValueError, manager.LauncherError) as error:
        raise CliError('E_SETUP', str(error)) from error
    finally:
        sys.dont_write_bytecode = previous


def execute(args):
    if getattr(args, 'help_requested', False) or args.group in (None, 'help'):
        return envelope({'text': HELP})
    if args.group == 'launchers':
        if args.action is None:
            raise CliError('E_USAGE', 'launchers requires add or remove.')
        return manage_local_launchers(args.action)
    if args.group == 'agent-guide':
        try:
            return envelope({'text': (BUNDLE / 'docs/AGENT_CONFIGURATION.md').read_text(encoding='utf-8')})
        except (OSError, UnicodeError) as error:
            raise CliError('E_PROTOCOL', 'Bundled agent guide is unavailable: ' + str(error)) from error
    if args.group in ('mode', 'config', 'apps', 'icons') and args.action is None:
        raise CliError('E_USAGE', args.group + ' requires a subcommand. Run dockrail help.')
    if args.group == 'setup' and args.feature is None and args.yes:
        raise CliError(
            'E_USAGE',
            '--yes requires --feature. Interactive setup asks before each action.')
    if args.group == 'setup' and args.feature is not None and not args.yes:
        raise CliError(
            'E_USAGE',
            '--feature requires --yes. For guided prompts run dockrail setup.')
    if args.group == 'config' and args.action == 'reset' and (args.key is None) == (not args.preferences):
        raise CliError('E_USAGE', 'Reset requires either KEY or --preferences, not both.')
    if args.group == 'apps' and args.action == 'show' and (args.id is None) == (not args.all):
        raise CliError('E_USAGE', 'Show requires either ID or --all, not both.')
    # Read only an explicitly supplied input, before starting the IPC deadline.
    patch = read_patch(args) if args.group == 'config' and args.action == 'apply' else None
    runtime = getattr(args, 'runtime', 'auto')
    instance_id = getattr(args, 'instance', None)
    if instance_id == '':
        raise CliError('E_USAGE', '--instance requires a nonempty exact ID.')
    transport = Transport()
    checks = {'python': True, 'quickshell': shutil.which('qs') is not None,
              'omarchyShell': shutil.which('omarchy-shell') is not None, 'liveRuntime': False}
    try:
        instance, status = transport.select(runtime, instance_id)
    except CliError as error:
        if (error.code == 'E_RUNTIME_NOT_FOUND' and args.group == 'config'
                and args.action == 'schema' and runtime == 'auto' and instance_id is None):
            return bundled_schema(args.key)
        if args.group == 'doctor':
            error.data['checks'] = checks
        raise
    if args.group == 'mode':
        return validate_mutation(transport.request(instance, 'mode.toggle'), instance)
    if args.group == 'settings':
        # Fixed no-arg IPC entry point. Never use the CLI configuration mutator
        # to implement a second UI writer.
        response = transport.run(['qs', 'ipc', '--pid', str(instance['pid']), 'call', '--',
                                  'dockrail-settings', 'open'])
        if response != 'opened':
            raise CliError('E_RUNTIME_NOT_FOUND',
                           'Settings needs an active dock or sidebar anchor on a connected monitor.')
        return envelope({'opened': True, 'runtime': status['data']['runtime']})
    if args.group == 'setup':
        checks['liveRuntime'] = True
        return run_setup(transport, instance, status, args, checks)
    if args.group in ('status', 'doctor'):
        if args.group == 'doctor':
            checks['liveRuntime'] = True
            status['data']['checks'] = checks
            if status['data']['loadState'] == 'invalid':
                raise CliError('E_CONFIG_INVALID', status['data']['loadError'], status['data'])
            if status['data']['writeState'] == 'error':
                raise CliError('E_PERSISTENCE', status['data']['writeError'], status['data'])
            requested = validate_read(
                transport.request(instance, 'config.get', {'effective': False}), 'get')
            if not requested['ok']:
                error = requested['error']
                data = requested['data']
                data['checks'] = checks
                raise CliError(error['code'], error['message'], data)
            status['data']['features'] = feature_readiness(
                status['data'], requested['data']['settings'])
        return status
    if args.group in ('apps', 'icons'):
        return app_icon_request(transport, instance, args)
    if args.action in ('schema', 'get'):
        arguments = {} if args.key is None else {'key': args.key}
        if args.action == 'get':
            arguments['effective'] = args.effective
        return validate_read(transport.request(instance, 'config.' + args.action, arguments), args.action, args.key)
    if args.action == 'export':
        reply = validate_read(transport.request(instance, 'config.get', {'effective': False}), 'get')
        if not reply['ok']:
            return reply
        validate_status(reply, instance)
        return export_snapshot(reply, args.output)
    if args.action == 'set':
        reply = validate_read(transport.request(instance, 'config.schema', {'key': args.key}), 'schema', args.key)
        if not reply['ok']:
            return reply
        patch = {args.key: scalar_value(args.value, reply['data']['settings'][args.key])}
    command = 'config.' + args.action
    arguments = {}
    if args.action in ('apply', 'set'):
        command = 'config.apply'
        arguments = {'patch': patch, 'dryRun': getattr(args, 'dry_run', False)}
    if args.action == 'reset':
        arguments = {'preferences': True} if args.preferences else {'key': args.key}
    return validate_mutation(transport.request(instance, command, arguments), instance)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    as_json = '--json' in argv
    parsed = None
    try:
        parsed = build_parser().parse_args(argv)
        reply = execute(parsed)
    except CliError as error:
        reply = {'apiVersion': 1, 'ok': False, 'error': {'code': error.code, 'message': str(error)},
                 'data': error.data, 'warnings': []}
    if as_json:
        print(json.dumps(reply, ensure_ascii=False, allow_nan=False, separators=(',', ':')))
    elif reply['ok']:
        data = reply['data']
        if parsed is not None and parsed.group == 'doctor':
            print(format_doctor(data))
        elif parsed is not None and parsed.group == 'setup':
            print(format_setup(data))
        else:
            print(data['text'] if 'text' in data else json.dumps(data, ensure_ascii=False, indent=2))
        for warning in reply['warnings']:
            print('dockrail: ' + str(warning), file=sys.stderr)
    else:
        print('dockrail: ' + reply['error']['code'] + ': ' + reply['error']['message'], file=sys.stderr)
        if reply['data']:
            print(json.dumps(reply['data'], ensure_ascii=False, indent=2), file=sys.stderr)
    return 0 if reply['ok'] else EXIT_CODES.get(reply['error']['code'], 5)


if __name__ == '__main__':
    sys.exit(main())
