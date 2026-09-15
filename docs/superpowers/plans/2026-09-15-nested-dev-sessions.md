# Per-agent nested Hyprland development sessions implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task-by-task. Work sequentially; each task ends with a check and a local commit. Do not start the next task when its predecessor's acceptance gate fails. A smaller agent can execute one task per turn and record its result in the execution ledger below.

**Goal:** Let coding agents repeatedly test different SmartDock source changes and configurations in independent local desktops, without changing the production dock or opening a PR for each experiment.

**Architecture:** A development-only launcher owns a named nested Hyprland session, a private session bus, private writable settings, and one selected dock host. Existing source launchers, Omarchy's real plugin host, and the existing exact-instance SmartDock CLI provide dock behavior. Start with one foreground supervisor per named session; do not add a daemon service, web dashboard, VM manager, or runtime plugin API.

**Tech stack:** Existing Python 3 standard library, Bash entry point, Hyprland/Aquamarine, Quickshell/Qt, D-Bus, Bubblewrap, grim, and existing QML tests. No pip/npm dependencies. Bubblewrap and grim were found installed during planning; their suitability still needs runtime verification.

**Spec:** The approved design is reproduced in “Approved design and boundaries” below, so this file is a self-contained handoff. The user approved planning multiple nested desktops for separate agents, source branches and configurations. This document authorizes no claim that nesting has already been qualified.

## Global constraints

- Canonical source: `/home/admin/Projects/smart-omarchy-dock`. Read its current `AGENTS.md` and `docs/DELIVERY.md` before execution.
- Local tests and local commits do not require a PR. Deliver validated source changes through a PR; never merge a feature branch locally into `main` and push it.
- Never edit an installed plugin checkout or the packaged files in `/usr/share/omarchy`.
- Never launch a second dock on the production display. Workspace placement alone is not display isolation.
- Preserve `shell.qml`, `Overlay.qml`, `Service.qml`, `DockHost.qml`, and shared `DockWindowActions` ownership. No production QML changes are expected for this tooling.
- Use `scripts/smartdock` with exact runtime and instance selectors for live settings. Its host FileView remains the settings writer.
- Place new outer windows silently on the coding agent's workspace by default. An explicit `--workspace` may select a user-authorized test workspace. Never switch the user's workspace, steal focus, or repurpose existing windows.
- Read the Omarchy skill and its Hyprland guide before implementation of placement. Verify syntax against the installed revision; do not copy legacy Hyprland `.conf` rules into this Lua installation.
- No global `systemctl --user import-environment`, `dbus-update-activation-environment --systemd`, `uwsm` launch, `omarchy restart`, or general newest-instance shell wrapper in the test environment.
- Keep `$HOME` and the calling agent's environment unchanged. Use a private mount view for paths requiring a private home; use task-specific variable names for directories.
- If installation genuinely becomes necessary, report the missing package. Any privileged operation must use graphical authorization, per the user's instructions.
- Runtime checks are explicit opt-in commands. CI must not create nested desktops.

## Approved design and boundaries

Each named session has independent source, configuration, display socket, Hyprland IPC identity, session bus, application state and evidence. Two sessions must operate concurrently. A single session runs either standalone or plugin mode, never both at once.

The source is an explicit checkout/worktree provided by the caller. The launcher does not create branches, stash edits, reset repositories, commit, push, or deploy. It can run uncommitted files. Record both HEAD and working-tree content identity; a HEAD SHA alone cannot describe a dirty candidate.

Start stays in the foreground. Agents keep its terminal/tool process alive while calling other commands from another tool invocation. This removes background-daemon recovery and service installation from version one. On shutdown, remove only session-owned processes; retain settings, logs and screenshots for inspection. A stopped session name cannot be reused automatically: use a fresh name to keep evidence unambiguous.

Version one supports disposable Wayland applications that stay in their process groups. Do not promise cleanup of arbitrary applications that daemonize or escape those groups. Browser profiles, machine-wide services, physical hotplug, lock/login flows and VM fallback are separate follow-up work. Nested desktops are not a security boundary for hostile code.

### Evidence from planning — read before guessing

Planning only performed read-only inspection; no nested compositor was launched.

| Component | Inspected result | Consequence |
| --- | --- | --- |
| Omarchy | package `4.0.3-1`; `/usr/share/omarchy` has no Git metadata | Record package revision and hashes of inspected host files, not an invented Git SHA. |
| Hyprland | package `0.56.2-2`; installed example `/usr/share/hypr/hyprland.lua` | Use current Lua config. `Hyprland --help` exposes `--config` and `--verify-config`; no `--headless` flag. |
| Aquamarine | package `0.15.0-2` | Nested backend exists, but exact launcher recipe and background frame behavior remain experimental. |
| Quickshell | package `0.3.1-1` | `qs -p PATH --no-color` is available; avoid daemonization and no-duplicate shortcuts. |
| Omarchy host | `shell/shell.qml` reads `HOME + '/.config/omarchy/shell.json'` | `XDG_CONFIG_HOME` alone does not isolate the host. |
| Plugin registry | `shell/services/PluginRegistry.qml` reads `HOME + '/.config/omarchy/plugins'` | Expose the candidate inside the private home, preserving its plugin ID. |
| First-party plugins | Registry implicitly enables infrastructure unless in `disabledPlugins` | Empty `plugins` does not produce an inert shell; explicitly disable unrelated infrastructure. |
| General Omarchy wrapper | `/usr/share/omarchy/bin/omarchy-shell` uses newest/config selection and guesses a display when missing | Never use it to target test sessions. |
| SmartDock CLI | `scripts/smartdock_cli.py`, `Transport`, uses exact `qs ipc --pid` | Reuse it; do not add another config writer or transport implementation. |
| Existing runtime harnesses | `tests/runtime/check-workspace-resize.sh`, `check-interface-animations.sh`, `preview-browser-activity.sh` | Run within verified test context where applicable. Do not launch their hosts alongside a full test dock without inspecting their contract. |

Primary references for the feasibility task:

- [Hyprland nested backend background](https://hypr.land/news/independentHyprland/)
- [Aquamarine 0.15.0 Wayland backend source](https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/Wayland.cpp)
- [Reported nested frame presentation problem](https://github.com/hyprwm/aquamarine/issues/348)
- [Current Hyprland window rule documentation](https://wiki.hypr.land/Configuring/Basics/Window-Rules/)

Treat the issue as a reason to test, not proof this installed version is broken. Never invent `AQ_BACKEND`, `AQ_WL_*`, or legacy `WLR_*` variables without confirming support in the exact installed version's source/help.

## Intended public command contract

These commands are proposed, not currently implemented:

```bash
# Long-running command: keep this process alive in an agent tool session.
./scripts/dev-session start agent-a --source /absolute/worktree --mode standalone

# Separate command invocations while start is running:
./scripts/dev-session status agent-a --json
./scripts/dev-session exec agent-a -- hyprctl -j clients
./scripts/dev-session dock agent-a -- status --json
./scripts/dev-session dock agent-a -- config get --json
./scripts/dev-session capture agent-a
./scripts/dev-session stop agent-a

# Another agent can run a different worktree/config concurrently.
./scripts/dev-session start agent-b --source /another/worktree \
  --mode plugin --config /absolute/test-config.json
```

- `start NAME --source PATH --mode standalone|plugin [--config PATH] [--workspace TARGET]`: name matches `[a-z][a-z0-9-]{0,31}`. Source and optional config resolve to existing paths. Mode is required. Default settings come from that source's `config/dock.json`. Copy supplied settings; never write the input file. Return nonzero on incomplete readiness. Once ready, print one JSON ready record to stdout, flush it, then remain alive until stopped. Logs go to files/stderr.
- `status NAME --json`: emit source path, HEAD, dirty/content identity, mode, lifecycle state, exact compositor/host identifiers, host config path and evidence path. States are `starting`, `ready`, `stopping`, `stopped`, `failed`. No discovery fallback to another name/display.
- `exec NAME -- ARGV...`: execute argv directly in that session's mount/environment context; preserve exit status. Reject empty argv and non-ready/dead sessions. Never use `shell=True`. Relative paths use the candidate source as cwd. The command is foreground; cancellation cleans its owned process group. Caller shell metacharacters are not interpreted by the launcher.
- `dock NAME -- ARGS...`: run the candidate `scripts/smartdock` with stored exact `--runtime` and `--instance`. Reject caller-provided selectors, even `--instance=...`; callers cannot override ownership. Validate the returned host config path before mutations. Pass through CLI stdout/stderr and exit status.
- `capture NAME`: capture the nested output using `grim`, with a 10-second timeout, into a new numbered file in that session's evidence directory. Never fall back to capturing the outer desktop. Print the resulting absolute path.
- `stop NAME`: stop only registered, still-owned processes, gracefully first and forcibly after five seconds. Repeating stop succeeds. Keep evidence and settings. Never run `pkill qs`, `killall Hyprland`, or delete an entire shared runtime directory.
- Usage errors exit 2; failed runtime/precondition checks exit 1. `exec` and `dock` preserve child exit codes. Unsupported capabilities fail with a specific reason; no silent fallback to production or to another backend.

No automatic worktree creation, session auto-restart, network browser test profiles, distributed scheduling, or automatic PR creation in these commands.

## Files and responsibilities

| File | Responsibility |
| --- | --- |
| `scripts/dev-session` (new) | Bash entry point resolving its own directory and executing Python. |
| `scripts/dev_session.py` (new) | Argument parsing, private paths/environment, lifecycle, exact targeting and evidence. Start with functions in one module; no manager class hierarchy. |
| `tests/test_dev_session.py` (new) | Standard-library unittest checks for names, argv, ownership, failures and config isolation. |
| `tests/runtime/dev-session/hyprland.lua` (new after Task 1) | Minimal verified nested compositor config; no user autostart imports. |
| `tests/runtime/dev-session/client.qml` (new after Task 1) | One disposable real Wayland window, distinguishable title/color, visible changing counter for screenshot freshness. |
| `tests/runtime/check-dev-sessions.py` (new) | Explicit live acceptance driver; never discovered by ordinary `tests/test_*.py`. |
| `docs/DEV_SESSIONS.md` (new) | Verified installation-specific recipe, commands, troubleshooting and qualification limits. |
| `AGENTS.md`, `docs/DELIVERY.md` (modify last) | Make local isolated iteration discoverable and distinguish it from PR delivery. |

Do not modify `.github/workflows/ci.yml` unless existing test discovery demonstrably misses the new Python test. Its unittest discovery already includes `tests/test_*.py`.

## Task 1 — Qualify the platform before building a session manager

**Files:** Create the two `tests/runtime/dev-session/` fixtures and the feasibility section of `docs/DEV_SESSIONS.md` only after the experiment demonstrates they work. Temporary experiment files stay outside deployed paths.

**Consumes:** Installed Hyprland, Omarchy and Quickshell; approved source and window-placement rules.

**Produces:** An exact, rerunnable launch recipe containing argv, environment, namespace mounts, window placement, nested display discovery, input and screenshot commands. Every later task uses that recipe. If this task fails, stop here and record the failed gate; do not implement a VM automatically.

- [ ] Read current `AGENTS.md`, `docs/DELIVERY.md`, `docs/CLI_RUNTIME_CHECKS.md`, `scripts/run`, `shell.qml`, `Overlay.qml`, `Service.qml` and the installed Omarchy skill/Hyprland guide.
- [ ] Record the platform and host source identity in an evidence directory:

```bash
pacman -Q hyprland aquamarine quickshell omarchy bubblewrap
Hyprland --help
qs --help
qs list --help
qs ipc --help
bwrap --help
sha256sum /usr/share/omarchy/shell/shell.qml \
  /usr/share/omarchy/shell/services/PluginRegistry.qml
```

- [ ] Inspect the exact Hyprland/Aquamarine revision's backend initialization. Record how Wayland nesting is selected; ensure missing parent connection cannot silently start a DRM/physical-seat session. If that cannot be enforced with the installed backend, stop and explain the gap.
- [ ] Identify the agent's outer workspace by walking process ancestors and matching their PIDs against `hyprctl -j clients`. Do not substitute the user's currently focused workspace. Perform this ownership discovery in the outer launcher before entering any private namespace. If there is no unique owner, require an explicit authorized `--workspace` before opening any window.
- [ ] Confirm current one-shot silent placement/no-initial-focus launch syntax from official documentation and installed code. Prefer per-launch rules. If nesting obscures PID ancestry, use a temporary exact compositor-PID rule registered before connection; remove only that rule afterward. A global class-only rule for every Hyprland window is not acceptable.
- [ ] Create private directories for home, runtime, cache and evidence, mode 0700. Use Bubblewrap's mount namespace to expose the private home at the real home path, leaving the caller's `$HOME` unchanged. Bind the selected source read-only at its original absolute path. Map only the parent Wayland socket needed by the nested compositor; do not expose the parent's entire runtime directory to test applications. Hide the host `/run` socket tree in the private mount view and expose only the required child runtime and, for compositor launch alone, the parent Wayland socket. Keep X11, session bus, user-service, audio and SSH sockets out of the child environment. Environment clearing alone does not hide sockets accessible through a broad root bind.
- [ ] First prove mount behavior with a non-GUI command: a write to the child's `~/.config/smartdock/dock.json` must appear only in private state. A marker in the real home must be unavailable inside. Prove the source is readable and not writable. Keep rendering access limited to the GPU nodes required by the nested backend; no physical input devices or system D-Bus socket.
- [ ] Start a minimal nested compositor with the installed Lua dialect. Begin with this config body, then validate it using `Hyprland --verify-config --config ABSOLUTE_PATH` in the private context before launch:

```lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.config({ general = { layout = "dwindle", gaps_in = 0, gaps_out = 0 } })
```

Do not import the user's Hyprland config, Omarchy autostart, or UWSM. Record the resulting nested resolution; version one uses one output and does not promise arbitrary monitor geometry.

- [ ] Capture the nested display and Hyprland signature from the child compositor's own startup context. A small startup callback writing a JSON readiness file via a fixed helper is preferable to parsing human log text. Use `hl.on('hyprland.start', ...)` and `hl.exec_cmd(...)` as shown in `/usr/share/hypr/hyprland.lua`; shell-quote any helper path. Never select newest socket/PID. The nested signature must differ from the parent signature.
- [ ] Query nested `hyprctl -j monitors` and `hyprctl -j clients` using the verified child environment. Verify the new outer window's exact address/PID/workspace with the parent's `hyprctl clients -j`; if necessary move only that window silently. Record that startup did not switch the active workspace or focus. Do not forcibly restore focus if the user changed it during the check.
- [ ] Create the disposable QML client from this starting fixture:

```qml
import QtQuick
import Quickshell

ShellRoot {
  FloatingWindow {
    width: 420
    height: 240
    title: "SmartDock dev-session fixture"
    property int ticks: 0
    color: ticks % 2 === 0 ? "#183a55" : "#553018"
    Timer {
      interval: 500
      running: true
      repeat: true
      onTriggered: parent.ticks++
    }
    Text {
      anchors.centerIn: parent
      text: "Frame " + parent.ticks
      color: "white"
    }
  }
}
```

Refine the fixture to read a session-specific label from its environment. Its window belongs inside the nested compositor, never directly on the production display.

- [ ] Capture at least three frames several seconds apart while the outer window is on an unfocused/inactive workspace. Compare decoded image content/counter visually; merely creating three files is not a pass. Verify a nested-targeted keyboard/pointer event changes the fixture while the production cursor and active workspace stay untouched. Inspect installed `wtype` and Hyprland input-dispatch help; record the exact successful input recipe. No `ydotool`/physical-seat injection fallback.
- [ ] Launch the source standalone dock with private defaults, verify its CLI host config path, and exercise a real nested window minimize/restore cycle through the dock. Prove previews and input can be observed without focusing the outer window.
- [ ] Stop only the experiment's processes. Verify production dock PID/settings remain intact. Record PASS/FAIL/NOT RUN separately for rendering, background frame freshness, capture, input, standalone host, settings and cleanup.

**Gate:** All required checks above pass, including inactive-workspace frame freshness and input. If the output freezes, screenshots time out, input requires moving the user's real pointer, or namespace isolation fails, retain logs and stop. Report a concrete narrower option or VM proposal to the user. Do not mark this workflow usable.

**Commit after passing:** fixtures and verified recipe only, on the owning local feature branch. No PR required yet.

## Task 2 — Implement deterministic names, paths, argv and environment

**Files:** Create `scripts/dev-session`, `scripts/dev_session.py`, `tests/test_dev_session.py`.

**Consumes:** Task 1's verified namespace recipe.

**Produces:** These shared interfaces, reused without duplicating logic:

| Function | Inputs | Returns / error |
| --- | --- | --- |
| `validate_name` | `value: str` | Validated string; ValueError for invalid name. |
| `session_paths` | `name: str`, `state_root: Path`, `runtime_root: Path` | Dictionary of Path values keyed `state`, `runtime`, `home`, `evidence`, `record`, `lock`. |
| `process_identity` | `pid: int` | Dictionary with integer `pid`, `start_ticks`, `pgid`; None if process disappeared. |
| `child_environment` | `record: dict` | String-to-string environment dictionary for nested clients. |
| `sandbox_argv` | `record: dict`, `argv: list[str]`, keyword `compositor: bool = False` | Full Bubblewrap argv list; compositor mode alone exposes the parent Wayland socket. |
| `dock_argv` | `record: dict`, `args: list[str]` | Candidate CLI argv with immutable host selectors; ValueError for attempted overrides. |

Only implement functions when their task needs them. Store launch-specific paths in the record, not module globals. Production parent display is supplied only for compositor launch; ordinary child commands receive the nested display.

- [ ] Write these runnable initial tests in `tests/test_dev_session.py` using normal imports from the repository's `scripts` directory:

```python
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from dev_session import validate_name, dock_argv

class SessionArgumentsTests(unittest.TestCase):
    def test_names_cannot_escape_session_root(self):
        for value in ("../prod", "a/b", "", "A", "a" * 33):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_name(value)
        self.assertEqual(validate_name("agent-a"), "agent-a")

    def test_dock_calls_keep_exact_host(self):
        record = {"source": "/tmp/source with spaces", "mode": "plugin",
                  "host_pid": 1234}
        self.assertEqual(dock_argv(record, ["status", "--json"]), [
            "bash", "/tmp/source with spaces/scripts/smartdock",
            "--runtime", "plugin", "--instance", "1234", "status", "--json"])
        for args in (["--instance", "999"], ["--instance=999"],
                     ["--runtime", "standalone"], ["--runtime=auto"]):
            with self.subTest(args=args), self.assertRaises(ValueError):
                dock_argv(record, args)
```

- [ ] Run `python3 -m unittest discover -s tests -p 'test_dev_session.py'`. Confirm failure is because the new module/functions do not exist, not an unrelated environment issue.
- [ ] Implement `validate_name` with `re.fullmatch`; `dock_argv` uses a list and rejects selector overrides anywhere in args. Add the Bash entry point using the existing `scripts/run` directory-resolution pattern and `exec python3 "$script_dir/dev_session.py" "$@"`.
- [ ] Use persistent evidence/state under `${XDG_STATE_HOME:-~/.local/state}/smartdock/dev-sessions/NAME` and live metadata/sockets under `${XDG_RUNTIME_DIR}/smartdock-dev/NAME`. Validate the runtime directory's owner/mode. Reject symlinked session directories and overlong Unix-socket paths rather than truncate names into collisions.
- [ ] Atomically reserve NAME using directory creation. Reject existing names with a useful message. Write JSON by temporary file plus `os.replace`, within the same filesystem. Readers must never see half-written JSON.
- [ ] Build the child environment from an allowlist and Task 1's verified values. Keep locale/PATH/rendering essentials; clear inherited `DISPLAY`, `SESSION_MANAGER`, `SSH_AUTH_SOCK`, production `HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS`, `QS_*`, `SMARTDOCK_*`, portal and audio routing values before setting child-owned values. Never globally export this environment.
- [ ] Turn Task 1's namespace argv into `sandbox_argv`; do not invent a more elaborate sandbox architecture. Read-only system/source views plus private writable home/runtime/state are required. Keep the caller's HOME string; only the child mount view differs. Each later `exec` must reconstruct the same private view and session bus/runtime. Keep host PID visibility consistent so Quickshell's reported PIDs work across these commands; do not introduce separate PID namespaces per invocation.
- [ ] Extend the test file with temporary-directory cases for invalid ownership/symlinks, duplicate names, source paths with spaces, poisoned inherited environment and exact literal argv containing `$(touch SHOULD_NOT_EXIST)`. The marker must not be created. Test namespace argv construction offline; actual namespace enforcement stays a runtime check.
- [ ] Run the targeted test and `bash -n scripts/dev-session`; commit the tested task locally.

## Task 3 — Add foreground lifecycle and precise cleanup

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`, `docs/DEV_SESSIONS.md`.

**Consumes:** Task 2 helpers and Task 1 compositor/bus launch recipe.

**Produces:** Working `start`, `status`, `stop` with no dock host yet. This intermediate state is development-only and must not advertise full readiness until Task 4 lands.

- [ ] Create a versioned `session.json` record with: name, state, source, mode, private paths, parent signature, nested signature/display, supervisor/process identities, registered child groups, host PID/ID/config path, output name and evidence directory. Fields unavailable before startup are JSON null; readiness requires them to be filled.
- [ ] Implement `process_identity` from Linux `/proc/PID/stat` start-time ticks plus PID. Account for spaces/parentheses in process names by parsing after the final `)`. Return None for a disappeared process. Never treat existence of a PID alone as ownership.
- [ ] Write lifecycle tests using disposable `sys.executable` children, not real Hyprland: ready record transition, startup timeout, child exits during startup, repeated stop, changed start-time token and malformed metadata. A forged/stale PID must never result in a signal to another process.
- [ ] Move Task 1's readiness helper into a private `_ready` subcommand of `scripts/dev_session.py`; do not add another public tool. It writes only the session readiness record containing the child display and signature, and refuses missing/parent-matching identity. Start private D-Bus and nested compositor using the verified recipe, with bounded readiness deadlines (15 seconds for compositor). Use `subprocess.Popen(argv, env=env, start_new_session=True)` for owned process groups; log each PID/start-time identity. The supervisor remains in the foreground and handles SIGTERM, SIGINT and unexpected compositor exit through one cleanup path.
- [ ] Use one per-session `fcntl.flock` for lifecycle/registry updates. `stop` marks stopping before reading the process registry; later exec registration must fail. Do not hold the lock while waiting for processes. Different sessions never share a lock.
- [ ] Stop children in reverse dependency order: command/fixture groups, host, compositor, bus. Revalidate identity before each signal. Send TERM, wait at most five seconds, then KILL surviving owned groups. Preserve files. A normal explicit stop yields stopped; unexpected startup/runtime exit yields failed with an error string.
- [ ] Reject unsupported detached/session-escaping applications in docs and fixtures. Add a `ponytail:` comment at group tracking stating its ceiling: foreground process groups only; adopt scoped cgroup containment if detached applications become a requirement. Do not use broad process-name matching as a shortcut.
- [ ] Run lifecycle tests; then run Task 1's nested-only check through start/status/stop. Kill the nested compositor deliberately and verify supervisor cleanup leaves no registered live children. Repeat stop; it must succeed without touching production.
- [ ] Commit the passing lifecycle task locally.

## Task 4 — Load the standalone dock and add session commands

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`, `docs/DEV_SESSIONS.md`.

**Consumes:** Lifecycle, namespace/env helpers, `scripts/run`, exact-instance SmartDock CLI.

**Produces:** Ready standalone sessions; working `exec`, `dock`, `capture` and source evidence.

- [ ] Before launch, copy either `--config` or candidate `config/dock.json` into private settings. Require a JSON object; preserve unknown keys and collection order. Do not run `controlCommand`. Do not mutate the supplied file. Resolve relative icon paths only according to the existing CLI/config contract; do not invent normalization here.
- [ ] Launch the candidate's existing `scripts/run --no-color` in its private namespace. Do not replace it with a duplicate QML entry point. Discover its exact PID/config source via `qs list --all --json` within that namespace and validate ownership against the launched process group.
- [ ] Ask the source CLI for `status --json` using exact standalone/runtime selectors. Require expected mode, exact host identity, expected private config path and healthy loaded state before emitting ready. A wrong path, pending load, dead host or ambiguous discovery is startup failure, followed by owned cleanup.
- [ ] Implement `exec` with direct argv, child environment and the same mount bindings. Register its owned process group under the session lock before releasing it for work; prevent a concurrent stop from missing a newly started command. Deregister only after the child/group has exited. Reject operations once stopping or failed.
- [ ] Implement `dock` as the existing source CLI plus immutable exact selectors. Use current source CLI schema/get/dry-run before grouped changes. Do not teach the launcher to edit live dock JSON. A reloaded/restarted host with a new PID invalidates the stored target; require stopping and starting a new named session in version one rather than guessing a replacement.
- [ ] Implement capture with the recorded nested output and session context, e.g. `grim -o OUTPUT NEW_FILE`, using Task 1's verified syntax. Require success and a nonempty valid PNG signature. Timeout is a failure. Never switch workspaces to make capture succeed.
- [ ] Record HEAD, `git status --porcelain`, tracked diff and hashes of the actual candidate files (tracked plus nonignored untracked, excluding `.git`) at ready and capture time. Sort paths; include paths in the digest. Detect source edits during inventory and fail/retry once instead of assigning inconsistent evidence. Record config bytes/hash alongside screenshots. Logs must distinguish dirty local evidence from committed release evidence.
- [ ] Add tests for copied-config independence, wrong host path, host restart, literal argv, stop/exec race, screenshot timeout and source dirtiness changing evidence identity. Use a mocked subprocess boundary for error branches; keep at least one real disposable-process lifecycle test.
- [ ] Live-check a standalone session: exact CLI readback, one typed config mutation persisted only privately, changing fixture frames, real window minimize/restore, screenshot, stop. Check hashes of production settings and input config before/after; classify unrelated concurrent user changes separately rather than reverting them.
- [ ] Commit the passing standalone workflow locally.

## Task 5 — Support the real Omarchy plugin host

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`, `docs/DEV_SESSIONS.md`.

**Consumes:** Working standalone workflow and the installed Omarchy host/registry implementations.

**Produces:** `--mode plugin` runs the unmodified installed shell with this candidate's `Overlay.qml` and `Service.qml` inside the isolated session.

- [ ] Re-read and hash installed `shell/shell.qml`, `services/PluginRegistry.qml`, plugin manifests, theme loading and any always-created services. Verify the Task 1 host revision still matches; changed revisions require revisiting the loading recipe.
- [ ] Create the candidate's plugin directory under the private view of `~/.config/omarchy/plugins/io.github.fernandodamaso.smartdock`. Prefer a read-only bind of the candidate source, preserving live source updates, over copying application code. Do not invoke `omarchy plugin add/update/clone` or change the deployed checkout. Host namespace setup owns the bind; no symlink workaround if validation prohibits it.
- [ ] Generate private `~/.config/omarchy/shell.json` with `version: 1`, a minimal native bar with empty layouts, the SmartDock plugin enabled and unrelated first-party plugins explicitly disabled. Derive first-party IDs from installed manifests and registry rules, not an outdated hardcoded list. Build `plugins` entries in the exact shape consumed by current `findEntryLocation`; verify with a unit test using an installed-independent manifest fixture.
- [ ] Include only the theme files/assets actually needed by `qs.Commons` in the private home. Copy inspected theme data read-only for the run; never edit the user's theme. If shell core services bypass disabledPlugins and attempt to change machine/session state, stop plugin qualification and document the specific service. Do not patch packaged shell files or grant access to production buses to make it pass.
- [ ] Start `qs -p "$OMARCHY_PATH/shell" --no-color` in the private context. Verify the real registry resolves this candidate's bind, and that one overlay/service pair loads. Use exact `qs ipc --pid` and the source SmartDock CLI, never the generic `omarchy-shell` wrapper.
- [ ] Read SmartDock status and require mode plugin, exact owned host PID and private settings path. Preserve one Quickshell host process for this dock; the plugin must not start another dock process. Run standalone and plugin sessions concurrently only on separate nested displays.
- [ ] Run plugin CLI mutation/persistence, theme rendering, menu/preview and service readiness checks. A service object loading is not proof of real notification/browser badge transport; report provider cases not exercised.
- [ ] Add tests for independent plugin mount paths, config shape, disabled first-party derivation, wrong source rejection and unexpected mode. Run targeted tests plus explicit live plugin checks, then commit locally.

## Task 6 — Demonstrate two-agent operation and failure recovery

**Files:** Create `tests/runtime/check-dev-sessions.py`; update `docs/DEV_SESSIONS.md`.

**Consumes:** Full launcher and Task 1 fixture/input recipe.

**Produces:** Repeatable acceptance evidence, including a negative test that would fail if commands crossed into another session.

- [ ] Make the live driver require `--source-a ABS --source-b ABS` and explicit opt-in execution. It launches two foreground start subprocesses with fresh unique names, captures ready records with a 20-second deadline, and always stops both in `finally`. It must not create Git worktrees itself.
- [ ] Provide a `--workspace TARGET` pass-through only for an authorized workspace. Absence uses the agent-owned workspace discovery. Never assume workspace 99 is unused.
- [ ] Execute the following matrix. Save command, exit status, JSON and screenshots; each row is PASS, FAIL or NOT RUN with a reason:

| Case | Action | Required observation |
| --- | --- | --- |
| Identity | A standalone, B plugin, distinct sources/settings | Different nested sockets/signatures, buses, host PIDs, private homes and config paths. |
| Source fidelity | Load a visible fixture/source difference in each candidate | Observed differences match recorded source identities; production source is not substituted. |
| Configuration separation | Change `magnification` in A through `dock`; read both | A's requested value and saved private bytes change; B and production bytes do not. Restore A through its CLI. |
| Window separation | Launch uniquely titled fixtures in A and B | Each nested client list contains only its own fixtures. Targeting A cannot minimize B's fixture. |
| Workspace actions | Move A's fixture between nested workspaces | B's window workspace and production workspace are unaffected by the test command. |
| Background frames | Capture changing fixtures while outer windows are inactive | Both captures keep changing and contain the correct session labels. |
| Input | Send nested-only input using Task 1 recipe | Only selected fixture reacts; production pointer is not driven by the test. |
| Preview/lifecycle | Hover/select/minimize/restore a fixture through the real dock | Screenshot and nested client state agree; record any untested gesture as NOT RUN. |
| Stop isolation | Stop A while B remains active | B continues rendering/CLI reads; production host remains alive. |
| Crash cleanup | Terminate B's owned compositor | B transitions failed, registered owned host/bus/fixtures are cleaned up, evidence remains. |
| Stale identity | Use stale metadata after process exit | No signal or IPC call is redirected to another process. |
| Repeated cleanup | Stop both names again | Both succeed without deleting unrelated state. |

- [ ] Run the matrix twice with mode assignments swapped to catch assumptions that only one host mode can own a particular path. Use fresh names. This is a deliberate concurrency check, not an indefinite soak test.
- [ ] Run a source edit/reload cycle locally and capture before/after identity. If the host exits or restarts, use a new session instead of silently reassigning its PID. No PR is opened between these iterations.
- [ ] Record unsupported cases explicitly: physical hotplug, production portals/audio, real browser profiles, detached apps, and hostile-code isolation. Neither simulated monitors nor offscreen unit tests qualify physical behavior.
- [ ] Commit the live driver and verified evidence recipe locally after the matrix passes. Keep generated runtime logs/images outside Git unless a small selected artifact explains a defect.

## Task 7 — Publish the agent workflow and validate delivery

**Files:** Modify `AGENTS.md`, `docs/DELIVERY.md`, finish `docs/DEV_SESSIONS.md`.

**Consumes:** Passing concurrency and plugin-host checks.

**Produces:** An executable small-agent runbook and one normal PR for the completed workflow.

- [ ] Add a short local-development section to AGENTS.md linking `docs/DEV_SESSIONS.md`: headless tests first; nested sessions for runtime work; exact source/instance targeting; no production display launches; PR only for delivery. Preserve issue-specific qualification gates in `docs/CLI_RUNTIME_CHECKS.md`; do not rewrite that historical issue's ownership/handoff requirements into a generic exemption.
- [ ] In DELIVERY.md state that local edits, local test sessions and local commits precede PR creation. Existing required checks and protected-main policy remain in force.
- [ ] Write a copyable quickstart with two terminal/tool invocations: one holds `start`, another performs status/dock/capture/stop. Include source paths with spaces, optional config copies, how to find evidence, how to resolve “workspace owner unknown”, and why newest-instance selection is forbidden.
- [ ] Document the foreground-only app ceiling and named-session ownership. Different coding agents use different worktrees and names. An agent edits only its worktree and stops only its session. Parallel agents do not share a mutable source checkout merely because their desktops differ.
- [ ] Run the existing headless gate from this exact final tree:

```bash
bash -n scripts/dev-session
python3 -m unittest discover -s tests -p 'test_*.py'
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components
bash -c 'set -e; for f in tests/check_*.sh; do bash "$f"; done'
bash -c 'set -e; for f in tests/test_*.mjs; do node "$f"; done'
git diff --check
```

Also run the remaining current Headless CI commands from `.github/workflows/ci.yml`, including provider tests and shell syntax for existing entry points. Run plugin validation/lint where required; any source-host smoke check belongs inside the verified isolated session. Do not launch the AGENTS.md smoke command on production just to tick a box.

- [ ] Commit the documentation. Record final HEAD/base and run the live matrix on the committed candidate; earlier dirty-source screenshots are development evidence, not final-SHA acceptance. Both source arguments may point to two clean worktrees of the final commit with different private configs for final concurrency qualification.
- [ ] Create one PR against `fernandodamaso/smart-omarchy-dock` explicitly, following DELIVERY.md. `gh` previously defaulted to the unrelated upstream repository; always pass `-R fernandodamaso/smart-omarchy-dock`. Keep Draft while any required gate is incomplete. Do not deploy or merge as part of this implementation plan.

## Stop conditions for the executing agent

Stop dependent work and report the precise failed command/log if any of these occurs:

1. Nested rendering/capture/input cannot work while the outer workspace is inactive.
2. The compositor can silently acquire a physical seat or test commands resolve the parent display.
3. Private home/config/runtime mapping cannot be enforced or exact host/source ownership cannot be verified.
4. Plugin mode requires enabling production services, global environment changes or editing packaged/deployed files.
5. One session can mutate another's settings/windows, or stop cannot distinguish an owned process from a reused PID.
6. Installed version changes invalidate the qualified recipe.

A stop condition is not permission to weaken checks, focus the user's workspace, install packages, build a VM, or claim partial qualification as a pass. Preserve the successful local work and describe the smallest next decision needed.

## Execution ledger

At the end of each task, append a short entry here. Record actual results only.

| Task | Status | Local commit | Evidence / next action |
| --- | --- | --- | --- |
| 1. Platform feasibility | BLOCKED (host-nested) / superseded | None | Host-nested Aquamarine inactive grim FAIL. Pivot: KVM virtio-gpu guest feasibility PASS 2026-09-15 (see docs/DEV_SESSIONS.md and docs/superpowers/specs/2026-09-15-kvm-dev-sessions-design.md). Evidence: ~/.local/state/smartdock/dev-sessions/_kvm-feasibility/. |
| 2. Paths and targeting | Not started | None | Depends on verified Task 1 recipe. |
| 3. Lifecycle | Not started | None | Depends on Task 2. |
| 4. Standalone commands | Not started | None | Depends on Task 3. |
| 5. Real plugin host | Not started | None | Depends on Task 4. |
| 6. Concurrent acceptance | Not started | None | Depends on Task 5. |
| 7. Docs and delivery | Not started | None | Depends on Task 6. |

### Small-agent handoff prompt

> Read AGENTS.md and this entire plan once. Execute the first incomplete task using superpowers:executing-plans. Before editing, inspect the task's listed source files and verified recipe. Do not spawn agents unless separately authorized. Run the task's checks, record exact evidence, commit only its scoped files locally, and update the execution ledger. Continue to the next task only after its dependency gate passes. Local iteration does not require a PR. Never open a second dock on production or guess a display/host target. If a stop condition occurs, preserve logs and report the concrete blocker rather than weakening isolation.
