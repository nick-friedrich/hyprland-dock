# KVM guest SmartDock development sessions — design

**Status:** Approach approved; **guest display/capture feasibility PASS** (2026-09-15). Source iteration, guest input, dock hosting, and concurrent sessions remain unqualified. Launcher planning may proceed from the verified recipe in `docs/DEV_SESSIONS.md`.
**Date:** 2026-09-15
**Supersedes for qualification:** nested Aquamarine-on-host inactive-workspace capture from `docs/superpowers/plans/2026-09-15-nested-dev-sessions.md` Task 1.

## Problem

Host-nested Hyprland (Aquamarine Wayland backend) on this machine starts and isolates correctly, but `grim` against the nested output times out while the outer Aquamarine window sits on an inactive host workspace. That fails the background-agent contract. Nested-on-host remains unqualified.

## Decision

Use a **full KVM guest** with **virtio-gpu**. Dock hosts, `grim`, `hyprctl`, and SmartDock CLI run **inside** the guest against the guest’s own compositor. The host QEMU window may be unfocused or on an inactive workspace; guest-internal presentation must still produce changing frames.

Rejected for v1: second loginctl seat (only `seat0` present), Looking Glass / NVIDIA passthrough (takes the host RTX 4070), nested-on-host Aquamarine as the qualified capture path.

## Architecture

```
Host agent tool
  └─ scripts/dev-session (later)
       ├─ owns QEMU process group + evidence on host
       ├─ SSH/exec into guest (exact key, no newest-instance guessing)
       └─ syncs screenshots/logs out of guest

Guest (disposable Arch-based VM)
  ├─ Hyprland + Quickshell (+ Omarchy host files when plugin mode is in scope)
  ├─ candidate source copied by explicit, hash-checked sync
  ├─ private HOME / XDG dirs inside guest disk or overlay
  └─ grim / wtype / smartdock against guest WAYLAND_DISPLAY only
```

Constraints carried forward from the nested plan:

- Never launch a second dock on the production (host) display.
- Never edit `/usr/share/omarchy` or installed plugin checkouts on the host.
- No global host `systemctl --user import-environment`, `uwsm`, or `omarchy restart` for test setup.
- Privileged host package installs use graphical authorization (`pkexec` from agent context).
- Named sessions stay foreground-supervised; no daemon/web VM manager in v1.
- Exact instance targeting for SmartDock CLI inside the guest.
- Each named VM has its own writable qcow2 overlay, OVMF variables, cloud-init seed, SSH key/known-hosts file, and loopback SSH endpoint. Reserve endpoints atomically; never select a different guest when a port is occupied.
- Launch the QEMU window with current-version silent placement and no initial focus. Identify and, if necessary, move only the window belonging to the recorded owned VM PID/address. A class-only `qemu` lookup can select an existing user window and is forbidden.
- Version one syncs source explicitly at start and after edits, then verifies a candidate-content hash in the guest. Guest copies must never sync writes back to the host. Virtiofs is an optional later optimization after read-only mount behavior is proved.

## Display feasibility gate (before launcher code)

Prove on this host, with temporary scripts under evidence state (not the product launcher):

1. Install `qemu-desktop` and `edk2-ovmf` via graphical authorization if missing.
2. Boot a disposable guest with virtio-gpu (UEFI). Prefer a minimal Arch cloud/base image plus packages over a full Omarchy ISO for the first gate.
3. Inside the guest, run Hyprland (or the smallest compositor that still exercises Wayland + `grim` if Hyprland install blocks) and a labeled changing fixture.
4. From guest context, capture ≥3 frames several seconds apart with nonempty PNG signatures and decoded content that changes.
5. While capturing, keep the **host** QEMU window on an **inactive** host workspace without switching focus to it. Host cursor/active workspace must not be driven by the test.
6. Copy one candidate file into the guest and verify its bytes match the host. This proves transport fidelity for the experiment; it does not qualify a read-only live mount or repeatable source sync.
7. Stop only owned QEMU/guest processes; host production dock PID and host `~/.config/smartdock/dock.json` hash unchanged.

**Pass:** all of the display, capture, placement, copied-byte, and cleanup checks above. Then write the verified guest recipe into `docs/DEV_SESSIONS.md` and proceed to an implementation plan for `scripts/dev-session` on this KVM substrate. Early implementation gates must prove repeatable source sync from a dirty candidate, content-hash readback, no host source writes, and guest input without moving the host pointer; do not call the agent workflow qualified before they pass.

**Fail:** retain logs under `~/.local/state/smartdock/dev-sessions/_kvm-feasibility/`, do not claim nested or KVM workflows usable, report the concrete blocker.

Out of scope for this gate: SmartDock standalone/plugin hosts inside the guest, two concurrent VMs, virtio networking hardening beyond SSH for the experiment, and shipping a custom guest image in git.

## Product shape after a passing gate (not built in the feasibility step)

Public command contract follows the nested plan (`start` / `status` / `exec` / `dock` / `capture` / `stop`) plus an explicit `sync` command for edit/test repetition:

- `start` boots or attaches the named guest and waits for SSH + compositor readiness.
- `exec` / `dock` / `capture` run in the guest environment (SSH or virtio-serial control channel), not in a host Bubblewrap nested Hyprland.
- `sync` copies the current candidate bytes into the named guest, verifies a content hash, and reports that identity. It never copies guest writes to the host; a running dock is restarted/reloaded through its existing host contract after the copy.
- Host Bubblewrap private-home isolation may still wrap host-side helpers; guest settings live in the guest.
- Concurrent agents = concurrent VMs (or distinct guest users/disks), not concurrent nested compositors on the host.

Plugin-mode Omarchy-in-guest is a later task after standalone-in-guest works.

## Risks

| Risk | Mitigation |
| --- | --- |
| Guest compositor also freezes when host QEMU window is inactive | Feasibility gate measures this explicitly; fail closed |
| NVIDIA host + virtio-gpu quirks | Stick to virtio-gpu; no DRM passthrough in v1 |
| Large images / disk use | Disposable qcow2 overlays under XDG state; one immutable base image may be shared, but each session has its own writable overlay and OVMF variables |
| Package install needs privilege | `pkexec pacman`; stop if user denies |

## Evidence from nested Task 1 (retained)

Nested isolation, silent placement token (`HL_EXEC_RULE_TOKEN`), and render-node needs are documented under `~/.local/state/smartdock/dev-sessions/_task1-evidence/`. That path remains a negative qualification for host-nested capture, not a recipe to ship.
