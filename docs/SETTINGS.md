# Dockrail Settings 3.1 — accepted design record

## Status and evidence

This document records the owner-accepted Dockrail 3.1 Settings design from FDM-1022/FDM-1023, accepted on 2026-09-26 and re-frozen from the dated text export on 2026-10-21.

**SET-01 is documentation and policy only. The Settings UI is not shipped by this change.** UI implementation starts in later SET issues after the schema metadata foundation. Accepted entry points, IPC, and the `dockrail settings` command described below are design requirements, not claims about the current executable surface.

The original design pass inspected **Omarchy 4.0.4** first-party network, audio and Bluetooth panels against Dockrail `main@2889f13`. The SET-00 source baseline inspected was Dockrail `main@994de311ed00b0f90ca6437e21c8bc64e8cd386c`. The installed Omarchy revision and exact native `shell/Ui` and `shell/Commons` compatibility are **not verifiable in the remote GitHub environment**; SET-03 must inspect and record them before native UI work and its smoke check.

**Frozen sources:** `dockrail-settings-implementation-plan-rev18.md` and `dockrail-settings-design-canvas-2026-10-21.md`, attached to Linear FDM-1022/FDM-1040. The latter is the full 14-board export captured 2026-10-21 (board 13 Mapping, board 14 Spec). The plan **wins where it conflicts with the canvas**. The private page does not expose a version number: the plan calls it v58, but this record freezes the attachment and capture date instead.

Original canvas: https://claude.ai/artifact/2hMEW7BB2rGoakSLF3sM3b

## Policy: two audiences, one writer

Dockrail has two configuration audiences:

- **AI coding agents and automation use the CLI.** It remains the complete agent interface.
- **People use Settings.** The accepted Settings panel makes ordinary configuration discoverable without requiring a terminal.
- Both interfaces submit the same host intents through the **single host FileView/settings writer**. They share the same validation, latest-state application, persistence, retry, and readback semantics.
- QML does not write `dock.json` directly. There is no second writer and no preview-only preference layer.
- **Change Icon is the sole icon editor.** Settings can hand the shared editing slot to Change Icon, but must not implement another icon editor.
- The accepted 3.1 surface in this document is the boundary. Do not add another Settings/preferences surface outside it.

## Surface

Settings is a single host-owned Omarchy **`KeyboardPanel`**, approximately **680 px wide**, with **two panes**:

1. section navigation and search on the left;
2. the selected section's controls on the right.

There is one host-wide instance, not one instance per screen. It is dock-anchored, moves to the monitor that opened it, and grows with content until the monitor limit, then scrolls.

The accepted entry points for later implementation are Dock Controls, the sidebar/icon-rail header, an IPC target, and `dockrail settings`. All entry points open the same host-owned panel.

## Sections and setting homes

Each setting has one **canonical** editing home. Features additionally offers schema-defined aggregate shortcut switches over those canonical values, not a competing editor.

| Section | Home |
| --- | --- |
| **Appearance** | Icon size, hover magnification and reach, hover glow, background opacity, interface animations, theme/custom colours, and theme/custom border width. |
| **Layout** | Per-monitor Classic/Sidebar presentation, sidebar edge/width, classic auto-hide/reserved space/margin, and **Displays**, **Sidebar**, **Classic dock** cards. Classic dock contains Size and position, Hiding, and Apps on the dock (Arrange apps tiles with dependent controls). |
| **Behavior · Pointer** | Left click, middle click, and scroll actions. Destructive actions such as closing an app's windows are marked as destructive. |
| **Behavior · Windows** | Window previews, external drag navigation, and its dwell delay. The drag controls apply to both presentations. |
| **Behavior · Attention** | Attention badges, urgent nudge, launcher badge style/count behavior, Herdr agent state on terminal icons, and Claude Desktop session indicators. |
| **Sidebar & Widgets** | Enabled/ordered sidebar widgets, including `herdr.agents`; one ordered list with an **Off** group and a Create widget form. Compact workspace rows move to Layout › Sidebar; Chrome tabs move to Apps › Chrome. Widget collapse stays on its card. |
| **Features** | Independent runtime readiness badges and aggregate feature switches for Chrome, Coding agents and Launcher counts, plus explicit Add/Remove launchers; Python detection through the asynchronous INF-2 bridge, with refresh on open/focus and polling only while visible and needed. |
| **Apps** | Pinned apps, hidden apps, Show Trash, and discovery/reset of custom-icon rules by handing off to Change Icon. |
| **Apps · Chrome** | Chrome profile badges, **Chrome tabs under windows**, and muted unread services. |
| **Apps · Advanced** | `controlCommand`, saved explicitly and never executed by Settings. |
| **Search** | Search across schema labels, keys, and help text, returning the owning section and jumping to the row. |
| **First run / legacy** | Welcome content only when no `dock.json` exists; one-click conversion of legacy `sidebarMonitor` to per-monitor choices. |

Four schema keys are intentionally not ordinary generated controls: `position` is shown as the fixed classic placement, `groupWindows` is deprecated, `sidebarWidgetCollapsed` is edited in place on its widget card, and legacy `sidebarMonitor` appears through the conversion banner.

## Interaction rules

- **Apply on change.** Ordinary controls submit an actual host write; there is no hidden preview state.
- **Sliders commit on release.** Keyboard stepping settles before commit; shown values follow effective normalization rather than pretending every requested intermediate value is renderable.
- **Paired theme controls write one patch.** Colour and border-width controls offer **Theme default** or a custom value; choosing a custom value updates its paired enabled flag atomically.
- **Dependencies come from schema metadata.** Disabled/dependent controls use readable dim help text. Amber is reserved for real warnings.
- **Classic visibility rule.** When all monitors use Sidebar, classic-only cards stay visible with a **Not in use** badge; they never collapse into one row. Visibility and effective applicability are separate.
- **One-monitor presentation writes that monitor's own entry.** With one monitor, Settings shows **Classic dock | Sidebar**; the multi-monitor matrix appears only with two or more monitors.
- **One editing slot.** Settings shares the host-wide editing slot with Change Icon. Opening one closes the other; late results from the old editing surface must not win.
- **Live updates are visible.** CLI or other accepted host writes update the open page. A changed row is marked “Changed elsewhere” rather than silently overwriting an active text draft.
- **Stale text drafts conflict explicitly.** An `E_STALE` response produces a conflict prompt; it is not auto-retried over newer state.
- **Per-row reset is retained.** Reset acts through the same host writer and does not restore the removed page's broad hidden reset behavior.
- **Setup guidance vs typed actions.** Guidance for `dockrail setup --feature chrome|herdr|launcher-counts` is copy-only. INF-3 explicitly allows validated typed `widget create`, confirmed `widget install`, and explicit `launchers add|remove`; fixed argv, no shell, single-flight, structured responses. No general command runner, direct config file writes, or `controlCommand` execution.
- `controlCommand` is visible only under Advanced and is **never executed for validation or by Settings**.
- Right-click menus and drag interactions remain the primary in-dock app-management interactions; Settings provides a discoverable place to review and undo them.

## Save, live-update, and error states

| State | Accepted behavior |
| --- | --- |
| **Saving** | A write is in progress; do not send a duplicate mutation as though the first were rejected. |
| **Saved** | Confirm the durable write, then fade the Saved indicator after about two seconds. |
| **Not saved** / `E_PERSISTENCE` | Keep the applied live value visible, pin the error, and offer **Retry** through the same persistence retry path as `config retry`. |
| `E_VALIDATION` | Reject the write and keep the user's field text so it can be corrected. |
| `E_CONFIG_INVALID` | Make Settings read-only until the invalid configuration is repaired; do not replace it with defaults. |
| **Changed elsewhere** | Reflect a live host update and highlight the affected row. |
| `E_STALE` | For an active text draft, show a conflict decision instead of overwriting the newer value. |
| **Requested vs shown** | Preserve requested intent while displaying normalized/effective values honestly. |

Errors remain pinned until resolved. Informational Saved feedback is transient.

## Lessons from the removed Settings page

FDM-918 removed the previous Settings implementation in commit `0dbd7c54151577457deb45b3cf282b37fb2fc258`. The accepted 3.1 design deliberately avoids the failure modes captured during that removal and the FDM-1022 review:

| Removed-page problem | 3.1 correction |
| --- | --- |
| A Settings surface was created per screen. | One host-owned panel and one editing session. |
| Hidden preview state could diverge from saved state. | No preview-only preferences; every change uses the real host writer. |
| Write failures had no honest UI state. | Saving/Saved/Not saved, validation, invalid-config, stale, and retry states are explicit. |
| Reset could broadly reset preferences, including executable `controlCommand`. | Settings uses schema-driven, scoped controls and per-row reset; `controlCommand` is Advanced and never executed. |
| A hand-built `PanelWindow`, focus timers, and a separate component kit duplicated shell behavior. | Compose Omarchy `qs.Ui` controls and `qs.Commons` tokens around Dockrail-specific behavior. |
| About 1,379 hardcoded QML lines covered only part of the settings and drifted from the CLI/schema. | Generate controls from `config/settings-schema.json` UI metadata; one home per key. |
| Validation mostly grepped QML text. | Later SET implementation tests exercise the real host writer, persistence errors/retry, stale writes, live updates, and panel ownership. |

Do not restore the deleted FDM-918 components or their obsolete validation paths.

## Decided

The accepted design has no open design questions. These decisions are binding for the 3.1 Settings implementation:

- Use one host-owned Omarchy `KeyboardPanel`, about 680 px wide, with two panes.
- Open on the section for the current presentation mode and remember the last section.
- Keep classic-only cards visible as **Not in use**, reversing the old collapse-row decision.
- With one monitor, show Classic dock/Sidebar and write that monitor's own `presentationModeByMonitor` entry; use the monitor matrix only for two or more monitors.
- Keep Arrange apps mode and its dependent settings together inside **Layout › Classic dock › Apps on the dock** (Single row vs Card per workspace).
- Settings is the on/off surface for the `herdr.agents` widget; do not change the Herdr provider lifecycle to implement it.
- Feature shortcuts are **aggregate** switches, while all individual settings keep one canonical home and the readiness badge remains independent.
- Use the shared readiness projection; do not duplicate feature detection in Settings.
- Sliders commit on release.
- Use one colour control and one border-width control with **Theme default** or a custom value.
- Keep Chrome profile badges, muted services **and Chrome tabs** in **Apps · Chrome**.
- Keep launcher-count presentation, Herdr terminal-icon state and Claude Desktop session indicators in **Behavior · Attention**.
- Include Apps, while context menus and dragging remain primary.
- Keep Change Icon as the only icon editor and share its editing slot with Settings.
- Put `controlCommand` under Advanced and never execute it from Settings.
- Provide one-click conversion for legacy `sidebarMonitor`.
- Search labels, keys, and help text across the schema.
- Show the first-run welcome only when no `dock.json` exists; do not add a dismiss preference.
- Provide the accepted IPC target and `dockrail settings` entry point in the implementation slice; SET-01 does not add them.
- Show the final `dockrail setup --feature chrome|herdr|launcher-counts|agent-launchers` guidance, but allow only INF-3's named validated widget and launcher actions to run directly; launchers never install automatically.
- Rename the sidebar's legacy “SmartDock” accessibility label when the Settings shell is implemented.
- Hide demo widgets from production Settings.
- Use readable dependency hints; reserve amber for actual warnings.
- Keep the single host writer, preserve live reload, unknown keys and collection order, and never execute `controlCommand`.

## Frozen contract changes — 2026-10-21

The plan rev 18 reverses four older binding choices:

1. **Classic settings stay visible**, marked "Not in use" for sidebar-only users, instead of collapsing into one row: discoverability without changing display modes.
2. **Chrome tabs live in Apps › Chrome**, not Sidebar & Widgets: all Chrome integration preferences are together.
3. **Features has aggregate switches** alongside independent runtime badges, while the same keys retain exactly one canonical editing home.
4. **Settings may start named typed Dockrail actions** rather than being universally copy-only: validation, per-action fixed argv, confirmation and single-flight mitigate execution risk.

Use **native titled cards with icons and right-side badges**, readable descriptions, semantic tokens from `qs.Ui`/`qs.Commons`, and a distinct navigation column with separators. Appearance is five cards: Icons, Hover glow, Dock surface, Workspace badges, Motion. Layout is Displays, Sidebar, and Classic dock (Size and position, Hiding, Apps on the dock); the classic **Placement** row is removed. Monitor order belongs to Displays, hidden for one monitor, and Compact workspace rows belongs to Layout › Sidebar. One monitor always writes its own `presentationModeByMonitor` entry. Arrange apps offers Single row or Card per workspace tiles and reveals only that arrangement's settings.

### Feature aggregates (schema, not parallel editors)

| Shortcut | Canonical source | Off | On |
| --- | --- | --- | --- |
| Chrome | `browserProfileBadgesEnabled`, `sidebarBrowserTabsEnabled` in Apps › Chrome | both false | both true |
| Coding agents | `herdr.agents` in `sidebarWidgets` (Sidebar & Widgets), `dockHerdrIndicators` (Behavior › Attention) | both off | both on |
| Launcher counts | `launcherBadgeMode` (Behavior › Attention) | `dots-only` | `automatic` |
| Agent launchers | installed owned files, not config | no switch | no switch |

Mixed source values show **Partly on**; clicking means On, clicking again means Off. Coding agents appends/removes only its own widget ID, preserving unknown IDs and ordering. Shortcut activation never installs, and does not change a readiness badge by itself.

### Shared execution contracts

- **INF-1 writer:** a host-owned patch carries an expected starting value for *every* touched key, compared structurally before commit. Any changed key returns `E_STALE` without writing. An accepted write still saving (`E_BUSY`) returns `{accepted:true,pending:true,reply}`. Existing single FileView writer, applied/persisted/readback, and live reload remain authoritative.
- **INF-2 readiness:** Python `feature_readiness()` stays the **only detector**, compatible with existing doctor/status summaries. Add separate `configuration` (off/partly-on/on), `installation` (missing/installed), `runtime` (unavailable/limited/ready) and `nextAction` (enable/configure/install/learn-more, with human text). A QML bridge calls `dockrail doctor --json` asynchronously with a timeout, one call in flight, last-good cache, refresh on panel open/focus, polling only when visible and any runtime badge is not Ready.
- **INF-3 typed actions:** only fixed-argv `widget create ID --name NAME`, `widget install SOURCE`, `launchers add`, `launchers remove`, never a shell/generic process runner or `controlCommand`. Validate inputs and package manifest using existing CLI rules, reject collisions, confirm source/ID/name/replacement *before* install; report structured progress/errors. Create and install are separate actions, and widgets land **Off**. After Create, **offer Open folder** rather than opening automatically.
- **INF-4 launchers:** explicit Add detects available commands on PATH, writes only matching launchers, tracks owned filename and content hash. Remove only matching owned files, retaining edited or foreign desktop files. Readiness is based on detected agents, not every possible agent. Herdr launcher icon is original or licensed with `assets/terminal-agents/ATTRIBUTIONS.md`.
- **INF-5 launcher counts:** setup checks CMake and compiler availability and prints one Arch/Omarchy install command when missing; it never auto-builds.

### Section-specific behavior

Widgets: one enabled-order list and **Off** group, grip + keyboard **Alt+↑/↓**, inline Add new widget (create, then confirmed install). Apps: Pinned/Hidden/Custom icons/Chrome/Dock items/Advanced; drag and **Alt+↑/↓** (no up/down buttons), × removes an icon mapping, **Change…** delegates to the single Change Icon editor, Advanced is a plain card for explicitly saved `controlCommand`. Layout Classic dock cards remain visible when marked Not in use. Errors and Changed elsewhere remain honest; sliders commit on release, text conflicts offer Reload or Keep editing, and Saved fades after about two seconds. Search uses the SET-03 registry and first run appears only without `dock.json`; legacy `sidebarMonitor` receives a one-click conversion banner.

### Canonical setting mapping (frozen canvas board 13)

All **62 settings** appear below. The plan's four reversals and moved homes override stale lines elsewhere in the canvas. Color/border *Enabled flags are paired into one primary control; `position` (fixed bottom), `groupWindows` (deprecated), `sidebarWidgetCollapsed` (in-place), and `sidebarMonitor` (legacy banner) have no ordinary generated row.

| Key | Section | Group | Label |
| --- | --- | --- | --- |
| `iconSize` | Appearance | Icons | Icon size |
| `magnification` | Appearance | Icons | Hover magnification |
| `magnificationRadius` | Appearance | Icons | Magnification reach |
| `hoverGlowEnabled` | Appearance | Hover glow | Hover glow |
| `hoverGlowOpacity` | Appearance | Hover glow | Glow strength |
| `hoverGlowRadius` | Appearance | Hover glow | Glow radius |
| `backgroundOpacity` | Appearance | Dock surface | Background opacity |
| `backgroundColor` | Appearance | Dock surface | Background color |
| `backgroundColorEnabled` | Appearance | Dock surface | (set by Background color) |
| `borderColor` | Appearance | Dock surface | Border color |
| `borderColorEnabled` | Appearance | Dock surface | (set by Border color) |
| `borderWidth` | Appearance | Dock surface | Border width |
| `borderWidthEnabled` | Appearance | Dock surface | (set by Border width) |
| `workspaceBadgeBackgroundColor` | Appearance | Workspace badges | Badge background |
| `workspaceBadgeBackgroundColorEnabled` | Appearance | Workspace badges | (set by Badge background) |
| `workspaceBadgeTextColor` | Appearance | Workspace badges | Badge text color |
| `workspaceBadgeTextColorEnabled` | Appearance | Workspace badges | (set by Badge text color) |
| `interfaceAnimationsEnabled` | Appearance | Motion | Interface animations |
| `presentationModeByMonitor` | Layout | Displays | Monitor choice |
| `sidebarCollapsedByMonitor` | Layout | Displays | Icon rail |
| `presentationMode` | Layout | Displays | Other monitors |
| `sidebarCollapsed` | Layout | Displays | Icon rail (other monitors) |
| `sidebarMonitor` | Layout | Displays | Legacy banner |
| `workspaceMonitorOrder` | Layout | Displays | Automatic monitor order |
| `sidebarEdge` | Layout | Sidebar | Edge |
| `sidebarExpandedWidth` | Layout | Sidebar | Width |
| `sidebarInlineSoloWorkspace` | Layout | Sidebar | Compact workspace rows |
| `position` | Layout | Classic dock | No row of its own |
| `fullLength` | Layout | Classic dock · Size and position | Full width |
| `autoHide` | Layout | Classic dock · Hiding | Auto-hide |
| `reserveSpace` | Layout | Classic dock · Hiding | Reserve screen space |
| `margin` | Layout | Classic dock · Size and position | Edge margin |
| `workspaceLayout` | Layout | Classic dock · Apps on the dock | Arrange apps |
| `workspaceMonitorScope` | Layout | Classic dock · Apps on the dock | Cards include |
| `windowScope` | Layout | Classic dock · Apps on the dock | Show windows from |
| `showUrgentOutsideScope` | Layout | Classic dock · Apps on the dock | Always show urgent windows |
| `sortByWorkspace` | Layout | Classic dock · Apps on the dock | Sort by workspace |
| `clickAction` | Behavior | Pointer | Left click |
| `middleClickAction` | Behavior | Pointer | Middle click |
| `scrollAction` | Behavior | Pointer | Scroll |
| `showPreviews` | Behavior | Windows | Window previews |
| `dragHoverNavigationEnabled` | Behavior | Windows | External drag navigation |
| `dragHoverDelayMs` | Behavior | Windows | Drag hover delay |
| `workspaceGroups` | Behavior | Windows | Grouped apps |
| `attentionBadgesEnabled` | Behavior | Attention | Attention badges |
| `launcherBadgeMode` | Behavior | Attention | Badge style |
| `urgentWindowAnimationEnabled` | Behavior | Attention on the dock | Urgent nudge |
| `dockHerdrIndicators` | Behavior | Attention on the dock | Agent state on terminal icons |
| `dockT3Indicators` | Behavior | Attention on the dock | T3 Code threads on dock icons |
| `dockClaudeIndicators` | Behavior | Attention | Claude Desktop session indicators |
| `groupWindows` | Behavior | — | Not shown |
| `sidebarWidgets` | Sidebar & Widgets | Widgets | Widgets list |
| `sidebarWidgetCollapsed` | Sidebar & Widgets | — | Not shown |
| `pinned` | Apps | Pinned | Pinned apps |
| `hiddenApplications` | Apps | Hidden | Hidden apps |
| `iconOverrides` | Apps | Custom icons | App and profile icons |
| `windowIconOverrides` | Apps | Custom icons | Window-title rules |
| `browserProfileBadgesEnabled` | Apps | Chrome | Profile badges |
| `sidebarBrowserTabsEnabled` | Apps | Apps · Chrome | Chrome tabs under windows |
| `browserActivityMutedServices` | Apps | Chrome | Muted unread services |
| `showTrash` | Apps | Dock items | Show Trash |
| `controlCommand` | Apps | Advanced | App launcher command |

### Implementation test gates

SET-02 must prove every key has a section or hidden/in-place reason; dependencies reference existing keys; symmetric pairs; aggregate shortcut ownership; and a pure static classic-only inventory matches the host's `inactiveClassicSettings`, including the missing `dockHerdrIndicators`. INF-1 and SET-03 test writer conflicts, busy/persistence/readback, validation and live updates using qmltestrunner rather than grep of source. SET-03 requires real Omarchy native smoke evidence for four entry points and CLI round trips, and SET-LOCAL performs the final focus/keyboard/monitor/theme/launcher/shortcut check.

**SET-00 changes only the design record. This does not ship a Settings panel.**
