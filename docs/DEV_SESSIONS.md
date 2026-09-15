# SmartDock development sessions

Local isolated docks for agent testing. **Qualified substrate on this host: KVM guest with virtio-gpu**, not host-nested Aquamarine.

## Status

| Path | Result |
| --- | --- |
| Host-nested Hyprland (Aquamarine Wayland backend) | **Not qualified** — `grim` times out while the outer window is on an inactive host workspace (2026-09-15 Task 1 evidence). |
| KVM guest (virtio-vga + guest Hyprland DRM) | **Feasibility PASS** — guest `grim` returns changing PNGs while the host QEMU window sits on inactive workspace `4` without stealing host focus. |

Do not launch a second dock on the production display. Do not use `omarchy-shell` newest-instance targeting.

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

### Host window placement (Omarchy Hyprland Lua)

Silent move without following focus:

```lua
-- via: hyprctl repl '…'
local w = hl.get_windows({ class = "qemu" })[1]
hl.dispatch(hl.dsp.window.move({ workspace = "4", follow = false, window = w }))
```

Authorized test workspace for this run was `4`. Do not switch the user's active workspace.

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

Candidate `AGENTS.md` SHA-256 matched between host and a copy into the guest (`SOURCE_HASH_MATCH`). **virtiofs read-only mount is not yet in the verified recipe**; the launcher must add it (virtiofsd + `vhost-user-fs-pci`) before claiming live source mounts.

### Not yet qualified (launcher / later tasks)

- SmartDock standalone or Omarchy plugin host inside the guest
- Nested guest input (`wtype`) while host pointer untouched
- Concurrent two-VM sessions
- Disposable guest image packaging in-repo
- virtiofs / 9p live source binds

## Agent workflow (after launcher exists)

Commands will follow the plan contract (`dev-session start|status|exec|dock|capture|stop`) on top of this KVM substrate. Until that lands, use the evidence scripts under `_kvm-feasibility/run/` only as experimental notes — not a supported product CLI.

## Related docs

- Design: `docs/superpowers/specs/2026-09-15-kvm-dev-sessions-design.md`
- Original nested plan (host Aquamarine path blocked): `docs/superpowers/plans/2026-09-15-nested-dev-sessions.md`
