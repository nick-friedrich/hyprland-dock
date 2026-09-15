# SmartDock development sessions

Local isolated docks for agent testing. A named KVM guest runs Hyprland, screenshots, and one SmartDock host (standalone or Omarchy plugin) without opening a PR for each edit and without touching the production dock.

## Status

| Path | Result |
| --- | --- |
| Host-nested Hyprland (Aquamarine Wayland backend) | **Not qualified** — `grim` times out while the outer window is on an inactive host workspace (2026-09-15 Task 1 evidence). |
| KVM guest (virtio-vga + guest Hyprland DRM) | **Display/capture feasibility PASS** — guest `grim` returns changing PNGs while the host QEMU window sits on inactive workspace `4` without stealing host focus. |
| KVM guest standalone SmartDock | **LIVE PASS** — task4a qs pid 2816, private `~/.config/smartdock/dock.json`, frame-010.png. |
| KVM guest Omarchy plugin SmartDock | **LIVE PASS** — Omarchy `4.0.3-1` (`version` file `4.0.0.alpha`); one guest qs pid 3415 at copied `smartdock-omarchy-test/shell/shell.qml` with Overlay.qml enabled; `--runtime plugin --instance 3415`; iconSize 42→48 guest-only; frame-011.png. First-party services were listed in `disabledPlugins`. Host `/usr/share/omarchy` and host `~/.config/smartdock/dock.json` were not edited. |
| Two concurrent standalone sessions | **LIVE PASS** — task4a (port 22000, source feat-nested-dev-sessions, marker TASK7A) and task7b (port 22001, source task7b-src, marker TASK7B); distinct overlay/vars/seed/SSH/known-hosts/evidence; dirty syncs did not cross; stop A left B capturing (frame-003.png); both stopped with no leftover SmartDock QEMU. Host production qs 743034 / settings `7ccbbaf5…` unchanged. |
| Two-session targeting with one plugin guest | **LIVE PASS** — task4a stayed `--runtime standalone --instance 4577`; task7b switched to `--runtime plugin --instance 2558` at copied `smartdock-omarchy-test/shell/shell.qml`; B `iconSize` 36 did not change A's guest settings hash. |

Do not launch a second dock on the production display. Do not use `omarchy-shell` newest-instance targeting. Do not edit `/usr/share/omarchy` or host `~/.config/smartdock/dock.json`.

## Quickstart

`start` stays in the foreground and supervises QEMU. Use a second terminal for `status` / `sync` / `exec` / `dock` / `capture` / `stop`. Fresh names are required for new runs; evidence is kept after `stop`.

Keep `XDG_STATE_HOME` unset so state is `~/.local/state/smartdock/dev-sessions/NAME`.

### VM image prerequisite

Use the verified Arch cloud image (do not invent another):

```text
~/.local/state/smartdock/dev-sessions/_kvm-feasibility/images/Arch-Linux-x86_64-cloudimg.qcow2
```

Host packages for the supervisor: `qemu-desktop`, `edk2-ovmf`, `cloud-utils`, plus `ssh` / `scp` / `hyprctl`. Guest packages are installed inside the VM (`Hyprland`, `qs`, `grim`, `wtype`, `python3`, `seatd`, `qt6-5compat`).

### Two terminals (start stays open)

Terminal 1 — source A, workspace 4 so the QEMU window stays off the active desktop:

```bash
unset XDG_STATE_HOME
./scripts/dev-session start agent-a \
  --source /absolute/path/to/worktree-a \
  --base-image /home/admin/.local/state/smartdock/dev-sessions/_kvm-feasibility/images/Arch-Linux-x86_64-cloudimg.qcow2 \
  --mode standalone \
  --workspace 4
```

Terminal 2 — source B, same workspace, different name:

```bash
unset XDG_STATE_HOME
./scripts/dev-session start agent-b \
  --source /absolute/path/to/worktree-b \
  --base-image /home/admin/.local/state/smartdock/dev-sessions/_kvm-feasibility/images/Arch-Linux-x86_64-cloudimg.qcow2 \
  --mode standalone \
  --workspace 4
```

Do not wait on `start` in the controller pane. Poll `~/.local/state/smartdock/dev-sessions/NAME/evidence/progress.json` and the flushed `guest_setup_complete` JSON line. `start` then remains alive until `stop`.

Plugin mode uses `--mode plugin` on one name only. That session copies Omarchy `shell/` plus theme `colors.toml`/`shell.toml` into the guest as read-only test assets and runs one `qs -p …/shell` with `Overlay.qml` enabled. Never start a second dock in the same guest.

### Commands (guest-only CLI targeting)

Public `dock` injects `--runtime standalone|plugin --instance HOST_PID` from the named record. Do not pass `--instance` or `--runtime` yourself.

```bash
unset XDG_STATE_HOME
./scripts/dev-session status agent-a --json
./scripts/dev-session sync agent-a
./scripts/dev-session exec agent-a -- true
./scripts/dev-session dock agent-a -- status --json
./scripts/dev-session dock agent-a -- config schema --json
./scripts/dev-session dock agent-a -- config get --json
./scripts/dev-session capture agent-a
./scripts/dev-session stop agent-a
```

Replace `agent-a` with `agent-b` for the other session. `stop` is idempotent and signals only the owned QEMU PID/start-ticks.

### Evidence and isolation

Per-name state:

```text
~/.local/state/smartdock/dev-sessions/NAME/
  overlay.qcow2
  vars.fd
  seed.iso
  id_ed25519
  known_hosts
  record.json
  evidence/
    frame-NNN.png
    frame-NNN.json
```

SSH is `127.0.0.1` plus that name's reserved port in `22000..22999`. Guest candidate path is always `/home/admin/smartdock-candidate`. Guest settings are always `/home/admin/.config/smartdock/dock.json` inside that VM, not the host file.

### Fresh-name rule

Do not reuse a name directory. After `stop`, keep evidence and pick a new name for the next run.

## Feasibility recipe (verified 2026-09-15)

Evidence root: `~/.local/state/smartdock/dev-sessions/_kvm-feasibility/`.

### Host packages

```text
qemu-desktop 11.1.1-1
edk2-ovmf 202608-1
cloud-utils 0.33-3
```

Installed with graphical authorization (`pkexec pacman`) when missing.

### Guest image

- Base: Arch Linux cloudimg qcow2 (`Arch-Linux-x86_64-cloudimg.qcow2`)
- Working overlay: `images/guest.qcow2` (backing file = base)
- cloud-init seed ISO: admin user + SSH ed25519 key, no password auth
- SSH: `ssh -i …/run/guest_ed25519 -p 2222 admin@127.0.0.1`

### QEMU argv (core)

```bash
qemu-system-x86_64 \
  -name 'SmartDock KVM Feasibility,process=smartdock-kvm-feasibility' \
  -machine q35,accel=kvm,usb=off \
  -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$GUEST_QCOW2",if=virtio,format=qcow2,discard=unmap \
  -drive file="$SEED_ISO",media=cdrom,if=virtio,readonly=on \
  -device virtio-vga \
  -display gtk,gl=off,window-close=on \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci
```

### Host window placement

The feasibility experiment verified that its QEMU window ended on workspace `4` without following focus. Its temporary script selected the first window with class `qemu`; that shortcut must **not** be copied into the launcher because another QEMU window could already belong to the user.

The launcher must establish a current-version silent/no-initial-focus launch rule first, then identify the new QEMU window by the owned VM PID and its exact address in `hyprctl clients -j`. Require exactly one match. If a delegated window ignores the rule, move only that address with `movetoworkspacesilent` and verify the target workspace afterward. A class-only match or an active-window dispatcher is an ownership failure.

Authorized test workspace for this run was `4`. General sessions use the coding agent's workspace unless the user explicitly selects another. Never switch the user's active workspace.

### Guest compositor

Inside the guest after `pacman -S hyprland grim quickshell seatd`:

1. Enable `seatd`; user in groups `seat` and `video`.
2. Minimal Lua config (`guest-hyprland.lua` in evidence `run/`) with `hl.on("hyprland.start", …)` writing `/tmp/hypr-ready.json`.
3. `LIBSEAT_BACKEND=seatd Hyprland --config …` (unset inherited `WAYLAND_DISPLAY`).
4. Guest output name observed: `Virtual-1` (Red Hat QEMU Monitor).
5. Capture: `grim -o Virtual-1 FILE.png` with guest `WAYLAND_DISPLAY` + `HYPRLAND_INSTANCE_SIGNATURE` from the readiness file.

Headless Weston starts but **does not** implement the screencopy protocol grim needs. Use guest Hyprland (or another compositor with wlr-screencopy).

### Capture gate result

With host active workspace ≠ `4` and QEMU on workspace `4`:

- Distinct red / green / blue Quickshell surfaces produced distinct PNGs (`HOST_INACTIVE_COLOR_CAPTURE_PASS`).
- Production `~/.config/smartdock/dock.json` SHA-256 unchanged across the run.
- QEMU stopped by recorded PID; no leftover qemu window.

### Source bytes

Candidate `AGENTS.md` SHA-256 matched between host and a copy into the guest (`SOURCE_HASH_MATCH`). This qualifies copied-byte fidelity for one file only. Repeatable sync of a dirty source tree, content-hash readback, and protection against guest-to-host writes are still implementation gates. Version one uses explicit sync at start and after edits; a read-only virtiofs live mount can be added after it is separately proven useful and safe.

### Not yet qualified

- Disposable guest image packaging in-repo
- virtiofs / 9p live source binds

## Agent workflow

Use `./scripts/dev-session` as documented in the Quickstart. `start` stays open; a second terminal runs `status|sync|exec|dock|capture|stop`. Evidence under `_kvm-feasibility/run/` is historical capture notes, not the product CLI.

## Related docs

- Design: `docs/superpowers/specs/2026-09-15-kvm-dev-sessions-design.md`
- Original nested plan (host Aquamarine path blocked): `docs/superpowers/plans/2026-09-15-nested-dev-sessions.md`
