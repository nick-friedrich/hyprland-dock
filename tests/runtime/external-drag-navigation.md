# External drag hover navigation — real-app runtime matrix (Task 1 feasibility gate)

Status: **NOT EXECUTED — staging only, handed off.** This file records the
native Wayland drag route gate from
`docs/superpowers/plans/2026-11-03-external-drag-hover-navigation.md` (Task 1).
No case was performed, so no case is PASS or FAIL and no feature code is
qualified by this document. The KVM route was halted by the owner and the gate
moved to a real desktop machine; see "Handoff" below for what the next agent
inherits. The staging, instrumentation contract, case matrix and evidence format
are retained because they are directly reusable on a real desktop.

## Scope

Task 1 answers one question before Tasks 2–5 are implemented: while an external
drag is held, does activating a Dockrail window or workspace target keep the
source drag alive, and does the final drop still deliver the content exactly
once to the destination application?

A drag-entry log alone is **not** success. A case passes only when the
destination application receives the dragged content.

## Base and versions

| Item | Value |
| --- | --- |
| Base commit (branch point) | `ff7d452284c1bd065fdb0d344a98eb3c864bc9ef` (origin/main) |
| Branch | `feat/edhn-gate-t1` |
| Host Hyprland | `0.56.2-4` (built from v0.56.2, commit `efb5099`) |
| Host Quickshell | `0.3.2.r7.g2b4501a-1` |
| Host Qt Wayland | `6.12.0-1` |
| Guest Hyprland | `0.57.0-3` (built from v0.57.0, commit `0aa6745`) |
| Guest Quickshell | `0.3.2-1` |
| Guest Qt Wayland | `6.12.0-1` |
| Guest apps | thunar `4.20.10-1`, foot `1.28.0-2`, grim `1.5.0-2` |
| Guest session | `edhn-t1-j`, standalone, two virtio outputs (`Virtual-1` 1900x907, `Virtual-2` 1900x968) |

The guest is a named KVM dev session (`docs/DEV_SESSIONS.md`), not the host
desktop. No host dock, host settings file, or installed Omarchy plugin was
touched.

## Instrumentation (temporary, removed before delivery)

A navigation-only prototype was synced into the guest candidate only:

- `components/DockExternalDragSpike.qml` — a non-visual Qt `DropArea` with an
  empty `keys` list (accepts every MIME type), a 500 ms dwell `Timer`, and an
  append-only log at `/tmp/edhn-t1.log`.
- One instance over the workspace-card header (`DockWorkspaceGroup.qml`) and one
  over each running application icon (`DockItem.qml`).

The prototype logs only: event type (`armed`, `entered`, `motion`, `exited`,
`dwell-fired`, `activation-target`, `activated`, `dropped`, `drop-rejected`),
the MIME format **names** offered by the drag, the target identity (workspace
identity or desktop id plus window title), and timestamps. It never reads
`text`, `urls`, HTML or image data, and never calls `getData*`. A release on a
navigation target sets `drop.accepted = false`.

Activation reuses the existing owners only: `DockWindowActions.focusWorkspaceInPlace()`
for workspace targets and `DockWindowActions.activateToplevel()` (no activation
monitor, so no relocation) for window targets. The window path prefers a
toplevel that is not the currently focused one, so a same-workspace activation
is meaningful even when one icon owns several windows.

Outline colours in the screenshots: **red** = workspace target, **green** = a
window target that is not the focused window (for example the destination),
**orange** = the icon of the currently focused window (typically the drag
source).

### Harness deviations recorded for honesty

- The launcher's host-focus equality guard was relaxed **locally and
  uncommitted** because the desktop owner was actively working while the guest
  started; the run was accepted only after verifying that no QEMU window held
  focus or sat on the active workspace, by exact QEMU window address.
- The owner's Hyprland configuration renumbers workspaces in place, so an exact
  workspace number cannot persist. Placement therefore verifies "both QEMU
  windows share one workspace that is not the active workspace" and records the
  resulting number.
- The guest `qs list` build prints Qt locale warnings and `No running
  instances.` on stdout, so dock readiness matches the candidate config path in
  the plain `qs list --all` output instead of parsing `--json`.
- The drags were performed by the desktop owner with the real pointer. No
  synthetic input, clipboard transfer, or synthetic mouse release was used.
- Guest dock settings differ from host settings only inside the guest:
  `workspaceLayout: grouped`, `iconSize: 56`, `autoHide: false`,
  `showPreviews: true`. Theme files (`colors.toml`, `shell.toml`) were copied
  into the guest so Omarchy `Color`/`Style` resolve.

## Guest layout

- Workspace 1 on `Virtual-1`: two thunar windows, tiled — **src**
  (`~/edhn-t1/src`, holds `payload-a.txt`, `payload-b.txt`, `payload-shot.png`)
  and **dst-same** (`~/edhn-t1/dst-same`, empty).
- Workspace 3 (hidden until activated): **dst-cross** (`~/edhn-t1/dst-cross`,
  empty).
- Dock (both outputs): workspace-1 card with two thunar icons, workspace-3 card
  with one thunar icon, plus an empty-workspace card.

## Matrix

The owner performs each case with the real pointer; the gate reads the
navigation log and the destination state afterwards. "Dwell" is 500 ms.

| # | Case | Source | Target hovered | Release | Pass criteria |
| --- | --- | --- | --- | --- | --- |
| A | Same-workspace window activation | `payload-a.txt` from **src** | green thunar icon in the workspace-1 card | inside **dst-same** | exactly one copy in `dst-same`; source intact; no repeated activation |
| B | Cross-workspace window activation | `payload-b.txt` from **src** | green thunar icon in the workspace-3 card | inside **dst-cross** | workspace 3 becomes visible; exactly one copy in `dst-cross`; source intact |
| C | Cross-workspace workspace activation | `payload-shot.png` from **src** | workspace-3 header (red box left of the single thunar icon) | inside **dst-cross** | workspace 3 focused; exactly one copy in `dst-cross`; no window pull |
| D | Rejected release on a navigation target | a second file from **src** | any green/red target | released **on** the dock target | source file still present; drag terminates without a stuck grab; no content written anywhere |
| E | Escape cancellation | a file from **src** | any green/red target | pressed `Escape` while hovering | drag cancels; source intact; focus stays on the reached destination (no restore) |
| F | Selected-text drag (GTK text source) | text selected in **src** location bar (`Ctrl+L`) | green thunar icon (workspace 1) | inside **dst-same** location bar (`Ctrl+L`) | destination entry contains the dragged text |
| G | Action cursor | any of the above | navigation target entry | — | observation only: does the drag cursor change shape when the target accepts? |
| H | Pointer warp on activation | any of the above | window/workspace target | — | observation only: does the pointer jump when the target activates? |
| I | Browser image/link drag | browser page | any target | browser/text field | **NOT EXECUTED unless a browser is available in the guest** |

## Results

No case was performed. Every row in the matrix is **NOT EXECUTED**.

| # | Result | Reason |
| --- | --- | --- |
| A–F | NOT EXECUTED | Owner halted the KVM route before performing them |
| G–H | NOT EXECUTED | Observations belong to the same run |
| I | NOT EXECUTED | No browser in the guest image; needs re-provisioning |

Nothing here is evidence that a real external drag survives activation, and
nothing here is evidence that it does not. The gate remains open.

## Handoff

The gate moved to a real desktop (no KVM) because the guest route could not be
driven by the owner on this machine. What the next agent inherits:

- This document: the instrumentation contract, the case matrix (A–I), the
  pass criteria and the evidence format. Reuse them as-is on the target machine.
- `feat/external-drag-hover-navigation` (`heads/0f5fb7d`, from `origin/main`
  `ff7d452`): Task 2 is implemented and unit-tested. Two adapter decisions are
  deliberately unresolved until this gate returns a result:
  1. Whether entry acceptance (`drag.accepted = true` in `onEntered` /
     `onPositionChanged`) changes the action cursor or breaks the final drop.
  2. Whether a focus/workspace change during the drag emits a spurious
     `onExited`/unmap that the adapter must distinguish from a genuine exit.
  Also outstanding: whether `focusToplevelInPlace` warps the pointer.
- The temporary prototype in this branch was reverted before commit. Its shape
  is described under "Instrumentation" and can be re-created from this document
  in minutes; it is a non-visual `DropArea` with empty `keys`, one 500 ms dwell
  timer, format-name-only logging and `drop.accepted = false`.
- Do not re-use the KVM harness deviations below as precedent on a real desktop:
  they were local, uncommitted workarounds for a guest started while the owner
  was active.

Run this gate on the target machine before wiring Tasks 3–5 further, and record
the real per-case results here.

## Evidence

- Session evidence root: `~/.local/state/smartdock/dev-sessions/edhn-t1-j/evidence/`
- Navigation log: guest `/tmp/edhn-t1.log` (copied into the evidence root)
- Screenshots: `frame-NNN.png` in the evidence root, plus the annotated target
  map at `Storage/design-export/edhn-t1-gate-map.png`

## Verdict

**NO-GO as unproven (gate open), not as failed.** No case ran, so the plan's
"final drop survives for files, images and text" condition was never tested. The
gate is GO only if the file cases (A–C) deliver exactly once and the cancellation
cases (D–E) leave the source intact on the target machine. Tasks 3–5 must not be
treated as qualified until this matrix is filled in.
