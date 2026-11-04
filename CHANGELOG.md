# Changelog

## [Unreleased]

### Added

- T3 Code threads (sidebar widget `t3.threads`, dock indicators `dockT3Indicators`, `dockrail t3 pair|status|unpair`).
- Claude Desktop session state on its dock icon and sidebar window row
  (working spinner, input needed, done). A session needs input when Claude
  asks you a question, and done clears when you open the session. The sidebar
  lists each session that needs attention and opens it in Claude Desktop.
  State comes from Claude Code hooks (`dockClaudeIndicators`,
  `dockrail claude hooks install|status|uninstall`).

### Fixed

- Failed T3 subagent threads no longer pin an orange "needs you" row in the
  dock. Their failure belongs to the parent run, and a subagent thread is
  never visited, so the row came back after every snooze expired.
- Ghost and duplicate workspace sections no longer appear when workspaces are
  destroyed or renumbered quickly. Quickshell can keep stale stand-in
  workspaces (id -1) from late window-list replies; empty ones are now hidden,
  and numbered ones merge into the real workspace with that number.
- Claude Desktop hooks no longer break when the CLI is reinstalled from the
  Omarchy plugin. Installed commands use a stable CLI-owned hook script and
  `dockrail claude hooks status` reports a missing or stale script.
- Fresh standalone installs no longer enable the four demo Widgets in the
  sidebar. Existing configurations are not changed; remove unwanted
  `demo.*` entries from `sidebarWidgets` if an earlier install added them.
- `dockrail t3 pair` and `status`, and the T3 provider, work on hosts booted
  with IPv6 disabled.
- `scripts/run` and `dockrail launch`/`restart` follow a moved `OMARCHY_PATH`
  instead of failing on a stale `qs` import alias.
- The Trash item no longer polls `gio` while every screen shows the sidebar,
  and a failed Trash listing shows as unknown instead of empty.
- `uninstall.sh --purge` refuses before removing anything while the plugin is
  installed, including under a custom `XDG_CONFIG_HOME`.

## 3.0.0 - 2026-09-25

SmartDock for Omarchy is now **Dockrail**. The repository moved to
<https://github.com/fernandodamaso/dockrail>; the old
`fernandodamaso/smart-omarchy-dock` URL redirects. The plugin ID is now
`io.github.fernandodamaso.dockrail`, so existing SmartDock plugin installs
reinstall once (see below); settings are kept.

### Upgrade and compatibility

- The first plugin or standalone startup migrates legacy SmartDock state into
  the Dockrail XDG roots through a journaled, resumable transaction. Legacy
  paths become managed aliases and a recovery snapshot is retained under
  `${XDG_STATE_HOME:-~/.local/state}/dockrail/migrations/`.
- Migration refuses while a `dev use` override is active; run
  `dockrail dev reset` (or `smartdock dev reset`) first. CLI-only installs and
  read-only commands never migrate.
- `DOCKRAIL_CONFIG` is the canonical override; `SMARTDOCK_CONFIG` is still
  honored when the canonical variable is unset.
- Both `Dockrail.WidgetKit 1.0` and `SmartDock.WidgetKit 1.0` imports work.
- The Omarchy plugin ID is now `io.github.fernandodamaso.dockrail`. Existing
  SmartDock plugin installs reinstall once:
  `omarchy plugin remove io.github.fernandodamaso.smartdock --yes`, then
  `omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes`.
  Settings and shared state are kept.
- Intentionally unchanged: `smartdock` IPC target, `special:smartdock-minimized`, terminal-agent IDs,
  Wayland layer namespaces and Herdr executable names. Minimized windows stay
  recoverable across restarts; their original workspace/monitor is not
  persisted.
- Uninstall keeps configuration, shared Widget/provider state and recovery
  snapshots; `--purge` refuses while the Omarchy plugin is installed. There is
  no automatic rollback over settings written after activation.

### Product identity

- SmartDock for Omarchy is now **Dockrail** for current product-facing UI,
  documentation, installer output, and help.
- `dockrail` is the canonical CLI; `smartdock` remains a compatibility
  launcher to the same implementation.
- Canonical user state lives under the Dockrail XDG roots introduced by the
  migration, while managed legacy SmartDock paths remain compatibility aliases.
- `Dockrail.WidgetKit 1.0` is the canonical public WidgetKit module;
  `SmartDock.WidgetKit 1.0` remains supported for existing packages.
- The `smartdock` IPC target, terminal-agent/application
  IDs, Wayland layer namespaces, `special:smartdock-minimized`, Herdr
  executable identities and historical issue/release names remain
  intentionally unchanged.


### Added

- Added `presentationModeByMonitor`, per-connector presentation overrides: an
  explicit `classic`/`sidebar` entry beats `presentationMode` and
  `sidebarMonitor`, unlisted connectors inherit the effective default,
  disconnected entries stay saved, and changing the global default never
  removes them — so one output can run the bottom dock while another runs the
  sidebar at the same time.
- Added one stable surface owner per connected output: switching one screen's
  presentation never recreates another screen's renderer instance, a
  disconnected output cancels its gesture and closes its popups, and
  reconnecting restores the configured presentation. The host owners, the
  sidebar controller and CLI diagnostics share one pure resolver that reports
  `defaultMode`, `perMonitor`, `modeByMonitor`, `sourceByMonitor`,
  `classicScreens` and `mixed`.
- Added mute controls on Chrome activity rows (eye / eye-off). Muted service
  IDs persist in `browserActivityMutedServices`, stay visible and dimmed, and
  are excluded from the card header total and Chrome dock badge fallback.
- Added the Chrome activity hover card with strict WhatsApp/Gmail unread rows,
  exact-tab activation, compact window previews, and a Chrome-only badge-count
  fallback.
- Shipped the CLI command/JSON/error reference, all 43 declared setting defaults
  and dependencies, and agent recipes for minimal patches, themes, calmer motion,
  workspace cards, application restoration/order and per-app icon set/reload/reset.
- Added executable documentation checks through the existing CLI and production
  host/model harness, including preservation, dry runs, effective projections,
  parser/schema consistency, Unicode artwork URLs and offline installation.
- Included linked reference, inventory and local-runbook documents beside the
  installed agent guide without adding a runtime, test framework or CI workflow.
- Added the migration plan and exact-SHA FDM-920/FDM-885 joint local runbook with
  isolation, touched-state restoration and explicit not-yet-verified runtime gates.

### Changed

- Workspace and window activation is now opt-in for moves, in both the dock
  and the sidebar: a plain workspace-name click focuses the workspace where
  it already is, while Ctrl+click pulls it onto the clicked monitor and
  focuses it. A plain window click focuses the window where it is, while
  Ctrl+click moves just that window (the one a plain click would focus, so
  repeated Ctrl-clicks on a multi-window icon cycle through its windows) to
  the clicked monitor's active workspace and focuses it.
- Grouped workspace names now render at `Style.font.body` with
  `Font.DemiBold`, matching the monitor label, and grouped pinned icons sit
  16 px apart, matching the sidebar pinned strip.
- Removed the standalone + (add pinned application) slot beside Dock Controls;
  pin apps from the Dock Controls menu's **Add Pinned Application** entry instead.

- Dock presentation has two modes: the classic bottom dock and the sidebar
  (the dock's left vertical presentation), resolved per monitor so both can
  render side by side. Drag empty dock background left to switch that monitor
  to the sidebar, or drag empty sidebar background down to return it to the
  dock; the gesture shows a direction hint and a destination silhouette on the
  source monitor, commits one `presentationModeByMonitor` entry for that
  connector only on release past the threshold, and cancels without a write on
  early release, Escape or an interrupted drag. Rejected or failed commits
  report feedback only on the monitor that produced the gesture. Legacy
  top/right/left classic values remain readable as bottom compatibility values.
- Removed the graphical Dock Settings page, its menu route, temporary preference
  previews, exclusive controls and editor-only helpers. Configuration and icon
  editing now use `smartdock config`, `smartdock apps` and `smartdock icons`.
- Retained ordinary window previews, the app picker, dock menus, auto-hide,
  pinned-app dragging, workspace/window actions, Trash and live theme bindings.
- Preserved existing configuration, application identities, pin order, hidden
  membership and custom icons through the existing host-owned settings writer.
  Restore hidden applications with `smartdock apps show ID` or `apps show --all`.
- Updated active configuration instructions and split mixed regression suites so
  runtime behavior remains covered without depending on removed UI components.
- **Breaking launcher change:** bare `smartdock` shows help; unrecognized leading
  arguments no longer implicitly launch Quickshell. Replace invocations such as
  `smartdock --no-color` with `smartdock launch --no-color`. The explicit
  `--daemonize` and `-d` lifecycle aliases remain supported.
- **Source configuration migration:** `./scripts/run` now defaults to
  `${XDG_CONFIG_HOME:-$HOME/.config}/smartdock/dock.json`, not the checkout's
  `config/dock.json`. `SMARTDOCK_CONFIG` still selects an explicit configuration.
  Existing source-only customizations are not copied over user state automatically;
  preserve a separate copy outside the checkout and select it explicitly. Use an
  isolated config/display for source qualification, not a second production dock.

### Fixed

- Grouped workspace labels with fractional text widths no longer show overflow
  arrows when the compact dock has enough room.
- Source-run configuration saves no longer overwrite the bundled defaults used
  by single-key and preference resets after restart.
- New bulk pin/hidden-ID patches reject surrounding whitespace instead of saving
  identities that CLI discovery and dock rendering resolve differently. Untouched
  legacy settings are preserved.
- Drag reordering uses the same legacy-preserving move intent as the CLI,
  retaining duplicate/unavailable legacy pins, hidden membership, other ordering
  and the existing forward/backward drop semantics. Bulk replacement stays strict.
- Removed the obsolete local dropdown fixture and extended both removal audits
  to local tests. The FDM-858 UI audit is explicitly historical and superseded.

The CLI-first migration remains an unreleased candidate. Remote checks do not
replace the final Omarchy focus, auto-hide, FileView and image/cache qualification.
Historical entries below describe earlier versions and are not current UI routes.

## 2.1.0 - 2026-09-01

### Changed

- Updated FDM-814 attention motion so SNI `NeedsAttention`, critical local
  notification attention, and Hyprland urgency share the bounded
  `0 -> 5 -> 0 -> 3 -> 0` nudge. Active attention can receive reminders no more
  than once every three seconds; launcher counts alone remain static while
  counts with attention remain eligible.
- Reorganized Dock Settings into icon-led Icons, Hover effect, Dock surface,
  Layout, and Behavior cards matching the approved compact layout.
- Added progressive Theme default, Omarchy token, custom hex, and custom border
  width controls while preserving the existing JSON schema.
- Added a collapsible launcher section and fixed Reset/Close footer.
- Added theme-tinted Lucide section and action icons using Omarchy accent and
  urgent tokens.

## 2.0.0 - 2026-09-01

### Added

- Established SmartDock for Omarchy as an independently released GitHub fork
  distributed from the SmartDock repository.
- Assigned the public Omarchy plugin ID `io.github.fernandodamaso.smartdock`.
- Preserved user configuration in `~/.config/smartdock/dock.json` across Git
  migration and plugin updates.

## 1.1.1-custom.18 - 2026-09-01

### Added

- Added a theme-aware Dock Settings panel with live previews, persistent controls, and reset-to-defaults support.
- Added a dynamic Trash utility with open, item-count, empty/full icon, and confirmed Empty Trash actions.
- Added compact workspace navigation at the trailing edge using the same visibility rule as the configured Omarchy workspace widget.
- Added independent opt-in dock background color, border color, and border width overrides in Dock Settings.
- Added clickable alpha-aware color swatches beside the background and border hex fields.
- Added ready-to-choose Omarchy theme-token presets for dock background and border colors; symbolic selections follow theme changes.
- Added live color squares to each theme-token selector option and its selected-value trigger.
- Added Dock Settings controls for enabling hover glow and adjusting its intensity and radius.

### Changed

- Renamed the user-facing dock branding to **SmartDock for Omarchy** while
  preserving the existing plugin ID, commands, configuration path, and
  internal Hyprland workspace namespace for compatibility.
- Replaced the first dock item's grid artwork with a sliders-style controls icon.
- Split the dock into leading controls, centered applications, and trailing utilities so full-length and vertical layouts remain organized.
- Kept dock-wide settings, application pinning, and auto-hide actions exclusively in the controls icon menu.
- Tied reserved screen space to visibility so the dock reserves a dock-sized area only while auto-hide is disabled; the Reserve space control is disabled while auto-hide is enabled.
- Added themed glyphs to the Dock Settings, Add Application, and Auto-Hide actions.
- Colorized the symbolic Trash icon with white/accent states and aligned workspace controls to the same icon centerline at every dock edge.
- Made the idle Trash glyph fully opaque white; it still changes to the theme accent while hovered.
- Reworked Dock Settings into a responsive 980 px two-column layout so desktop screens avoid vertical scrolling.
- Bundled Lucide `trash-2` artwork and matching Lucide icons for dock and window context-menu actions.
- Clicking the controls icon now opens its menu; the menu's **Open App Launcher** action runs the configured launcher command.
- Centered application, control, Trash, and workspace icons symmetrically on every dock edge.
- Moved application, controls, and Trash hover labels to popup-backed tooltips so long names remain visible at dock edges.
- Replaced hover fill-and-border tiles with a soft theme-accent glow behind each magnified icon.
- Forced the color picker to use an in-overlay Quick implementation so GTK's native
  color window cannot appear behind Dock Settings.
- Kept the dock's edge input strip available while Dock Settings is open, so hover
  magnification and glow previews remain visible during live edits.
- Released Hyprland's compositor-wide exclusive pointer routing after the settings
  surface acquires keyboard focus, restoring dock hover events reliably.

## 1.1.1-custom.17 - 2026-09-01

### Fixed

- Removed the workspace badge border and restored white workspace numbers without changing the separate hover tooltip styling.

## 1.1.1-custom.16 - 2026-09-01

### Changed

- Removed borders from dock tooltips and made tooltip labels white for clearer contrast.

## 1.1.1-custom.15 - 2026-09-01

### Changed

- Made workspace number badges opaque and accent-colored so they remain visible over application icons.

## 1.1.1-custom.14 - 2026-09-01

### Changed

- Replaced dock, menu, picker, tooltip, badge, border, radius, typography, and hover styling with Omarchy theme tokens.
- Kept `backgroundOpacity` as a user-controlled multiplier on the active theme surface alpha.
- Made standalone launches expose the same Omarchy QML modules without modifying `/usr/share/omarchy`.

## 1.1.1 - 2026-08-22

### Added

- Optional auto-hide with animated screen-edge reveal, configurable through `autoHide` or the dock context menu.

### Fixed

- Keep the revealed dock's full interaction area clickable and allow more time to move from the screen edge to an icon.

## 1.1.0 - 2026-08-22

### Added

- Drag-to-reorder pinned applications with automatic config persistence.
- Right-click actions to open a new window or close a running application.
- Fuzzy application picker and right-click actions for pinning or unpinning apps.
- Configurable dock background transparency through `backgroundOpacity`.

### Fixed

- Focus existing browser-based web apps instead of launching duplicate windows.
