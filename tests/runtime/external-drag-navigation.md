# External drag hover navigation — real-app runtime matrix (Task 1 feasibility gate)

Status: **EXECUTED — GO for the sidebar and classic-dock routes that exist.**
The gate ran on the owner's live Omarchy desktop with the real compositor, real
applications and real Wayland DnD transfers, first against
`feat/edhn-surfaces @ 4c2909f` and `fe10d67` (agent-driven), then hands-on
against the merged installed dock `c4385fd` (owner-driven). Sidebar rows, badges,
mirrored cross-monitor targets, the classic running-icon target, multiwindow
preview tiles, and text/image drags are qualified. Two rows stay open: the
classic reveal strip while a content drag is held, and XWayland sources.

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
| Branch | `feat/edhn-surfaces` |
| Executed head | `4c2909fbc2047594aac39bfe7339dd056da45ee7` |
| Host Hyprland | `0.56.2-4` (built from v0.56.2, commit `efb5099`) |
| Host Quickshell | `0.3.2` (rev `2b4501a`, Omarchy) |
| Host Qt Wayland | `6.12.0-1` |
| File manager | GNOME nautilus `51.1` (source and destination) |
| Displays | DP-1 1920x1080 (classic dock) and HDMI-A-1 1920x1080 (sidebar) |
| Input path | `ydotool` uinput virtual mouse + `hyprctl` cursor warps |

The earlier KVM guest attempt (`edhn-t1-j`, Hyprland 0.57.0, thunar 4.20.10)
staged identical instrumentation but performed no case; it is kept below only as
the staging that preceded this run.

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
- The intended guest run above never performed a case; the executed run used the
  owner's live desktop, so those guest deviations describe staging only.
- The executed run's drags were driven by a `ydotool` uinput virtual mouse, not
  a human hand and not the desktop owner's own pointer. See "Input method"
  under Results for exactly what that does and does not substitute for.
- Guest dock settings differ from host settings only inside the guest:
  `workspaceLayout: grouped`, `iconSize: 56`, `autoHide: false`,
  `showPreviews: true`. Theme files (`colors.toml`, `shell.toml`) were copied
  into the guest so Omarchy `Color`/`Style` resolve.

## Desktop layout used

- HDMI-A-1, workspace 11: two nautilus windows tiled — **src**
  (`/var/tmp/edhn-live/src`) and, for the first case, **dst**
  (`/var/tmp/edhn-live/dst`).
- Workspace 99 (`Work`) on HDMI-A-1: **dst** moved there for the cross-workspace
  case.
- Sidebar on HDMI-A-1 showed the workspace 11 group (T3 Code, ComfyUI, `src`)
  and the workspace 99 group whose inline badge was the cross-workspace target.
- DP-1 kept its classic dock and the T3 Code window untouched.

## Matrix

Each case is performed with the pointer over the real dock; the result is read
from the destination directory and the compositor state afterwards, never from a
log line alone. "Dwell" is 500 ms.

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

Executed 2026-11-04 on the owner's live desktop, not in a guest. Source
`feat/edhn-surfaces @ 4c2909f` selected with `dockrail dev use`, sidebar
presentation on the HDMI-A-1 output, classic presentation untouched on DP-1.
Settings: defaults (`dragHoverNavigationEnabled: true`,
`dragHoverDelayMs: 500`). Desktop restored with `dockrail dev reset` afterwards.

| # | Result | Evidence |
| --- | --- | --- |
| A | **PASS** | `payload-b.txt` dragged from the **src** nautilus window onto the **dst** sidebar window row. The row activated `dst` during the drag; the file was released inside `dst` and appeared there exactly once; `src` no longer held it. |
| B/C | **PASS** | `payload-a.txt` dragged from **src** onto the inline workspace badge of the workspace 99 group. HDMI-A-1 switched from workspace 11 to workspace 99 **while the drag was still held**; the file was released inside `dst` on that workspace and appeared exactly once. |
| D | **PASS** | A fresh file dragged onto a sidebar target and released **on** the dock. `drop.accepted = false`: the source kept the file, nothing was copied or moved anywhere, and subsequent input worked normally (no stuck grab). |
| E | **PASS** | Escape pressed while hovering a sidebar target with the button held: the drag ended, the source kept the file, nothing was transferred. |
| G | NOT MEASURED | Cursor shape was not captured reliably at the moment of target entry. |
| H | **PASS (no warp)** | On activation the pointer stayed where it was placed; only focus and the workspace changed. No pointer jump was observed in any case. |
| I | NOT EXECUTED | No browser image/link drag was attempted in this run. |
| — | NOT EXECUTED | Multiwindow icon → window-preview → exact-tile selection, and every classic-dock target: Task 4 is not implemented, so those targets do not exist yet in the candidate. |

### What this proves and what it does not

Proven: a real external file drag survives both an in-place window focus and a
workspace switch triggered by Dockrail, and the destination application receives
the content exactly once. Releasing on Dockrail does not steal the content, and
Escape leaves the source intact.

Not proven: non-file MIME types (text, browser image/link), the classic bottom
dock, multiwindow preview selection, XWayland sources, and any behaviour that
depends on Task 4's wiring.

### Input method (recorded for honesty)

The drags were driven by a **uinput virtual mouse** (`ydotool`): positions were
set with `hyprctl` cursor warps and button/motion events came from the virtual
device, so Hyprland, the Wayland data device, GTK drag-and-drop and nautilus all
behaved as they do for a physical mouse. No Qt drag API, clipboard transfer,
synthetic mouse release inside an application, or payload extraction was used.
A human hand on the same desktop would exercise the identical path; the only
synthetic element is the input device itself.

Harness note: `ydotool` absolute moves were mis-scaled by pointer acceleration,
so motion was sent as small relative steps converged against `hyprctl cursorpos`.

## Handoff

The gate ran on the owner's live desktop. What the next agent inherits:

- This document: the executed matrix, the input method, and the remaining gaps.
- `feat/edhn-surfaces` (`4c2909f`, stacked on `origin/main` `ff7d452`): Task 2
  and Task 3 are implemented and unit-tested, and the sidebar routes in them are
  now qualified by the run above.
- The two adapter decisions this gate existed for are answered for the sidebar
  window/workspace routes: entry acceptance did not break the transfer and focus
  or workspace changes did not cancel the source drag. The cursor *shape* on
  entry (case G) is still unmeasured.
- Task 4 is still unimplemented, so every classic-dock and multiwindow-preview
  route remains unqualified. Do not claim them until they are built and run.
- Task 5's broad app matrix (text, images, XWayland) is still open. The KVM
  staging artifacts under "Instrumentation" and the guest deviations are history,
  not precedent.

## Evidence

- Destination checks: `ls` of `/var/tmp/edhn-live/src` and `/var/tmp/edhn-live/dst`
  after each case (`payload-a.txt` and `payload-b.txt` each present exactly once
  in `dst`, absent from `src`; `payload-c.txt` retained in `src` after D and E).
- Compositor state: `hyprctl activewindow` showed the destination toplevel focused
  mid-drag for A; `hyprctl monitors` showed HDMI-A-1 on `Work` mid-drag for B/C.
- Screenshots captured during the run (host `/run/user/1000/hypruse/`): the drag
  cursor thumbnail over the sidebar row, over the workspace badge, and inside the
  destination window before release.
- The staged KVM session's frames and control map remain under
  `~/.local/state/smartdock/dev-sessions/edhn-t1-j/evidence/` and
  `Storage/design-export/edhn-t1-gate-map.png`; they belong to the unexecuted
  guest staging, not to the results above.

## Classic dock run (2026-11-04, second pass)

Same branch, after Task 4. `dockrail dev use`, classic dock on HDMI-A-1,
defaults plus `showPreviews: true`. All temporary settings (`autoHide`,
`groupWindows`) were restored and the installed copy re-selected afterwards.

| Case | Result | Evidence |
| --- | --- | --- |
| C1 — classic icon window target | **PASS** | `payload-t.txt` dragged from **src** onto the icon of the non-focused `dstA` window. The dwell activated `dstA` while the drag was held; the file was released inside it and appeared exactly once. |
| C2 — normal reveal | **PASS** (existing behaviour) | With `autoHide: true`, a plain hover at the bottom edge revealed the dock. |
| C3 — reveal while a content drag is held | NOT QUALIFIED | The drag ended when the pointer left the last window for the bare bottom strip; the dock did not reveal. Normal hover reveal works, so this is specific to the drag-held path and needs investigation with a real hand before it is claimed. |
| C4 — multiwindow icon → preview → exact tile | **PASS (owner, 2026-11-04)** | Grouped with the context-menu **Group Windows** action, then a real drag hovered the grouped icon: the preview opened at the dwell, hovering a specific tile focused that exact window, and the drop landed. The original not-run note below explained why the default per-window layout could not reach this path. |
| C5 — release on the classic dock, Escape | NOT EXECUTED | The sidebar equivalents passed; the classic surface was not repeated for these two. |

## Owner verification (2026-11-04, hands-on)

After the merge, the desktop owner ran the gesture themselves with a real mouse on
the installed dock (`c4385fd`) and reported no oddities. These are human
observations, not instrumented runs: no logging, no recordings, no timing
capture.

| Case | Result | What was exercised |
| --- | --- | --- |
| Basic gesture | **PASS** | File drag onto a dock icon focused the target window mid-drag and the drop landed. A workspace target switched workspace on hover. Releasing on the dock left the file where it was. |
| Multiwindow preview → exact tile | **PASS** | With windows grouped via the context-menu **Group Windows** action, hovering the grouped icon opened the preview at the dwell and hovering a specific tile focused that exact window; the drop landed. |
| Text and image drags | **PASS** | Selected text dragged onto a dock target, and an image dragged off a page into a folder. Both navigated and delivered. |
| Mirrored sidebar across monitors | **PASS** | With the sidebar mirrored on both outputs, a drag started on one screen activated a target row on the other and the drag continued. |

The owner reported no glitches: no stuck dock, no flicker, no lost files, no
cursor oddity noticed.

## Verdict and remaining gaps

**Qualified:** sidebar window rows, workspace rows, inline workspace badges and
mirrored cross-monitor targets; the classic bottom dock's running-icon target;
multiwindow preview → exact tile with grouped windows; text and image performs;
and the cancellation rules (release on Dockrail, Escape) on the sidebar surface.

**Not qualified, and must not be claimed:** the classic reveal strip while a
content drag is held (C3), XWayland sources, release/Escape repeated on the
classic surface (C5), and a precise action-cursor-shape measurement. The owner
saw nothing wrong with the cursor, which is weaker than a measured observation.

The two adapter decisions this gate was opened for are now answered for these
paths:

1. Accepting drag entry does **not** appear to alter the action cursor or break
   the final drop — every drop delivered once, including after a workspace
   switch. (Case G's cursor *shape* was not measured, so treat the "cursor does
   not change" half as unconfirmed.)
2. A focus or workspace change during the drag did **not** cancel the source
   drag and did not produce a spurious exit that ended the session; the transfer
   completed after activation. The adapter's current `onExited` handling is
   therefore adequate for these two routes.
3. `focusToplevelInPlace` did **not** warp the pointer.
