# Dockrail configuration inventory

**Configuration reference.** Discover `dockrail config schema --json` on the selected running host before changing it. Its keyed metadata and `config/dock.json` are the runtime/default authorities; this table is a tested reference, not a second settings engine or a replacement for the user's configuration.

Use [the agent workflow](AGENT_CONFIGURATION.md) for minimal, reversible changes and [the CLI reference](CLI_REFERENCE.md) for command/output/error details. The CLI configures preferences, and Change Icon is the sole icon editor. The accepted Settings 3.1 design is not shipped yet; ordinary dock menus, app picker and window previews remain.

## All declared settings

Defaults below are JSON literals. `tests/test_cli_docs.py` checks these 60 rows against the shipped defaults. Bounds apply to new CLI writes; compatible legacy requested values survive unrelated changes. There is no automatic whole-file migration.

| Key | Declared default | New-write type, limits and dependencies |
| --- | --- | --- |
| `iconOverrides` | `{}` | Object mapping canonical app IDs to local PNG/SVG sources; prefer per-app intents. Preserved by preference reset. |
| `windowIconOverrides` | `[]` | Ordered normalized raw-Wayland app ID/title-pattern rules for local PNG/SVG artwork; first match wins. Preserved by preference reset. |
| `iconSize` | `42` | Integer 24–96 logical pixels. |
| `magnification` | `1.2` | Number 1–2; effective step 0.05. Set 1 for no hover enlargement. |
| `magnificationRadius` | `95` | Number 40–240; effective step 5. |
| `hoverGlowEnabled` | `true` | Boolean; gates the hover glow. |
| `hoverGlowOpacity` | `0.72` | Number 0–1; effective step 0.05. |
| `hoverGlowRadius` | `28` | Number 0–100; effective step 5; relevant when glow is enabled. |
| `showPreviews` | `true` | Boolean; permits ordinary grouped-window previews and the previews pointer action. |
| `dragHoverNavigationEnabled` | `true` | Boolean; dwell on a dock or sidebar window/workspace target while dragging external content to navigate there. Applies to both presentations. |
| `dragHoverDelayMs` | `500` | Integer 100–2000 ms; effective step 100. Dwell time before external drag navigation activates; dimmed while dragHoverNavigationEnabled is false and preserved. |
| `showTrash` | `true` | Boolean; false removes Trash and pauses its polling, never empties it. |
| `margin` | `10` | Nonnegative integer, no arbitrary maximum; preserved by preference reset. |
| `backgroundOpacity` | `0.88` | Number 0–1; effective step 0.05; multiplies background color alpha. |
| `backgroundColorEnabled` | `false` | Boolean; enables the paired background override. |
| `backgroundColor` | `""` | Color string; requires backgroundColorEnabled. |
| `borderColorEnabled` | `false` | Boolean; enables the paired border override. |
| `borderColor` | `""` | Color string; requires borderColorEnabled. |
| `workspaceBadgeBackgroundColorEnabled` | `false` | Boolean; enables the paired workspace-number badge background override. |
| `workspaceBadgeBackgroundColor` | `""` | Color string; requires workspaceBadgeBackgroundColorEnabled. |
| `workspaceBadgeTextColorEnabled` | `false` | Boolean; enables the paired workspace-number badge text override. |
| `workspaceBadgeTextColor` | `""` | Color string; requires workspaceBadgeTextColorEnabled. |
| `borderWidthEnabled` | `false` | Boolean; enables a fixed width instead of theme-owned widths. |
| `borderWidth` | `2` | Integer 0–8 logical pixels; relevant only with borderWidthEnabled. |
| `presentationMode` | `"classic"` | Classic bottom dock or mirrored sidebar panels (the dock's vertical presentation) for connectors without a `presentationModeByMonitor` entry. Drag empty dock background left past the 48 px threshold to switch that monitor to the sidebar, or empty sidebar background down to return; release commits one `presentationModeByMonitor` entry for the source connector, and an early release, Escape or an interrupted drag writes nothing. |
| `presentationModeByMonitor` | `{}` | Object map of exact connector → `classic` or `sidebar`. A listed connector ignores `presentationMode` and `sidebarMonitor`; missing connectors inherit the effective default. Disconnected names retained; control characters and non-mode values rejected. |
| `sidebarEdge` | `"left"` | Sidebar panel edge; leaves classic position unchanged. |
| `sidebarMonitor` | `""` | Empty maps a mirrored panel on every connected screen. A connected connector maps only that output. Disconnected preferences are retained and fall back to all connected screens; control characters are rejected. |
| `sidebarExpandedWidth` | `320` | Requested expanded width in logical pixels. Runtime screen clamping never overwrites this preference; a changed resize release persists only this field. |
| `sidebarCollapsed` | `false` | Default icon rail for monitors without a `sidebarCollapsedByMonitor` override. Expanded width and session app folds are retained. |
| `sidebarCollapsedByMonitor` | `{}` | Object map of exact connector → boolean. Missing connectors follow `sidebarCollapsed`. Disconnected names retained; control characters and non-booleans rejected. |
| `sidebarInlineSoloWorkspace` | `true` | Boolean; when enabled, populated workspace names share the first application/window row instead of emitting a separate workspace row. Empty workspaces remain dedicated rows. |
| `sidebarWidgets` | `[]` | Ordered unique registered internal widget IDs. The array is both enabled state and card order. Runtime schema advertises source-registered IDs; unknown imports remain requested/unavailable. Add/remove/reorder use the host writer. |
| `sidebarWidgetCollapsed` | `{}` | Valid internal widget ID → boolean card-body state. Missing means expanded. Removing a widget keeps its collapse preference so re-adding restores it. Preference reset clears the map. |
| `sidebarBrowserTabsEnabled` | `true` | When true and the browser-profile provider is available, sidebar Chrome window rows can expand to list open page tabs (titles only, no URLs). Independent of `browserActivityMutedServices`. See the [online browser-tabs guide](https://github.com/fernandodamaso/smart-omarchy-dock/blob/370585ccfaed98f1d04954d8598a868aef80a087/docs/browser-tabs.md); it is not part of the offline CLI documentation bundle. |
| `position` | `"bottom"` | Classic dock edge; the classic dock renders on the bottom only and the left vertical presentation is the sidebar mode. Drag empty dock background left to switch to the sidebar, or empty sidebar background down to return; the gesture writes the source connector's `presentationModeByMonitor` entry, never `position`. Legacy left, right and top read as bottom. |
| `fullLength` | `false` | Boolean; extend along the available edge. |
| `reserveSpace` | `true` | Boolean; effective false while autoHide is enabled, without erasing this request. |
| `autoHide` | `false` | Boolean; existing edge-reveal auto-hide, not a new hide-mode enum. |
| `clickAction` | `"focus-or-launch"` | String: none, minimize-restore, previews, close, focus-or-launch. Close is destructive-on-use. |
| `middleClickAction` | `"none"` | Same canonical action vocabulary as clickAction. |
| `scrollAction` | `"none"` | String: none or cycle-windows. |
| `controlCommand` | `"omarchy-menu toggle apps"` | Nonempty string; executable-on-use launcher configuration, never executed by validation. |
| `sortByWorkspace` | `false` | Boolean; flat-layout workspace sorting; closed pins remain first. |
| `workspaceLayout` | `"flat"` | String: flat or grouped. Grouped cards render on the bottom dock only. |
| `workspaceMonitorScope` | `"all"` | String: all or current-monitor; grouped cards only. |
| `workspaceMonitorOrder` | `[]` | Exact case-sensitive connector-name array. Empty uses automatic physical x/y order; configured connected monitors lead, unlisted connected monitors append automatically, and disconnected names remain saved for reconnect. Classic grouped/all and global sidebar presentation; never reconfigures Hyprland monitors. |
| `groupWindows` | `false` | Deprecated/inactive compatibility Boolean. Stored legacy `true` is preserved on read and unrelated writes but never changes presentation; new attempts to enable it are rejected. |
| `workspaceGroups` | `[]` | Strict opt-in `{desktopId, workspace}` pairs. Workspace identities are canonical `id:N` or safe `name:N`; duplicate pairs and ambiguous/special identities are rejected atomically. |
| `interfaceAnimationsEnabled` | `true` | Boolean; interface transitions, not every compositor animation or attention nudge. |
| `windowScope` | `"all"` | String: all, workspace, monitor, workspace-monitor; flat-layout running-window filtering. |
| `showUrgentOutsideScope` | `true` | Boolean; genuinely urgent windows may bypass flat window scope; hidden apps remain hidden. |
| `attentionBadgesEnabled` | `true` | Boolean; gates attention indicators without installing a notification daemon. |
| `urgentWindowAnimationEnabled` | `true` | Boolean; existing bounded attention motion, also gated by attentionBadgesEnabled in rendering. |
| `launcherBadgeMode` | `"automatic"` | String: automatic or dots-only. Uses an already-available provider; does not start/install one. |
| `browserProfileBadgesEnabled` | `true` | Boolean; per-window browser profile corner badges (photo or initial) from the browser-profile provider. No provider or DevTools endpoint means no badges; the setting installs nothing. |
| `dockHerdrIndicators` | `false` | Show Herdr agent state on terminal icons, in hover previews and in the context menu. Uses the existing Herdr provider; enabling it starts that provider while a classic dock is active, including when it is auto-hidden. |
| `dockT3Indicators` | `false` | Show T3 Code thread state on the T3 Code icon, in hover previews and in the context menu. Pair with dockrail t3 pair; requires a classic dock to run for dock-only demand. |
| `dockClaudeIndicators` | `false` | Show Claude Desktop session state on the Claude Desktop dock icon and in its sidebar window row: a working spinner while a session runs, plus input-needed and done marks. The sidebar row also lists one row per session that needs attention. Install the Claude Code hooks with dockrail claude hooks install. |
| `browserActivityMutedServices` | `[]` | Safe service ID array (`gmail`, `whatsapp`, …). Muted rows stay visible and openable but are excluded from Chrome activity header and dock badge totals; retained by preference reset. |
| `hiddenApplications` | `[]` | Safe desktop ID array with no new canonical duplicates; independent of pins and retained by preference reset. |
| `pinned` | `["org.gnome.Nautilus","com.google.Chrome","com.mitchellh.ghostty","code","obsidian","chatgpt"]` | Ordered safe desktop ID array, including unavailable/hidden apps; no new canonical duplicates; retained by preference reset. |

## Requested, effective and rendered

Requested settings retain accepted intent: `hoverGlowOpacity: 0.72` projects to 0.70, `hoverGlowRadius: 28` to 30, and `backgroundOpacity: 0.88` to 0.90. A requested grouped layout survives moving to a vertical edge; effective layout becomes flat and effective workspaceMonitorScope becomes all. Auto-hide makes effective reserveSpace false without rewriting the requested value. New pointer writes require canonical values; stored legacy `focus`/`launch` aliases read effectively as `focus-or-launch` without an unrelated rewrite. Stored legacy `groupWindows: true` remains visible in requested readback but its effective value is always false; no startup rewrite or automatic local-group migration occurs. Use `workspaceGroups` or the context-menu **Group Windows** action instead.

`workspaceMonitorOrder` is normalized only for effective/rendered use. Missing or malformed legacy stored values read effectively as `[]` without startup rewrite; requested readback still exposes the stored bytes so an agent can decide whether to repair them. New writes are atomic: connector entries must be trimmed nonempty strings with no control characters or exact duplicates. Connector matching is case-sensitive, and valid virtual connector names are allowed.

Effective output is a headless projection, not complete rendered truth. Theme-owned/token colors and theme-owned border width are null with a warning. The normalized urgentWindowAnimationEnabled flag does not by itself report badge-gated animation eligibility; the renderer also requires attentionBadgesEnabled and eligible live attention. Numeric launcher counts alone do not trigger motion. Standalone remains dot-only without the plugin-owned provider. Report these dependencies rather than inventing a fully resolved effective value.

Colors accept an empty string, `#RRGGBB`, Qt **`#AARRGGBB`** (alpha first), or a syntactically valid symbolic token. Pair each color with its Enabled flag in one atomic patch. Disabling only that flag restores inheritance without discarding the stored override. An empty override inherits the theme. Unknown symbolic tokens are retained and use renderer fallback rather than being silently deleted; the CLI does not certify that a token exists in the installed theme.

Existing token families include:

```text
@background @foreground @accent @muted @urgent
@bar.background @bar.text @bar.active
@popups.background @popups.text @popups.border
@tooltip.background @tooltip.text @tooltip.border
@menu.background @menu.text @menu.border
@menu.selected-background @menu.selected-text @menu.selected-border
@notifications.background @notifications.text @notifications.border @notifications.countdown
```

Colors remain live theme bindings after Settings removal. Custom background alpha is multiplied by backgroundOpacity. Workspace-number badges inherit accent/white when their overrides are disabled. Image artwork is a separate local-file mapping, not a color token; custom images are not tinted.

## Layout, windows and identity

Workspace groups are opt-in per canonical application/workspace pair and never span workspaces. A saved pair survives empty workspaces and restart, new arrivals join automatically, moved windows follow the destination policy, minimized windows retain membership through their recorded origin, and unresolved/special workspace membership remains individual. Browser profile metadata does not create a second grouping dimension.

Workspace cards and window filtering are different features. Grouped cards organize all matching workspace members using workspaceMonitorScope; flat layout retains windowScope, sortByWorkspace and urgent-outside-scope filtering. Do not move a vertical dock without authorization merely to make cards visible. In flat layout, workspace scope uses the focused monitor's active workspace, monitor scope uses each dock's screen, and combined scope requires both. Closed pinned launchers remain visible; explicitly hidden applications remain hidden. Minimized origins and transient location fallbacks remain owned by the shared window controller.

In grouped `workspaceMonitorScope: all`, monitor sections use `workspaceMonitorOrder`. With `[]`, connected monitors with usable finite positions are sorted numerically by x then y, followed by deterministic connector/identity ties; monitors without usable positions follow positioned monitors. A saved order such as `["HDMI-A-1","DP-1"]` puts those connected connectors first and appends other connected monitors using the same automatic geometry order. A disconnected listed connector is not rendered but stays saved and resumes its configured slot after reconnect. This setting never dispatches monitor/workspace moves and has no visual effect in flat or `current-monitor` layouts. Workspace/application presentation identities and global badge traversal remain independent from section order.

Grouped/all renders those ordered monitor sections inline in the existing single horizontal workspace viewport. A small display glyph and the monitor's 1-based position in the section order (for example `󰍺 1`) appear only before the section's first present workspace card. The dock shows no monitor name or tooltip; the full description/connector (the live monitor model, then description, connector/name and finally `Monitor N`) is exposed through accessibility text, and the sidebar keeps showing monitor names. Duplicate display descriptions remain separate because section identity is the canonical monitor identity. The label/separator is informational only: it does not take keyboard focus, activate workspaces, or become a drag/drop surface. `current-monitor` keeps the existing unprefixed card appearance.

Each connected monitor may have one active workspace card simultaneously. The workspace on Hyprland's globally focused monitor remains the unique primary workspace used for automatic reveal and global badge/preview traversal. Focus-only monitor changes update the informational prefix brightness and primary reveal without changing monitor-section order or keyed workspace/application identities. Closed global launchers render once before all sections; **Other windows** renders once after them. When a first card exits or transfers monitors, the next present card acquires the prefix while the keyed card/app delegates are retained.

Workspace-header activation focuses in place on plain click and pulls through the central workspace-on-monitor route only with Ctrl: clicking a grouped header focuses that workspace where it already is, while Ctrl+click pulls it onto the clicked dock monitor and focuses it. A plain click on a window icon inside a workspace card focuses the exact window in place; Ctrl+left click moves just that window to the clicked dock monitor's active workspace and focuses it. The shared controller retains the workspace-monitor pin enforcement hooks for callers that establish a pin, though the current workspace header has no pin menu. Plain app-icon activation already focuses in place.

Dragging a grouped workspace header to another monitor's Dockrail moves that workspace without sending a focus command. The source must already be visible; an auto-hidden destination reveals only after the pointer reaches its normal reveal strip, and the drop is accepted only over the visible dock background. Release elsewhere, return to the source dock, Escape, invalidation, or a session pin cancels without a command. In `current-monitor` the card transfers from the source dock to the destination; in `all` every dock mirrors its transfer between monitor sections. This does not change app reordering, window-to-card dragging, workspace ordering, settings, schema, or CLI.

Workspace drag/drop continues to scan the one global workspace-card repeater and map the pointer into the actual `DockWorkspaceGroup` card. Monitor labels, separators, prefix gaps, navigation controls, clipped pixels, **Other windows** and ordinary gaps are not targets. Existing remote, empty and named workspace resolution stays owned by the shared window controller; topology changes during a frozen drag still revalidate the live destination rather than trusting wrapper geometry.

Right click remains the context menu. Existing modifier precedence, grouped close/minimize/restore and wheel rules remain unchanged. Pinning does not show a hidden app; hiding does not unpin/close it; unpinning does not hide a running app. Restore and move use exact host-discovered IDs and preserve unrelated order, including unavailable entries. Application display-name queries are discovery, not mutation identities.

Icon overrides are app-wide and Dockrail-only. Set/reset changes one latest-map entry, including for an unavailable safe identity, without changing desktop files, launch commands, grouping or screenshots. The local PNG/SVG is referenced in place. The dock watches referenced files and refreshes automatically after a same-path edit, replacement, deletion or recreation; `icons reload` remains for compatibility and to force a refresh. Humans can also edit app-wide, browser-profile and window-title artwork through the context menu's host-owned **Change Icon…** dialog, which saves through the same writer; the CLI remains the scripting interface. Missing/corrupt artwork retains the mapping and uses the bounded original/generic/bundled-glyph fallback. All CLI icon acknowledgments retain `renderVerified: false`.

Window icon overrides are a separate ordered rule collection keyed by normalized raw
Wayland `(appId, titlePattern)`. Only `*` is wildcard syntax; matching is
case-insensitive and full-title, first match wins, patterns are trimmed and limited
to 1–200 characters with no control characters. Rules survive restarts and apply to
all matching current/future windows. Grouped application/workspace pairs are
partitioned into distinct matched-rule and unmatched subsets; ungrouped windows keep
their exact-window identity. Different workspaces never merge. Sidebar keeps its
existing per-window hierarchy and only receives the matched artwork.

Renderer precedence is window rule → browser-profile override → app-wide override →
desktop icon → generic icon → bundled glyph. Reset removes only the exact rule and
may expose another rule or fallback. A source-only edit keeps stable rule/presentation
identity; changing the pattern may change identity. Source A→B propagation and
same-source byte reload are distinct: the latter advances the shared artwork revision
without a redundant settings write. Malformed/duplicate collections are rejected
unchanged; no migration or partial repair is attempted.

## Reset, preservation and executable settings

`config reset --preferences` preserves pinned, hiddenApplications, browserActivityMutedServices, iconOverrides, windowIconOverrides, margin and unknown extension keys; **controlCommand is reset** along with other preferences. `workspaceMonitorOrder` and `workspaceGroups` are ordinary preferences, so preference reset restores automatic monitor ordering and clears local grouping pairs; `config reset workspaceMonitorOrder` and `config reset workspaceGroups` reset only their exact keys. Do not perform a broad reset for a narrow request.

Existing unknown keys and untouched legacy values survive minimal mutations. New unknown keys are rejected. An explicit array/object patch replaces that whole key, not a deep merge. Prefer `apps`/`icons` commands for individual membership/order/artwork changes and touched-key rollback after fresh readback.

`controlCommand` is executable configuration: store only an intentionally chosen command, quote it literally, and never run it merely to check validity. The existing launcher action can execute it later. Pointer `close` can close every live member of an application group when used. Changes to either require explicit intent; schema reads, dry runs and metadata validation do not execute them.

## Sidebar presentation

Classic remains the default. `presentationMode: "sidebar"` maps mirrored panels on
connected screens (or one panel when `sidebarMonitor` names a connected connector),
while classic preferences remain requested data and return unchanged on switching
back. Empty `sidebarMonitor` means every connected monitor; a set connector maps
only that output. Disconnected names remain saved and fall back to all connected
screens. Placement does not filter the window inventory.

`presentationModeByMonitor` resolves each connected connector independently: an
explicit `classic`/`sidebar` entry beats both the global `presentationMode` and
the legacy `sidebarMonitor` selection, while unlisted connectors inherit the
effective default. An empty map reproduces pre-override behavior exactly.
Overrides for disconnected connectors stay saved, and changing `presentationMode`
never removes them. An explicit object patch replaces the whole map, so dropping
one connector's key (or `config reset presentationModeByMonitor` for the whole
map) restores inheritance. Classic and sidebar surfaces coexist: every connected
output renders its own resolved mode, so one monitor can show the bottom dock
while another shows the sidebar at the same time.

Sidebar effective output uses all monitors, structural workspace-local application
groups, persistent reservation, icons capped at 32, and no previews or auto-hide.
Classic click/middle-click/scroll actions are reported as `null` (inactive).
`config get --effective` applies those sidebar rewrites only when the inherited
default is `sidebar` and no connected output resolves `classic`; in a mixed
layout the classic outputs keep their own effective values for those keys, and
`inactiveClassicSettings` lists exactly the keys the sidebar outputs ignore.
The `presentation` diagnostic lists inactive classic settings, primary connector,
full `screens` list, effective persistent width and whether that geometry can
map, plus the per-monitor resolution: `defaultMode`, `perMonitor` entries of
`{connector, mode, source, mapped, sidebarSelected}`, keyed `modeByMonitor`,
`sourceByMonitor` and `mappedByMonitor`, the `classicScreens` list, and `mixed`
when classic and sidebar outputs coexist. `source` is `override` for an explicit
entry and `inherited` otherwise. In a mixed layout the legacy summary fields keep
their historical meaning: `mode` reports the inherited default, while `screen`,
`screens`, `width` and `mapped` describe the sidebar that actually renders — use
`perMonitor` for the per-connector truth. These are source projections, not proof
that the compositor mapped a surface. No screen means zero width and
`mapped: false`. Width uses unreserved logical screen geometry. Each output
reserves its own exclusive zone from its clamped width.

These sidebar and per-monitor presentation settings support the existing typed
set/apply/reset/schema/get commands. Width writes accept integers 240–480; the runtime may clamp the effective
width below 240 on narrow screens without rewriting the requested value. The
expanded resize handle lives inside the reserved width. Pointer motion changes only
temporary effective geometry; a changed release submits one `sidebarExpandedWidth`
intent. No-op release and cancellation write nothing. Collapsing a panel submits
only `sidebarCollapsedByMonitor` for that connector, preserves expanded width and
retains session-only app folds. Global `sidebarCollapsed` remains the default for
monitors without an override.
Unknown keys, pins, artwork, hidden apps and provider preferences survive unrelated
changes. Empty `sidebarCollapsedByMonitor` follows `sidebarCollapsed` on every
output; a connector key overrides only that panel.

Gesture commits use the existing sole writer. A stale captured field is rejected
rather than replayed; an accepted write may report persistence pending without
becoming a rejected intent. Persistence failure keeps the accepted live value and
retry persists the latest complete host snapshot. See `SIDEBAR_RESIZE.md` for the
exact geometry, cancellation, writer-count and deferred runtime contracts.

The background mode gesture follows the same contract. Only empty background is
eligible: dock rows, widgets, headers, pinned strips, controls and the sidebar's
list content keep their own input, and the sidebar gesture's blank tail
disappears once content overflows or scrolls. Dragging left on the bottom dock or
down on the sidebar arms after 48 px of directional travel, shows a hint pill and
then a destination silhouette on the configured edge — both staying on the source
monitor — and commits exactly one `presentationModeByMonitor` entry for the
source connector on release; other connectors keep their own modes. The press
captures that connector's presentation token, which the host revalidates at
release, so a presentation or topology change during the press, a release below
the threshold, Escape, an open menu/popup, a resize or row drag, or a disconnected
source cancels without any write. Rejected intents and persistence failures are
reported on the source monitor only, through host feedback keyed by connector,
using the shared wording above; a stale gesture's message can never appear on
another monitor.

Sidebar resizing, navigation and Widget lifecycle details are in the source-only
`docs/SIDEBAR.md` reference. Configuration readback is not proof that a compositor
has rendered the requested layout; check placement and input on the desktop.

`sidebarWidgets` uses the selected host's Widget registry.
Runtime schema `registeredIds` is authoritative for new writes. Unknown imports are
never executed; requested readback retains them and `data.presentation.widgets`
reports unavailable state. `config get --effective` lists only registered IDs.
The hierarchy and Widget bodies scroll independently, while the Widget header,
PINNED and Applications stay fixed. A content-aware 55% hierarchy cap returns
unused space. The Widget section consumes zero height when no Widgets are enabled;
Add/Manage remains available in expanded mode.
`sidebarWidgetCollapsed` stores body state without enabling providers. These
controls do not change stock topbar services. Source contract:
`docs/SIDEBAR_WIDGETS.md`.
