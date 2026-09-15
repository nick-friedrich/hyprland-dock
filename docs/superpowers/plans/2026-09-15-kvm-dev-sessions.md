# KVM SmartDock Development Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not ask another agent to write a plan.

**Goal:** Let coding agents run and inspect separate SmartDock candidates inside named KVM guests without opening a PR for each local edit or disturbing the production dock.

**Architecture:** A foreground host command owns one QEMU process per name. Each VM has a private writable disk, SSH identity, port, settings and evidence directory. The host copies candidate files into the guest on `start` and `sync`; Hyprland, Quickshell, CLI, input and screenshots run only inside the guest.

**Tech Stack:** Python 3 standard library, Bash, QEMU/KVM, Arch cloud image/cloud-init, SSH, Hyprland, Quickshell, `grim`, `wtype`.

**Spec:** `docs/superpowers/specs/2026-09-15-kvm-dev-sessions-design.md`; verified display recipe: `docs/DEV_SESSIONS.md`.

## Global constraints

- Read `AGENTS.md`, `docs/DELIVERY.md`, the spec and `docs/DEV_SESSIONS.md` first. Local iteration uses this worktree; delivery to `main` is PR-only.
- The display/capture experiment passed; repeatable source sync, guest input, real SmartDock and concurrency are **not yet qualified**. Gate those separately below.
- Never start a second dock on the host display; never edit installed Omarchy checkouts or host `~/.config/smartdock/dock.json`.
- Never run host `uwsm`, `omarchy restart`, global user-environment imports or newest-instance Quickshell targeting.
- Host package installs, if needed, use graphical authorization. Guest package installs occur inside the disposable VM.
- `start` stays foreground-supervised. No daemon, VM manager, host GPU passthrough, live source mount or automatic guest-to-host sync in v1.
- Each name gets separate overlay qcow2, OVMF vars, cloud-init seed, SSH key, known-hosts, loopback port and evidence. Exact PID/start-time ownership is required for signals and GUI placement.
- Launch the QEMU window on the coding agent's workspace with a current-version silent/no-focus rule. Verify exact owned PID and address in `hyprctl clients -j`; move only that address silently if needed. A class-only lookup is forbidden.
- A test that needs to focus the host QEMU window, move the host pointer, write host source from the guest, or select another VM is a failure. Preserve evidence and stop at that gate.

## Files and command contract

| File | Responsibility |
| --- | --- |
| `scripts/dev-session` | Tiny Bash wrapper resolving and running `dev_session.py`. |
| `scripts/dev_session.py` | Argument parsing, name/port reservation, per-name VM lifecycle, SSH/sync/evidence and exact targeting. Keep helpers local; no generic VM framework. |
| `tests/runtime/dev-session/guest-hyprland.lua` | Minimal guest compositor config and private readiness JSON. Copy the verified Lua from `_kvm-feasibility/run/guest-hyprland.lua`; change only paths needed for a named session. |
| `tests/runtime/dev-session/guest-control.sh` | Guest-side `start-compositor`, `env`, `capture`, `start-dock` and `stop-dock`, always using the named private paths. |
| `tests/test_dev_session.py` | Small Python stdlib unit tests for names, literal argv, source manifest, records, port/ownership and selector rejection. |
| `docs/DEV_SESSIONS.md` | Copyable workflow, real gate results and limitations. |

Public CLI: `./scripts/dev-session start NAME --source ABS --base-image ABS --mode standalone|plugin [--workspace TARGET]`; separate invocations use `status NAME --json`, `sync NAME`, `exec NAME -- ARGV...`, `dock NAME -- ARGV...`, `capture NAME`, `stop NAME`. The public `ready` record is emitted only after Task 5's real dock readback; Tasks 2–4 expose development-only `starting` state while their gates run. `start` then remains alive. `stop` is idempotent. Fresh names are required for new runs; evidence is retained. The guest candidate path is always `/home/admin/smartdock-candidate`; the source path is never mounted writable into the guest.

Persistent state: `${XDG_STATE_HOME:-~/.local/state}/smartdock/dev-sessions/NAME/`. Runtime lock/port registry: `${XDG_RUNTIME_DIR}/smartdock-dev/`. Record fields: `name`, `state`, `source`, `mode`, `source_digest`, `base_image`, `port`, `qemu_pid`, `qemu_start_ticks`, `qemu_pgid`, `qemu_window_address`, `guest_display`, `guest_signature`, `guest_output`, `host_pid`, `config_path`, `evidence_path`, `error`. Write records by same-directory temporary file and `os.replace` while holding the per-name lock. Never resolve a command by “most recent” session.

---

### Task 1: Validate contract and prepare private VM inputs

**Files:** Create `scripts/dev-session`, `scripts/dev_session.py`, `tests/test_dev_session.py`.

**Interfaces:** `validate_name(value: str) -> str`; `session_dir(name: str) -> Path`; `process_identity(pid: int) -> dict | None` with `pid`, `start_ticks`, `pgid`; `qemu_argv(paths: dict, port: int) -> list[str]`. Later tasks use these exact signatures.

- [ ] **Step 1: Write failing unit checks.** Include this minimum, plus an invalid source/base-image path case:

```python
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from dev_session import validate_name, qemu_argv

class ContractTests(unittest.TestCase):
    def test_name(self):
        self.assertEqual(validate_name("agent-a"), "agent-a")
        for value in ("", "A", "../a", "a/b", "a" * 33):
            with self.assertRaises(ValueError): validate_name(value)

    def test_qemu_target_is_private(self):
        paths = {"overlay": Path("/tmp/a/overlay.qcow2"),
                 "vars": Path("/tmp/a/vars.fd"), "seed": Path("/tmp/a/seed.iso")}
        argv = qemu_argv(paths, 22341)
        self.assertIn("hostfwd=tcp:127.0.0.1:22341-:22", argv)
        self.assertIn("file=/tmp/a/overlay.qcow2,if=virtio,format=qcow2,discard=unmap", argv)
```

- [ ] **Step 2: Run** `python3 -m unittest discover -s tests -p 'test_dev_session.py'`; expect import/function failure.
- [ ] **Step 3: Implement the minimum input helpers.** Match names with `re.fullmatch(r'[a-z][a-z0-9-]{0,31}', value)`. Resolve source/base image to existing absolute paths; require `shell.qml`, `Overlay.qml`, `scripts/run`, `scripts/smartdock`, `config/dock.json` in source. Refuse existing/symlinked name directories. Compute `/proc/PID/stat` start ticks after its final `)` (field 22); use PID and ticks before any later signal.
- [ ] **Step 4: Construct private inputs.** Require `/dev/kvm`, `qemu-system-x86_64`, `qemu-img`, `cloud-localds`, `ssh-keygen`, `ssh`, `scp`, `hyprctl`. In a newly reserved name directory, create an overlay with `qemu-img create -f qcow2 -F qcow2 -b BASE overlay.qcow2`, copy `/usr/share/edk2/x64/OVMF_VARS.4m.fd` into `vars.fd`, make a unique ed25519 key (`0600`), and generate cloud-init user-data/seed for `admin` with only that session's public key and password SSH disabled. Use the verified q35/UEFI/virtio-vga/GTK/loopback-network argv from `docs/DEV_SESSIONS.md`; substitute only private paths and port. Log argv with secret-bearing values redacted.
- [ ] **Step 5: Run tests and** `bash -n scripts/dev-session`; commit only this task's files locally.

**Gate:** Two names construct distinct disk, vars, seed and SSH paths without starting QEMU. Rejected inputs create no partial VM process.

### Task 2: Foreground lifecycle and exact host window ownership

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`.

**Interfaces:** `reserve_port(runtime_root: Path, name: str) -> int`; `read_record(name: str) -> dict`; `owned_process(record: dict) -> bool`; public `start/status/stop`. Task 3 consumes the ready SSH endpoint and record.

- [ ] **Step 1: Test** duplicate names, a port occupied by another listener, malformed/stale records, and changed `/proc` start ticks. A changed tick must cause `stop` to refuse a signal. Use a disposable `python3 -c 'import time; time.sleep(30)'` process for the one real ownership check; clean it in the test.
- [ ] **Step 2: Run the targeted test** and confirm the intended failures.
- [ ] **Step 3: Implement reservation.** Hold one runtime `fcntl.flock` while choosing a free loopback port in `22000..22999`, creating its per-port reservation file, starting QEMU, and confirming that the *owned QEMU* binds it; release the lock afterward. If startup fails, release only this name's port. Keep the name's lock for record changes; never guess a different port/VM when occupied.
- [ ] **Step 4: Launch and place.** Start QEMU with `subprocess.Popen(argv, start_new_session=True)`; store PID/ticks/PGID immediately. Before launch establish a current-Hyprland `hl.exec_cmd` silent/no-focus workspace rule for the unique VM command/token (inspect `/usr/share/hypr/stubs/hl.meta.lua` and Task 1 evidence for the installed API). Then require exactly one `hyprctl clients -j` window whose PID equals the recorded QEMU PID; record its address. If placement failed, silently move **that address only** and verify workspace. Log host active workspace/window/cursor before and after; never dispatch focus or workspace switch. If no unique owned window appears, stop the owned VM and fail.
- [ ] **Step 5: Wait for guest SSH** with a 10-minute bounded deadline, `BatchMode=yes`, `IdentitiesOnly=yes`, private key, private known-hosts, `StrictHostKeyChecking=accept-new`, and exact `127.0.0.1:PORT`. Require `cloud-init status --wait` and guest `Hyprland`, `qs`, `grim`, `wtype`, `python3`, `seatd` packages. Guest setup may install missing packages with guest sudo and enable seatd; do not run host sudo for guest setup. A failed setup stops the owned VM.
- [ ] **Step 6: Supervisor loop.** `start` remains in foreground and watches QEMU. `stop` writes `stopping`, sends TERM only if PID/ticks still match, waits five seconds, then KILLs only the still-owned process group. Keep state/evidence, write `stopped`; repeat `stop` succeeds. Unexpected QEMU death writes `failed`. `status --json` reads only NAME's record and reports stale/dead QEMU honestly.
- [ ] **Step 7: Run unit tests, then one live VM** using the verified cloud image path from `_kvm-feasibility/images/Arch-Linux-x86_64-cloudimg.qcow2`. Confirm SSH, exact QEMU address/workspace, unchanged host focus/cursor/settings hash, and no remaining owned QEMU after stop. Commit.

**Gate:** VM lifecycle works by exact name and host placement; no guest dock is claimed ready yet. A host window ownership failure stops this task.

### Task 3: Repeatable, one-way source sync

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`.

**Interfaces:** `source_manifest(source: Path) -> tuple[list[dict], str]`; `sync_source(record: dict) -> str`. Later status/capture/dock use the returned digest.

- [ ] **Step 1: Test** a tracked file, a dirty tracked edit, a nonignored untracked file, a path with spaces and an ignored file. Changing candidate bytes must change the digest; `.git`/ignored files must not enter the transfer. Assert the original host file hash is unchanged after a guest-side edit.
- [ ] **Step 2: Run the targeted test** and confirm failure.
- [ ] **Step 3: Inventory with Git.** From `source`, run `git ls-files -z --cached --others --exclude-standard`; sort byte paths. For each regular file hash path + bytes with SHA-256; for a symlink hash path + link target, never dereference. Reject path traversal, unsupported file kinds and a file changing between inventory and archive. Make a Python `tarfile` archive of exactly those paths; exclude `.git` and ignored files. Keep archive under this name's evidence directory.
- [ ] **Step 4: Copy one way.** `scp` the archive to this guest only. Extract into a new guest `/home/admin/smartdock-candidate.new` with paths confined to that directory; verify every file/link against the host manifest inside the guest, then rename it to `/home/admin/smartdock-candidate`. Do not mount host source or copy guest files back. Update `source_digest` only after guest readback matches; on failure retain prior candidate/record and report error.
- [ ] **Step 5: Live-check twice.** Sync a dirty source, edit one candidate file locally, sync again and verify a changed guest digest. Create a guest-only marker and verify no marker or changed bytes appear in the host source. Stop VM; run unit tests and commit.

**Gate:** Dirty local edits reach the correct guest without PRs; guest writes cannot flow to the host. Archive/hash mismatch stops the task.

### Task 4: Guest compositor, input and screenshot commands

**Files:** Create `tests/runtime/dev-session/guest-hyprland.lua`, `tests/runtime/dev-session/guest-control.sh`; modify `scripts/dev_session.py`, `tests/test_dev_session.py`.

**Interfaces:** guest control writes private JSON with `wayland_display`, `hyprland_instance_signature`, `output`; public `exec` and `capture` consume that exact context.

- [ ] **Step 1: Test** that `exec NAME -- echo '$(touch /tmp/wrong)'` passes literal argv, a failed guest command returns its exit code, and a screenshot missing PNG's eight-byte signature fails. Reject `exec`/`capture` for stopped/failed names.
- [ ] **Step 2: Run the targeted test** and confirm failure.
- [ ] **Step 3: Copy the verified guest config** from `_kvm-feasibility/run/guest-hyprland.lua` into the repository. Write readiness JSON under the guest session directory, not `/tmp/hypr-ready.json`; preserve minimal monitor and no imported user autostart. Guest control starts `LIBSEAT_BACKEND=seatd Hyprland --config ...` with inherited outer `WAYLAND_DISPLAY`/`DISPLAY` unset, waits 30 seconds, reads signature/display, and queries one output via `hyprctl -j monitors` using those values. It must never infer the newest Hyprland instance.
- [ ] **Step 4: Implement guest commands** via exact SSH key/port. Quote remote argv with Python `shlex.join` only at the SSH boundary; never use `shell=True` on the host. Export the readiness-file `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `XDG_RUNTIME_DIR` for guest clients. `capture` executes `timeout 10s grim -o OUTPUT FILE.png` in the guest, then copies only that PNG to NAME's numbered evidence path, validates PNG signature/size and records source/config digest.
- [ ] **Step 5: Live input gate.** Launch a labeled Quickshell fixture on the guest display; use guest `wtype` on its focused guest surface (or a guest `hyprctl dispatch` input operation) and capture before/after evidence. Record host `hyprctl cursorpos`, active workspace/window before/after; require host pointer/focus unchanged and guest response changed. Place host QEMU on an inactive workspace and capture at least three changing labeled frames. Preserve failure logs; do not focus host QEMU to force a pass.
- [ ] **Step 6: Run unit tests,** `bash -n tests/runtime/dev-session/guest-control.sh`, live gate, and commit.

**Gate:** Guest input and frames change with inactive/unfocused host QEMU, with no host pointer/focus change. An identical frame or timed-out `grim` blocks dock work.

### Task 5: Standalone SmartDock in the guest

**Files:** Modify `scripts/dev_session.py`, `tests/runtime/dev-session/guest-control.sh`, `tests/test_dev_session.py`.

**Interfaces:** `dock_argv(record: dict, args: list[str]) -> list[str]` inserts `--runtime standalone|plugin --instance HOST_PID`; public `dock` uses it. `start` becomes `ready` only after exact host/config readback.

- [x] **Step 1: Test selector rejection:** `dock -- --instance 999`, `--instance=999`, `--runtime auto` and `--runtime=plugin` cannot override the recorded mode/PID. A wrong config path or host PID makes readiness fail. Test `config/dock.json` input bytes remain unchanged.
- [x] **Step 2: Run the targeted test** and confirm failure.
- [x] **Step 3: Guest control copies** candidate `config/dock.json` to private guest `~/.config/smartdock/dock.json` on the first start, sets `XDG_CONFIG_HOME`/`SMARTDOCK_CONFIG`, then runs `/home/admin/smartdock-candidate/scripts/run` under the guest Wayland environment. Do not run `qs` on host. If standalone lacks Omarchy `qs.Commons` imports inside a plain Arch guest, copy the required current Omarchy shell `Commons/Ui` files into the guest as read-only test assets (never edit the host's installed checkout), or record a concrete standalone dependency failure; do not fake dock readiness.
- [x] **Step 4: Find the guest host exactly.** Use `qs list --all --json` inside guest and the candidate `scripts/smartdock --runtime standalone --instance PID status --json`; require the one process launched by guest control, mode `standalone`, healthy loaded state and exact private config path. Store PID/instance. Public `dock` always injects those exact selectors and calls the candidate CLI inside guest; a restarted PID invalidates the session rather than guessing a replacement.
- [x] **Step 5: Live-check** a standalone dock screenshot, one CLI `config schema/get` read and one typed dry-run/apply/readback against guest private settings. Minimize/restore a guest window through the dock controller if the guest environment supports it. Verify host production dock PID/settings and host source defaults are unchanged. `sync` after code edits must reload/restart **through the existing guest host contract** or require a fresh name; do not silently continue with stale running QML.
- [x] **Step 6: Run targeted unit tests and affected QML tests** with `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -import components`; commit.

**Gate:** A real standalone dock reports the guest's exact private config and renders. CLI persistence and rendering are recorded as separate facts.

### Task 6: Plugin mode qualification

**Files:** Modify `scripts/dev_session.py`, `tests/runtime/dev-session/guest-control.sh`, `tests/test_dev_session.py`, `docs/DEV_SESSIONS.md`.

- [x] **Step 1: Inspect** the exact Omarchy revision targeted by this source. Copy only required `shell/Commons`, `shell/Ui`, first-party plugin host files and theme assets into the guest test image/candidate area; keep host installed checkouts read-only. Start one Omarchy shell Quickshell process in the guest with SmartDock `Overlay.qml` enabled. Do not launch a second guest dock process or use a newest-instance wrapper. If shell core services require host-specific buses/portal/device state that the guest lacks, mark plugin mode unqualified with the exact failure; standalone remains usable.
- [x] **Step 2: Require guest CLI readback** `--runtime plugin --instance EXACT_PID status --json` with plugin mode, exact owned shell PID and guest private config path. Run one guest-only config mutation/readback and screenshot. Unit-test wrong-mode and changed-PID rejection.
- [x] **Step 3: Run targeted unit tests**, the guest plugin status/mutation/screenshot gate, and `omarchy plugin validate .` for plugin changes. Commit the tested task. If the guest shell lacks a required service, record its exact failure and mark this task BLOCKED; continue to Task 7's independent standalone concurrency gate.

**Gate:** Plugin CLI and rendering use the real guest Omarchy host, or plugin mode is explicitly blocked with evidence. Standalone qualification is unaffected.

### Task 7: Two-agent qualification, documentation and delivery

**Files:** Modify `scripts/dev_session.py`, `tests/test_dev_session.py`, `docs/DEV_SESSIONS.md`.

- [ ] **Step 1: Unit-test cross-targeting.** Two records with different names/ports/keys must produce different SSH argv and evidence paths. A stale/forged A PID must not receive a signal; B's record is unaffected.
- [ ] **Step 2: Run two named VM sessions** from two distinct worktrees/sources at once in standalone mode. Give each a different candidate marker and dock config, sync dirty edits separately, capture each guest with host QEMU windows inactive, and verify different disk/vars/seed/SSH/port/known-hosts/config/frame paths. Stop A; B must keep responding and capturing. Stop B; verify no owned QEMU/processes remain and host production PID/settings hash is unchanged.
- [ ] **Step 3: Write `docs/DEV_SESSIONS.md` quickstart** with two terminal invocations (`start` stays open), the exact `start/status/sync/exec/dock/capture/stop` examples, evidence paths, fresh-name rule, VM image prerequisite, guest-only CLI targeting and separate standalone/plugin qualification results. Do not call plugin mode supported if Task 6 failed.
- [ ] **Step 4: Run** `python3 -m unittest discover -s tests -p 'test_dev_session.py'`, `bash -n scripts/dev-session tests/runtime/dev-session/guest-control.sh`, `git diff --check`, and applicable `AGENTS.md` local validation. Commit. Open a Draft PR only after the local result is reviewable; record exact base/head SHAs per `docs/DELIVERY.md`.

**Gate:** Two standalone sessions cannot cross-target or cross-stop. If Task 6 passed, repeat the two-session targeting check with one plugin guest; otherwise document plugin mode as blocked.

## Execution ledger

| Task | State | Evidence / commit |
| --- | --- | --- |
| 1. Private VM inputs | PASS | unit tests + prepare gate-a/gate-b distinct paths; no QEMU started |
| 2. Lifecycle/placement | PASS | unit tests + live task2d (QEMU 1419058 / 0x5559cb52a2f0, SSH+packages, idempotent stop); ~/.local/state/smartdock/dev-sessions/task2d/evidence/ |
| 3. One-way source sync | LIVE PASS | unit tests + live task3a two syncs (87a19c→deefb21→58b7fd), guest-only marker, idempotent stop; ~/.local/state/smartdock/dev-sessions/task3a/evidence/ |
| 4. Guest compositor/input/capture | LIVE PASS | unit tests + live task4a Virtual-1 grim (input 001≠002, labeled colors 006–008 distinct), QEMU 1470347 on ws 4, host ws/window unchanged; ~/.local/state/smartdock/dev-sessions/task4a/evidence/ |
| 5. Standalone dock | LIVE PASS | unit + qmltestrunner 207; live task4a qs pid 2816 standalone loaded at guest ~/.config/smartdock/dock.json; margin 10→14 persist; frame-010.png dock render; host qs 743034 / settings 7ccbbaf5 unchanged; minimize NOT RUN (no window CLI, empty clients); ~/.local/state/smartdock/dev-sessions/task4a/evidence/ |
| 6. Plugin mode | LIVE PASS | omarchy 4.0.3-1; live task4a one qs pid 3415 at guest smartdock-omarchy-test/shell/shell.qml, --runtime plugin loaded, guest ~/.config/smartdock/dock.json; iconSize 42→48 persist; frame-011.png plugin dock; host qs 743034 / settings 7ccbbaf5 unchanged; ~/.local/state/smartdock/dev-sessions/task4a/evidence/ |
| 7. Two agents/docs | Not started | |

After each gate, update this ledger with PASS, FAIL or BLOCKED and exact evidence path/commit. Continue automatically after PASS. Task 6 plugin BLOCKED does not prevent Task 7 standalone concurrency. On any other failed gate, keep logs and report the concrete blocker without weakening isolation or touching host production state.
