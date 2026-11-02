# Dockrail

> Local Omarchy variant: pinned applications remain first, while grouped
> running applications from every workspace are appended automatically.

A developer-focused workspace rail for Hyprland — apps, windows, workspaces, widgets, and coding-agent sessions in one surface, built with Quickshell and Qt/QML.

![Dockrail running at the bottom of an Omarchy desktop](preview.png)

## Features

- Smooth pointer-distance magnification
- Freedesktop application icons and launching
- Configurable application-icon left, middle, and grouped-window scroll actions
- Optional grouped window previews when hovering application icons
- Focuses an existing application on another workspace
- Running-application indicators
- Dot-first application attention badges from live SNI/Hyprland state and available Omarchy notifications
- Reduced-motion bounded attention nudge with three-second reminders while attention remains active
- Optional authoritative application-provided launcher badge counts with dot fallback
- First-position sliders control for the app launcher, adding applications, and auto-hide
- Bundled Lucide SVG artwork for the Trash icon and dock context-menu actions
- Host-owned CLI configuration, app management, and local PNG/SVG icon overrides
- Optional dynamic Trash icon with item count, open, and confirmed empty actions
- Compact trailing workspace switcher that mirrors the Omarchy top-bar visibility rule
- Minimized-window markers, counts, tooltip summaries, and per-window status labels
- Fullscreen focus emphasis that enlarges the owner and fades other dock icons
- Per-window right-click management for workspace moves, fullscreen-with-bars,
  Hyprland-style minimize/restore, focus, and close
- Drag-to-reorder with persistent pinned-app order
- Context-menu hiding with persistent restoration through `dockrail apps show`
- Right-click actions to launch, close, pin, or unpin applications
- Fuzzy application search for adding dock items
- Configurable dock background transparency
- Omarchy theme-aware surfaces, borders, corner radius, typography, and hover states
- Optional reserved screen space while the dock is visible
- Optional auto-hide with screen-edge reveal
- Live JSON configuration reload
- Multi-monitor support

## Requirements

- Omarchy 4.x with the Quattro plugin host for the plugin installation below
- Hyprland and Quickshell 0.3 or newer
- Python 3 for the configuration CLI (standard library only)
- A working freedesktop icon theme
- Git for a standalone source checkout

Optional features have additional requirements:

| Feature | Requirement |
| --- | --- |
| Herdr agents | Herdr 0.9.1+ for click-to-focus; older versions cannot jump to agents. See [Herdr setup](docs/HERDR_DATA_ACCESS.md). |
| Chrome profiles, unread counts and tabs | Chrome with remote debugging explicitly enabled, a separate user-data directory, and the browser-profile provider. Omarchy does not enable remote debugging by default. See the [setup and security notes](docs/browser-activity.md#enable-chrome-profiles-and-tabs). |
| Numeric launcher counts | CMake, a C++20 compiler, and Qt 6.6+ Core/DBus development files to build the optional provider. |
| Trash | GLib's `gio` command. |

## Install

Install the Git-managed Omarchy plugin:

```bash
omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes
bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh --cli-only
dockrail setup
```

Omarchy does not run install hooks. The installed plugin directory is the
checkout for this CLI command; its launchers read the current plugin files, so
`omarchy plugin update` also refreshes CLI metadata. `dockrail setup` starts
with the same feature-readiness checks and guides optional setup through the running host. If `${XDG_BIN_HOME:-$HOME/.local/bin}` is not on `PATH`, add it to your
shell's `PATH` to use `dockrail` by name.

Upgrading from SmartDock (plugin ID `io.github.fernandodamaso.smartdock`)?
Dockrail 3.0.0 uses a new plugin ID, so reinstall once. Your settings in
`~/.config/dockrail` (or legacy `~/.config/smartdock`) are kept:

```bash
omarchy plugin remove io.github.fernandodamaso.smartdock --yes
omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes
```

The normal update command is:

```bash
omarchy plugin update io.github.fernandodamaso.dockrail --yes
```

Updates pull the fork's default `main` branch and preserve
`~/.config/dockrail/dock.json`. Installed plugin files are deployment state;
do not edit them directly. Development belongs in a separate clone, such as
`/home/admin/Projects/smart-omarchy-dock`, and changes reach an installed copy
through Git push followed by `omarchy plugin update`.

### Standalone installation

Standalone use is a secondary mode. After installing the requirements above,
clone the source and run the installer:

```bash
git clone https://github.com/fernandodamaso/dockrail.git && cd dockrail && ./install.sh
```

The installer uses only user directories, requires no `sudo`, and creates an
XDG autostart entry. To install without autostart, use
`./install.sh --no-autostart`.

Run the standalone dock immediately with:

```bash
dockrail --daemonize
```

Installed copies appear as **Dockrail** in application launchers.
Run `dockrail help` to see every command.

Manage autostart later from the CLI:

```bash
dockrail autostart status
dockrail autostart enable
dockrail autostart disable
```

### Update or remove

`dockrail update` only refreshes an installed standalone copy from its local
source copy. It does not update the Omarchy plugin; use the Git-managed
`omarchy plugin update` command above for that.

```bash
dockrail update
dockrail restart
dockrail uninstall
```

Uninstalling preserves the configuration; remove it too with
`dockrail uninstall --purge`.

To remove the Omarchy plugin:

```bash
omarchy plugin remove io.github.fernandodamaso.dockrail --yes
```

Plugin removal leaves `~/.config/dockrail/dock.json`, shared Widget packages,
optional providers, and migration recovery snapshots in place. Delete
`~/.config/dockrail` yourself only if you no longer want those settings.
If you switched to a local version with `dockrail dev use`, run
`dockrail dev reset` before removing or updating the plugin.

## Run as an Omarchy plugin

Omarchy users should run Dockrail inside the existing Omarchy shell rather
than starting a second Quickshell process. The installed plugin ID is
`io.github.fernandodamaso.dockrail`:

```bash
omarchy plugin enable io.github.fernandodamaso.dockrail
```

The plugin uses `~/.config/dockrail/dock.json`, shared with the standalone
version. Do not run the standalone and plugin versions together, or two docks
will appear.

### Herdr agents

Herdr agents requires Herdr 0.9.1+ for click-to-focus. With the `herdr` binary
installed, open the sidebar **Add/Manage** picker and enable **Herdr agents**.
Dockrail checks picker readiness without starting the Herdr provider; the existing
provider still starts only while a Herdr consumer is active. A connected older
server stays visible but cannot jump to an agent and shows
`Update Herdr to 0.9.1+ to jump to agents`.

Classic-dock Herdr indicators are a separate option:

```bash
dockrail config set dockHerdrIndicators true --json
```

`dockHerdrIndicators` controls classic dock indicators; it does not enable the
sidebar Herdr agents widget.

### T3 Code threads (pairing)

Dockrail can show local T3 Code threads through a read-only pairing with the
T3 server on this machine. Pairing stores a bearer session token in a `0600`
file under the Dockrail data root; the token never appears in settings, logs
or on a command line.

```bash
dockrail t3 pair --json
dockrail t3 status --json
dockrail t3 unpair --json
```

`pair` needs the `t3` CLI and a running T3 Code server. `status` exits 0 while
paired and unexpired. `unpair` removes the local pairing; revoke the
server-side session separately with `t3 auth session list` /
`t3 auth session revoke <id>` when needed. Only loopback T3 servers are
supported, and clicking a thread raises the T3 Code window (no thread
deep link).

With the `t3` binary installed, open the sidebar **Add/Manage** picker and
enable **T3 Code threads**. If you already have sidebar widgets enabled, append
`t3.threads` to your current requested list instead of replacing it (read it
first with `dockrail config get sidebarWidgets --json`):

```bash
dockrail config set sidebarWidgets '["herdr.agents","t3.threads"]' --json
dockrail config set dockT3Indicators true --json
```

`dockT3Indicators` controls classic dock indicators; it does not enable the
sidebar widget. Re-pair when the session expires (`dockrail t3 pair`).

### Claude Desktop sessions

Show a working spinner on the Claude Desktop icon while one of its Claude
Code sessions runs, an input-needed mark on permission prompts and when Claude
asks you a question, and a done mark that clears when you open that session
in Claude Desktop. The sidebar shows the same marks on the Claude window row
and lists each session that needs attention under it; clicking a session row
opens that session. Install the Claude Code hooks once, then enable the
indicators and start a new Claude Desktop session:

```bash
dockrail claude hooks install
dockrail config set dockClaudeIndicators true --json
```

Terminal `claude` sessions are ignored, and plain chat replies have no hook,
so they do not animate the icon. Remove the hooks with
`dockrail claude hooks uninstall`. Details: [docs/CLAUDE_DESKTOP.md](docs/CLAUDE_DESKTOP.md).

### Launcher badge count provider

Numeric counts are optional and provider-owned. Omarchy plugin installation
never compiles or executes an install hook. Build the small QtDBus provider
directly from the installed plugin folder when you want application-provided
counts:

```bash
bash "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.fernandodamaso.dockrail/scripts/build-launcher-badge-provider"
```

The script builds outside the installed plugin tree, runs the provider tests,
and installs only the resulting executable under
`${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/providers/`. Then reload the
dock with `omarchy restart shell` and verify with `dockrail doctor`. From a
separate source checkout, `bash ./scripts/build-launcher-badge-provider`
remains supported. If the binary, Qt runtime, D-Bus service, or an
application's launcher-count support is unavailable, Dockrail keeps the
attention dots; it does not poll or scrape another source for a number.

The provider listens to the established
`com.canonical.Unity.LauncherEntry.Update` session-bus protocol and accepts only
typed `count` and `count-visible` properties. Standalone Dockrail intentionally
does not own this provider and therefore remains dot-only. See
[`docs/launcher-badge-counts.md`](docs/launcher-badge-counts.md) for architecture,
compatibility, and local validation details.

Launcher badge counts do not invoke Herdr or poll any recurring agent-status CLI.
Herdr agent state is a separate, opt-in sidebar source: `herdr.agents` starts a
Dockrail-owned local event provider only while the sidebar widget is active.
LauncherEntry numeric counts remain authoritative for application badges, with
the optional Chrome activity provider supplying only its strict fallback.

### Per-window icon rules

Persistent window artwork rules are keyed by the raw Wayland application ID and a
title pattern. Only `*` is special; matching is case-insensitive across the full
title and the first matching rule wins. Rules apply to all matching current and
future windows and survive restart.

```bash
dockrail icons set com.mitchellh.ghostty ~/Pictures/solar.svg --title-pattern '*solar*'
dockrail icons reset com.mitchellh.ghostty --title-pattern '*solar*'
```

Window-rule artwork has renderer precedence over profile/app-wide artwork. It can
split grouped presentation slots by rule without changing launch, pin, hide, badge
or workspace identity. Reset removes only the targeted rule; another matching rule
or lower-priority artwork can immediately become visible. Missing/corrupt artwork
keeps the rule and falls back while `renderVerified` remains false.

The same rules, browser-profile artwork and app-wide overrides can be edited
without the CLI: right-click an app, window or pinned app and choose **Change
Icon…**. Pick a recently used image, **Choose file…** (PNG/SVG, via
Omarchy's `omarchy-file-select` portal chooser) or **Default**,
then choose whether it applies to all windows of the app, only one browser
profile, or only windows whose title contains some text (saved as `*text*`).
The dialog previews the affected open windows, **Reset to default** removes
exactly the override currently applied, and **Save** performs one settings
write; both the removed override and destination are checked against the
opening snapshot, including a destination that was absent. A concurrent edit is
refused rather than overwritten. Choosing an existing title pattern edits that
rule in place; renaming a different rule onto it is rejected without deleting
either rule. Choosing a narrower scope keeps the wider override. The preview
uses the resulting settings, including surviving title/profile/app overrides;
reset can reveal a remaining custom icon rather than the stock icon.

Only one Change Icon editing session is active at a time across dock items and
sidebar panels. Opening another closes the previous editor and ignores any late
file-picker result. Hidden, removed or recycled source anchors close the editor;
its file chooser is allowed to finish normally without applying a stale result.

### Browser profile badges and activity

Chrome can run every profile inside a single browser process, so a window's
process or `app_id` cannot tell a work profile window from a personal one. The
optional browser-profile provider reads Chrome's DevTools endpoint (one CDP
browser context per profile) and publishes which profile owns each window:

```bash
bash "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.fernandodamaso.dockrail/scripts/install-browser-profile-provider"
```

The script stages its bytecode check outside the installed plugin tree and
installs the Python helper under
`${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/providers/`. Then reload the
dock with `omarchy restart shell` and verify with `dockrail doctor`. From a
separate source checkout, `bash ./scripts/install-browser-profile-provider`
remains supported. Chrome remote debugging is optional and must
be enabled explicitly with a separate user data directory. Follow
**[Enable Chrome profiles and tabs](docs/browser-activity.md#enable-chrome-profiles-and-tabs)**
for setup, verification, and the security implications. Without a reachable
endpoint the dock keeps the plain application icon.

Detected profiles render as a small corner badge over the app icon: the
profile's own photo when one exists, otherwise an initial circle in a
deterministic color derived from the profile name. Windows of the same
application from different profiles therefore look different. A fully custom
artwork per profile is also available through the CLI:

```bash
dockrail icons set google-chrome ~/Pictures/work.svg --profile "Profile 1"
dockrail icons reset google-chrome --profile "Profile 1"
```

The profile argument is the on-disk profile directory inside the browser's
user data directory (`Default`, `Profile 1`, ...). Profile-specific artwork
wins over the application-wide override and suppresses the automatic badge
only after it renders. Application-wide artwork retains the profile badge.
When the provider is not installed, these keys stay inert.

The same provider can publish strict unread activity for WhatsApp, Instagram,
and supported English or Portuguese Gmail inbox titles.
When those rows are available, hovering Chrome opens a compact card with the
profile label, unread count, and matching window previews; selecting a row
activates that exact browser tab and owning window. Hover a row to reveal an
eye control that mutes that service from the header total and Chrome badge
fallback; muted rows stay visible and dimmed with eye-off until unmuted. Mute
state is stored as `browserActivityMutedServices` in user settings and survives
preference reset (`dockrail config get/set browserActivityMutedServices`).
Only HTTPS pages with the recognized service hosts and title signals are
accepted, and no message contents or account data leave the browser. If the
activity provider is unavailable or a row cannot be matched exactly, previews
and ordinary attention dots continue and Chrome may use an aggregate activity
badge only when no authoritative LauncherEntry count is present (including an
explicit zero or hidden state). See
[`docs/browser-activity.md`](docs/browser-activity.md) for the provider
contract and validation boundary. Sidebar nesting of open Chrome tabs (titles
only) is documented in [`docs/browser-tabs.md`](docs/browser-tabs.md) and gated
by `sidebarBrowserTabsEnabled`.

### Terminal-agent launchers

Dockrail bundles visible application entries that open these terminal agents
in separate Ghostty windows:

| Launcher | Desktop ID | Ghostty window class | Command |
| --- | --- | --- | --- |
| Pi | `smartdock-agent-pi` | `io.github.fernandodamaso.smartdock.agent.pi` | `pi` |
| Oh My Pi | `smartdock-agent-oh-my-pi` | `io.github.fernandodamaso.smartdock.agent.oh-my-pi` | `omp` |
| Command Code | `smartdock-agent-command-code` | `io.github.fernandodamaso.smartdock.agent.command-code` | `commandcode` |
| Cursor Agent | `smartdock-agent-cursor` | `io.github.fernandodamaso.smartdock.agent.cursor` | `cursor-agent` |
| Claude Code | `smartdock-agent-claude-code` | `io.github.fernandodamaso.smartdock.agent.claude-code` | `claude` |
| Kilo Code | `smartdock-agent-kilo-code` | `io.github.fernandodamaso.smartdock.agent.kilo-code` | `kilo` |
| Cline | `smartdock-agent-cline` | `io.github.fernandodamaso.smartdock.agent.cline` | `cline` |

Each launcher runs `ghostty --gtk-single-instance=false` with a unique, valid
GTK/Wayland application ID. Standalone users get these entries from the
normal `./install.sh`. Plugin users can install only the launchers and icons
directly from the installed plugin folder, without requiring Quickshell,
installing a second dock, enabling autostart, or changing the dock configuration:

```bash
bash "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh" --agent-assets-only
```

Then reload the dock with `omarchy restart shell` and verify with
`dockrail doctor`. From a separate source checkout,
`./install.sh --agent-assets-only` remains supported.

The plugin itself is installed with:

```bash
omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes
```

Agent grouping is best effort. Dockrail uses the terminal window's observed
title or agent marker as a fallback because these CLIs run inside a terminal,
so title updates can be delayed, overwritten by a shell, or unavailable. A
manually started Pi, Oh My Pi, or Kilo session usually retains a recognizable
title. Command Code, Cursor Agent, Claude Code, and Cline can replace their
branded title with arbitrary session or prompt text, so only their branded
startup/default phases are recognized outside the dedicated launchers. A
tab or split inside Ghostty usually shares the same top-level window and cannot
be separated reliably. The same limitation applies to multiple sessions in
tmux. An agent running over SSH or inside a container may expose only the local
shell/terminal title, so it can remain grouped under Ghostty instead of its
agent launcher. These entries still provide direct launches even when runtime
grouping cannot identify a session.

## Contributing

Want to try an unmerged version on your desktop? Use
`dockrail dev use <worktree-path-or-local-branch>`, then `dockrail dev reset`
to return to the installed copy. See [local version switching](docs/DEV_SWITCH.md)
for setup, reload, and recovery commands.

Development happens in the canonical source checkout or in your own clone,
never in the installed Omarchy checkout:

```bash
cd /home/admin/Projects/smart-omarchy-dock
./scripts/run
```

Quickshell watches the QML files, so UI changes reload while developing.

## Project history

Dockrail, formerly SmartDock for Omarchy, is an extensively developed MIT-licensed fork of
[nick-friedrich/hyprland-dock](https://github.com/nick-friedrich/hyprland-dock).
The upstream Git history, MIT license, and original copyright notice are
preserved in this repository.

## Configure

The [CLI reference](docs/CLI_REFERENCE.md) describes commands, JSON fields and
errors; the [configuration inventory](docs/CONFIGURATION.md) lists all 58
settings, declared defaults and dependencies. Both ship beside the offline
[agent guide](docs/AGENT_CONFIGURATION.md). It explains safe changes, backups,
readback and recovery. A successful CLI response confirms only the reported
configuration and persistence state, not the visible result on your desktop.

Use the selected running host through the CLI rather than editing a live
`dock.json`. The plugin installation command above installs the CLI from the
installed plugin directory. For a separate source checkout, install a copied
CLI bundle without starting a second dock:

```bash
bash ./install.sh --cli-only
dockrail status --json
dockrail config schema --json
dockrail config get --json
dockrail config set iconSize 48 --json
dockrail config set workspaceMonitorOrder '["HDMI-A-1","DP-1"]' --json
dockrail agent-guide
```

The host reports its authoritative `data.configPath`; do not infer that path
from the working directory. Choose `--runtime plugin|standalone` and an exact
`--instance ID` when discovery needs disambiguation. No command silently starts
or restarts a host. Read the [agent configuration guide](docs/AGENT_CONFIGURATION.md)
for atomic patches, dry runs, persistence errors, reset scope and safe exports.
[`config/dock.json`](config/dock.json) contains bundled defaults, not necessarily
the running configuration.

The CLI is the configuration interface for AI coding agents and automation.
The accepted [Settings 3.1 design](docs/SETTINGS.md) is not shipped yet; there is
no live preference preview. **Change Icon** remains the sole icon editor:
right-click an app, window or pinned app and choose **Change Icon…** to edit its app-wide, browser-profile or window-title icon
through the same host writer. The dock, ordinary window previews, application picker,
context menus, drag reordering, workspace controls and Trash remain available.
The first sliders icon opens the existing launcher/add-application/auto-hide menu.
Changes are applied through the same host-owned writer without resetting existing
preferences, pins, hidden apps, custom icons or extension keys.

Use `config set KEY VALUE` for a single preference and `config apply --stdin`
for a related batch. Background, border and workspace badge colors accept
`#RRGGBB`, Qt `#AARRGGBB`, and symbolic Omarchy tokens such as `@accent` or
`@menu.background`. Set the paired `Enabled` flag to use an override; set it to
`false` to follow the theme without discarding the saved override. Tokens keep
following live theme changes. Workspace badges default to accent with white text.

```bash
printf '%s\n' '{"backgroundColorEnabled":true,"backgroundColor":"@menu.background"}' | dockrail config apply --stdin --dry-run --json
printf '%s\n' '{"backgroundColorEnabled":true,"backgroundColor":"@menu.background"}' | dockrail config apply --stdin --json
dockrail config set backgroundColorEnabled false --json
dockrail config set showTrash false --json
dockrail config set interfaceAnimationsEnabled false --json
dockrail config reset hoverGlowOpacity --json
```

Inspect `applied`, `persisted` and `writeState` separately. A failed save may be
active for the session only; read status before `config retry`. A transport
timeout has an unknown outcome and requires readback before retrying. Preference
reset (`config reset --preferences`) preserves pins, hidden apps, icon overrides,
margin and unknown keys. Use a key reset for a narrow request.

`controlCommand` is executable configuration used later by the launcher action;
never execute it merely to validate a setting. Preference reset also resets this
command. Use runtime metadata and touched-key rollback rather than silently
falling back to raw configuration writes on an older or incompatible host.

The following is an example configuration shape, not a replacement snapshot to
apply. Read the running host's schema/defaults and preserve the user's values:

```json
{
  "iconOverrides": {},
  "iconSize": 42,
  "magnification": 1.2,
  "magnificationRadius": 95,
  "hoverGlowEnabled": true,
  "hoverGlowOpacity": 0.72,
  "hoverGlowRadius": 28,
  "showPreviews": true,
  "showTrash": true,
  "margin": 10,
  "backgroundOpacity": 0.88,
  "backgroundColorEnabled": false,
  "backgroundColor": "",
  "borderColorEnabled": false,
  "borderColor": "",
  "workspaceBadgeBackgroundColorEnabled": false,
  "workspaceBadgeBackgroundColor": "",
  "workspaceBadgeTextColorEnabled": false,
  "workspaceBadgeTextColor": "",
  "borderWidthEnabled": false,
  "borderWidth": 2,
  "presentationMode": "classic",
  "presentationModeByMonitor": {},
  "sidebarEdge": "left",
  "sidebarMonitor": "",
  "sidebarExpandedWidth": 320,
  "sidebarCollapsed": false,
  "sidebarInlineSoloWorkspace": true,
  "position": "bottom",
  "fullLength": false,
  "reserveSpace": true,
  "autoHide": false,
  "clickAction": "focus-or-launch",
  "middleClickAction": "none",
  "scrollAction": "none",
  "controlCommand": "omarchy-menu toggle apps",
  "sortByWorkspace": false,
  "workspaceLayout": "flat",
  "workspaceMonitorScope": "all",
  "workspaceMonitorOrder": [],
  "groupWindows": false,
  "interfaceAnimationsEnabled": true,
  "attentionBadgesEnabled": true,
  "urgentWindowAnimationEnabled": true,
  "launcherBadgeMode": "automatic",
  "browserProfileBadgesEnabled": true,
  "dockHerdrIndicators": false,
  "dockT3Indicators": false,
  "dockClaudeIndicators": false,
  "browserActivityMutedServices": [],
  "sidebarBrowserTabsEnabled": true,
  "hiddenApplications": [],
  "pinned": [
    "org.gnome.Nautilus",
    "com.mitchellh.ghostty",
    "chromium"
  ]
}
```

### Options

| Option | Description |
| --- | --- |
| `iconOverrides` | App-wide, Dockrail-only local PNG/SVG artwork by desktop ID; defaults to `{}`; use `icons set/reset/reload` |
| `windowIconOverrides` | Ordered raw-Wayland `appId` + case-insensitive title-pattern rules; only `*` is special, first match wins, defaults to `[]` |
| `iconSize` | Base icon size in pixels |
| `magnification` | Maximum icon scale under the pointer |
| `magnificationRadius` | Distance over which nearby icons magnify |
| `hoverGlowEnabled` | Show the accent glow behind the icon currently under the pointer |
| `hoverGlowOpacity` | Glow intensity from `0.0` (hidden) to `1.0` (full strength) |
| `hoverGlowRadius` | Glow blur radius as a percentage of the icon size, from `0` to `100` |
| `showPreviews` | When `true`, show grouped window previews while hovering application icons; defaults to `true` |
| `showTrash` | When `true`, show the Trash shortcut and count; disabling it removes the Trash section and pauses Trash polling |
| `margin` | Distance between the dock and screen edge |
| `backgroundOpacity` | Dock background opacity from `0.0` (transparent) to `1.0` (opaque) |
| `backgroundColorEnabled` | When `true`, use `backgroundColor` instead of Omarchy's menu background token |
| `backgroundColor` | Custom dock background in `#RRGGBB`, `#AARRGGBB`, or an Omarchy token such as `@menu.background` |
| `borderColorEnabled` | When `true`, use `borderColor` instead of the theme border color |
| `borderColor` | Custom dock border color in `#RRGGBB`, `#AARRGGBB`, or an Omarchy token such as `@accent` |
| `workspaceBadgeBackgroundColorEnabled` | When `true`, use `workspaceBadgeBackgroundColor` for application workspace-number badge backgrounds |
| `workspaceBadgeBackgroundColor` | Workspace badge background in `#RRGGBB`, `#AARRGGBB`, or an Omarchy token such as `@accent` |
| `workspaceBadgeTextColorEnabled` | When `true`, use `workspaceBadgeTextColor` for application workspace-number badge text |
| `workspaceBadgeTextColor` | Workspace badge text in `#RRGGBB`, `#AARRGGBB`, or an Omarchy token such as `@foreground` |
| `borderWidthEnabled` | When `true`, use `borderWidth` instead of the theme border width |
| `borderWidth` | Custom dock border width from `0` to `8` pixels |
| `presentationMode` | Global default presentation: `classic` bottom dock (default) or `sidebar`; a connector listed in `presentationModeByMonitor` ignores this default |
| `presentationModeByMonitor` | Per-connector presentation overrides such as `{"DP-1":"classic"}`; listed connectors ignore `presentationMode` and `sidebarMonitor`, missing connectors inherit the default, disconnected names stay saved, and a menu or background-drag switch writes one entry for its monitor only |
| `position` | Classic dock edge; new writes accept only `bottom` because the vertical presentation is `presentationMode: sidebar`, and legacy `left`, `right` and `top` read as bottom |
| `fullLength` | Fill the classic dock screen width |
| `workspaceLayout` | `flat` (default) or `grouped` workspace cards; grouped applies to the bottom dock and scrolls when crowded |
| `workspaceMonitorScope` | Grouped cards: `all` (default) mirrors workspaces across docks; `current-monitor` shows only each dock’s monitor |
| `workspaceMonitorOrder` | Grouped/all monitor section order by exact connector name. `[]` uses automatic physical x/y order; saved disconnected connectors remain stored for reconnect. |
| `reserveSpace` | When `true` and `autoHide` is `false`, tiled windows stop beside the visible dock; hidden auto-hide docks do not reserve space |
| `autoHide` | Hide the dock until the pointer reaches its screen edge; can also be toggled from the right-click menu |
| `clickAction` | Action for an unmodified Left click; defaults to legacy-compatible `focus-or-launch` |
| `middleClickAction` | Action for an unmodified Middle click; defaults to `none` |
| `scrollAction` | Vertical scroll action; `cycle-windows` cycles grouped live windows, while `none` preserves pass-through |
| `controlCommand` | Shell command run by **Open App Launcher** in the first icon's controls menu; defaults to the stock `SUPER + ALT + SPACE` apps menu |
| `sortByWorkspace` | When `true`, group open apps by workspace number; closed pinned apps stay first |
| `groupWindows` | Deprecated; new writes accept only `false`. Use `workspaceGroups` for grouping in classic workspace cards. |
| `interfaceAnimationsEnabled` | Animate workspace focus, card/icon insertion and removal, window moves, and context-menu opening; defaults to `true` |
| `windowScope` | Running-window visibility: `all`, `workspace`, `monitor`, or `workspace-monitor`; invalid/missing values use `all` |
| `showUrgentOutsideScope` | When enabled, a true Hyprland-urgent window may bypass a non-`all` scope; notification/SNI attention does not |
| `attentionBadgesEnabled` | Show application attention badges. Dot severity remains the fallback; in automatic mode an authoritative positive visible launcher count may replace that dot. |
| `urgentWindowAnimationEnabled` | When `true`, active SNI, critical local-notification, or Hyprland urgent attention may nudge the owning application icon, no more than once every 3000 ms while attention remains. A launcher count alone never animates; a count with attention still does. Motion is effective only while `attentionBadgesEnabled` is also enabled; disabling it leaves the static badge intact. |
| `launcherBadgeMode` | `automatic` shows authoritative application-provided counts when available; `dots-only` ignores numeric provider state and preserves dots only. |
| `browserProfileBadgesEnabled` | Show per-window browser profile badges when the browser-profile provider is installed and the browser exposes a DevTools endpoint; no provider is installed or started by this setting. |
| `dockHerdrIndicators` | Show Herdr agent state on terminal icons, in hover previews and in the context menu. Uses the existing Herdr provider; enabling it starts that provider while a classic dock is active, including when it is auto-hidden. |
| `dockT3Indicators` | Show T3 Code thread state on the T3 Code icon, in hover previews and in the context menu. Pair with dockrail t3 pair; requires a classic dock to run for dock-only demand. |
| `dockClaudeIndicators` | Show Claude Desktop session state on the Claude Desktop dock icon and in its sidebar window row: a working spinner while a session runs, plus input-needed and done marks. The sidebar row also lists one row per session that needs attention. Install the Claude Code hooks with dockrail claude hooks install. |
| `browserActivityMutedServices` | Service IDs muted from Chrome activity header and badge totals (`gmail`, `whatsapp`, …); rows stay visible/dimmed and openable; retained by preference reset |
| `sidebarBrowserTabsEnabled` | When true and the browser-profile provider is available, sidebar Chrome windows can expand to list open page tabs (titles only, no URLs) |
| `sidebarInlineSoloWorkspace` | When true, populated workspace names share the first application/window row instead of using a dedicated row; empty workspaces remain dedicated rows. Set `false` to retain separate workspace rows |
| `hiddenApplications` | Desktop-entry IDs hidden from the dock; applications remain running and pinned membership/order is preserved |
| `pinned` | Ordered desktop-entry IDs displayed in the dock |

### Application and icon commands

```bash
dockrail apps list --query 'Editor' --json
dockrail apps list --pinned --json
dockrail apps list --hidden --json
dockrail apps pin code --json
dockrail apps move code --before org.gnome.Nautilus --json
dockrail apps move code --after org.gnome.Nautilus --json
dockrail apps hide code --json
dockrail apps show code --json
dockrail apps show --all --json
dockrail apps unpin code --json
dockrail icons list --json
dockrail icons set code "$HOME/Pictures/Dock Icons/Ícone.svg" --json
dockrail icons reload code --json
dockrail icons reset code --json
```

Use actual IDs from `apps list`; the examples are not guaranteed installed IDs.
Discovery uses the host's native desktop-entry catalog and keeps unavailable
stored pins/hidden IDs visible in its output. IDs match exactly after case
folding and optional `.desktop` removal, never by fuzzy name. Pinning does not
unhide an app; hiding does not unpin it or close windows. Show only clears hidden
membership. Move requires two different pinned IDs and preserves the relative
order of all other entries, including hidden and unavailable pins. Repeating a
membership command is a no-op rather than another settings write.

`iconOverrides` defaults to `{}` and changes only Dockrail artwork. Each entry
applies across main icons, preview metadata and app-picker rows. It never changes
`.desktop` files, launch identity, window grouping, screenshots, badges, Trash or
action glyphs. A browser tab grouped as Chrome remains a Chrome item; custom
artwork does not split browser groups.

Only local static PNG/SVG files are accepted. Ordinary relative paths supplied
to the CLI are resolved from its current directory; the host accepts absolute
local paths and local `file:///` URLs, preserving spaces and Unicode. Remote
URLs and other formats are rejected. Files are referenced in place, not copied,
so keep them outside the plugin checkout. Per-app set/reset preserves unrelated
map entries. Preference reset also preserves `iconOverrides`.

The bounded fallback is **custom file → original desktop icon →
`application-x-executable` → bundled theme-tinted `app-window` glyph**. Custom
artwork is not tinted. Missing or corrupt images retain the requested mapping
and fall back instead of being silently removed.

The dock watches referenced artwork files and refreshes automatically about
250 ms after one is edited, replaced, deleted or recreated at the same path.
`icons reload ID` remains for compatibility and to force a refresh; it bumps the
global artwork revision without writing settings, and other mapped icons may
refresh too. Setting an equivalent source also requests a reload without a
redundant save. Every successful icon response
reports `renderVerified: false`: persistence and reload requests do not prove
image decoding or a visible redraw. Check the visible result on your Omarchy
desktop; headless tests cannot confirm image decoding or cache behavior there.

### Application pointer actions

The Left and Middle click keys accept the same vocabulary: `none`,
`minimize-restore`, `previews`, `close`, and `focus-or-launch`. `scrollAction`
is intentionally narrower: `none` or `cycle-windows`.

```bash
dockrail config set clickAction focus-or-launch --json
dockrail config set middleClickAction none --json
dockrail config set scrollAction cycle-windows --json
```

Input precedence is intentionally strict:

- Right click always opens the existing application context menu.
- Left click with no modifier uses `clickAction`.
- Ctrl+Left click uses the same `clickAction`; with `focus-or-launch` on a running group it moves just the window a plain click would focus to the clicked dock monitor's active workspace, then focuses it. Plain Left click focuses the exact window in place, including window icons inside grouped workspace cards. The dock uses on-demand keyboard focus so Ctrl can be held before entering it.
- Middle click with no modifier uses `middleClickAction`.
- Ctrl+Middle click uses the same `middleClickAction`, including the workspace pull when that action is `focus-or-launch`.
- Vertical-dominant scrolling uses `scrollAction`; horizontal/tied gestures pass through.
- Alt, Meta, Shift, and mixed modifier combinations do not trigger click or scroll actions. Ctrl does not trigger scroll actions.

The current action semantics are:

- `none`: no action.
- `minimize-restore`: all-or-nothing grouped behavior. If any member is visible,
  all visible members are minimized through the host-owned window controller;
  if all are minimized, all are restored through the same recorded-origin
  state.
- `previews`: show the grouped window preview popup when `showPreviews` is
  enabled. The same popup also opens after briefly hovering an application with
  two or more running windows.
- `close`: request graceful closure of every live grouped member.
- `focus-or-launch`: unmodified clicks focus successive windows in a running
  group in dock order without moving workspaces; a closed pinned application
  launches. Ctrl+click moves just the window a plain click would focus (same
  cycling order) to the clicked dock monitor's active workspace and focuses it.

Existing configuration files need no migration. If either action key is absent,
it normalizes to its default; an absent or invalid legacy `clickAction`
normalizes to `focus-or-launch`. Older `focus` and `launch` action values are
also normalized to `focus-or-launch`, so existing settings retain their useful
behavior. Invalid values for `middleClickAction` normalize to `none`. Missing or invalid
`scrollAction` values also normalize to `none`, so existing configurations keep
their current behavior. When set to `cycle-windows`, scroll input is consumed
only for a grouped icon with at least two live windows. High-resolution vertical
deltas accumulate in 120-unit steps, residual input resets after about 220 ms,
and minimized targets restore through the shared host-owned window controller
before focus.

### Window scope filtering

`windowScope` filters individual running windows before grouping. `all` preserves
existing behavior; `workspace` uses the workspace active on Hyprland's focused
monitor; `monitor` uses each Dock's own screen/monitor; and
`workspace-monitor` requires both. Closed pinned launchers stay visible.

```bash
dockrail config set windowScope workspace --json
dockrail config set showUrgentOutsideScope true --json
```

When `showUrgentOutsideScope` is enabled, only Hyprland's actual per-window
urgent state bypasses scope. Explicitly hidden applications still stay hidden.
Dockrail-minimized windows use the shared host-owned workspace/monitor origin;
unknown or transient location data fails open so the only restore affordance is
not lost. Scope refresh is debounced once in `DockHost.qml` for all monitor
Docks, with no per-Dock `hyprctl` polling.

### Application attention badges

Attention dots deliberately represent **attention state**, not inferred unread
counts. Dockrail reduces three sources when they are available:
StatusNotifierItem `NeedsAttention`, Hyprland's live urgent state/events, and
the Omarchy notification service. Notification events are never counted.
Identity matching is exact after case-folding and an optional `.desktop` suffix
removal; desktop-entry ID, application ID, `startupClass`, display name, and
explicitly configured aliases are accepted, but substring/fuzzy matching is
not. Grouped applications render one badge; ungrouped applications assign the
badge to the first visible item for that app. Hidden applications do not render
a badge.

Attention motion follows active badge severity: SNI `NeedsAttention`, critical
local-notification attention, and Hyprland urgent window state can trigger the
nudge. A previously absent Hyprland urgent **window address** still creates a
motion revision, while duplicate urgency for an address that remains urgent
does not. A launcher count without attention never triggers motion; a count
coexisting with attention still does. Titles, notification bodies,
terminal/editor output, sender data, and window content never create a motion
trigger. Each play is the bounded `0 -> 5 -> 0 -> 3 -> 0` px sequence over
about 520 ms with OutCubic easing; reminders repeat no more than once every
3000 ms while attention remains active. Hover, drag, context menus, and preview
interaction suppress motion without clearing the badge. Auto-hidden docks do
not reveal for attention; pending timer/reveal retries remain safe while the
badge is active. Hidden/restored applications and startup prime at the current
revision so stale urgency is not replayed. See
[`docs/attention-badges.md`](docs/attention-badges.md) for ownership and motion
semantics.

When the optional launcher provider is available and `launcherBadgeMode` is
`automatic`, a positive count with `count-visible=true` takes precedence over
the attention dot. Counts above 99 render as `99+`. Explicit zero or
`count-visible=false` hides the number and allows any current attention
dot to remain visible. `dots-only` ignores numeric state entirely. The count is
authoritative application state: focusing a window does **not** clear it.
Provider sender disconnects clear sender-owned state, and reconnects start from
fresh state rather than carrying stale fields across process ownership.

Dismissing a notification popup does not mark local attention read. Local
notification attention expires after 24 hours and clears only after the matched
application remains focused for about 800 ms. Live SNI state and authoritative
launcher counts are never cleared by Dockrail focus handling. Standalone mode,
or an Omarchy host without either optional service, simply omits the unavailable
source while the remaining sources continue to work.

The first dock icon is always the dock controls icon and is not part of
`pinned`. Clicking it opens the controls menu; **Open App Launcher** runs
`controlCommand`, while the menu also exposes Add Pinned Application,
**Switch to sidebar**, and the auto-hide toggle. The sidebar instead has a direct **Dockrail Settings** gear; you can switch back
to the classic dock through the Layout section of Dockrail Settings or a background drag. Application context menus
contain only application and window actions.
For example, with the Omarchy app-launcher plugin already installed:

```bash
dockrail config set controlCommand "omarchy-shell shell toggle tyrsolution.app-launcher '{}'" --json
```

The trailing Trash and workspace controls are not part of `pinned`. Trash uses
the freedesktop `trash:///` location and can be removed from the dock with
`showTrash`; while hidden, Dockrail also pauses its recurring Trash count
query. Workspace buttons always include 1 and 2, then add any focused or
occupied workspace through 10; clicking a number focuses it.

Pinned values are desktop-entry IDs. List the authoritative running host's IDs with:

```bash
dockrail apps list --json
```

Right-click any application in the dock and choose **Hide from Dock** to hide
the whole application while leaving its windows running and its pinned
membership unchanged. The canonical desktop-entry ID is stored in
`hiddenApplications`, so the choice persists across restarts and live config
reloads. Inspect hidden apps with `dockrail apps list --hidden --json`; use
`dockrail apps show ID --json` to restore one or `dockrail apps show --all --json`
to clear hidden membership. Restoring an application returns it to its existing
pinned position without pinning or unpinning anything. `config reset --preferences`
intentionally preserves `hiddenApplications` and the other application collections.

The configuration file is watched and updates automatically. Drag a dock icon to another slot to reorder it; the new `pinned` order is written back to this file. Switch to the sidebar using **Switch to sidebar** in Dock Controls; return to the classic dock through the Layout section of Dockrail Settings or a background drag. You can also drag genuinely empty background: drag the bottom dock's background left (48 px or more) to switch that monitor to the sidebar, or drag empty sidebar background downward to return it to the bottom dock. The hint pill, the destination silhouette and the result stay on the monitor where the drag started; other monitors keep their own modes, so a mixed layout with a classic dock beside a sidebar is normal. While you drag, a direction hint pill appears and, once the threshold is crossed, a silhouette of the destination edge previews where it will render; releasing past the threshold commits one `presentationModeByMonitor` entry for that connector once, and releasing earlier, pressing Escape, or an interrupted drag (open menu, popup, resize or row drag) cancels with no settings write. Only background is eligible — rows, widgets, headers, pinned strips and controls keep their own input. The existing settings writer persists the mode only after release. Feedback for a rejected or failed commit appears only on the monitor that produced the gesture. Reserved space follows visibility: while auto-hide is off, the `reserveSpace` option decides whether tiled windows keep a clear dock-sized area; while auto-hide is on, the hidden dock never reserves space.

### Focused-monitor keyboard shortcut

Toggle **only the currently focused monitor** between the bottom dock and
sidebar without restarting the host:

```bash
dockrail mode toggle --json
```

For Omarchy Quattro, add this optional binding to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + D", "Toggle Dockrail dock/sidebar", "dockrail mode toggle")
```

Check `omarchy menu keybindings --print` first and choose a different chord
if it is occupied; Dockrail does not install or override user keybindings.
Use `o.rebind` only when you intentionally replace an existing binding on
Omarchy versions supporting that helper. After editing, run
`hyprctl reload` and `hyprctl configerrors`. The monitor is selected by
Hyprland focus, **not** by pointer hover. The command updates just that
output's `presentationModeByMonitor` entry through the host's existing
settings writer; all other monitor overrides survive unchanged. An inherited
sidebar hidden by a `sidebarMonitor` pin is revealed on the first toggle.
For an `E_BUSY` or `E_PERSISTENCE` response, inspect
`dockrail status --json` before assuming the choice was saved.
See the [CLI reference](docs/CLI_REFERENCE.md#focused-monitor-presentation-shortcut).

Surface override settings are independent. Leave an `*Enabled` flag set to
`false` to follow the active Omarchy theme; enable it to use the matching
custom color or width. Custom background alpha is multiplied by
`backgroundOpacity` just like the theme background.

For a left sidebar as the default presentation, use one related patch. Existing
per-monitor choices in `presentationModeByMonitor` take precedence and are kept;
use **Switch to sidebar** on that monitor's Dock Controls menu to change only
that monitor. The classic dock remains bottom-only.

<!-- recipe: sidebar-default -->
```bash
printf '%s\n' '{"presentationMode":"sidebar","sidebarEdge":"left"}' | dockrail config apply --stdin --json
```

### Disable cursor warping

Hyprland controls whether the pointer moves when focus switches to a window on another workspace. This is compositor-wide behavior and cannot be reliably overridden by the dock.

On Omarchy, add this override to `~/.config/hypr/looknfeel.lua`:

```lua
hl.config({
  cursor = {
    warp_on_change_workspace = 0,
  },
})
```

Hyprland normally reloads after the file is saved. Validate the configuration with:

```bash
hyprctl reload
hyprctl configerrors
```

This disables cursor warping for all workspace changes, not only dock clicks.

## Roadmap

- Theme integration

## License

[MIT](LICENSE)

### Workspace cards (opt-in)

Use `dockrail config set workspaceLayout grouped --json` to enable horizontal
workspace cards. Use `dockrail config set workspaceLayout flat --json` to roll
back. Missing/invalid values and `config reset workspaceLayout` use flat.
Workspace cards are a classic-dock layout; the sidebar keeps its own hierarchy.
Window scope, workspace sorting and urgent-outside-scope affect the flat layout;
their saved values are preserved. Use `workspaceGroups` to group applications in
workspace cards; the legacy `groupWindows` setting is deprecated.

By default, `workspaceMonitorScope: all` shows the same ordered monitor sections,
workspaces and applications on every monitor dock. When more than one monitor is
connected, each monitor section is introduced inline before its first present
workspace card by a small display glyph and a bounded informational label. With
only one connected monitor, Dockrail omits that redundant glyph and label. The compact label prefers the live
monitor model, then description, connector/name, and `Monitor N`; the full
description/connector remains available in the tooltip/accessibility text. The
prefix is not clickable, does not take keyboard focus, and is not a workspace-drop target.
Use
`dockrail config set workspaceMonitorScope current-monitor --json` for the
existing local, unprefixed workspace-card appearance. Missing/invalid values and
`config reset workspaceMonitorScope` use `all`; flat layouts remain unchanged.

In grouped/all scope, every connected monitor may therefore have one active card
at the same time: its own active workspace. Only the workspace on Hyprland's
globally focused monitor is the primary workspace used for automatic reveal and
global badge/preview traversal. Switching global focus between monitors changes
that primary reveal without changing workspace/card identity or the physical
section order. Closed global launchers still render once before all monitor
sections, and **Other windows** still renders once after all sections.

`workspaceMonitorOrder` controls only the visual order of those sections; it
never moves a Hyprland monitor or workspace. The default `[]` uses automatic
physical order by finite monitor `x`, then `y`, with deterministic
connector/identity ties and monitors lacking usable positions after positioned
monitors. A saved connector list such as `["HDMI-A-1","DP-1"]` puts those
connected monitors first; other connected monitors append automatically. Saved
disconnected connector names remain stored and resume their configured position
after reconnect. Flat and `current-monitor` layouts retain the value but do not
use it visually. Reset automatic ordering with
`dockrail config reset workspaceMonitorOrder --json`.

Every normal workspace in the selected scope always shows all its app icons
inside a rounded translucent card, including inactive workspaces. Cards use
narrow workspace labels and a subtle tint across the active group; the label and
card styling identify activity. Window counts remain in the header tooltip.
Empty workspaces retain their header. With `current-monitor`, known windows on
another monitor are excluded. Window actions and previews use only the item's
members; hide and launcher pinning remain application-wide. Pinned reordering
and redundant per-icon workspace labels are disabled in grouped mode; running-
window dragging is described below.

Clicking a grouped workspace header focuses that workspace where it already is.
Ctrl+click pulls that workspace to the clicked dock before focusing it. Plain
window-icon activation focuses the exact window in place; Ctrl+click moves just
that window to the clicked dock monitor's active workspace and focuses it. Dockrail also has
**session-only movement pins** owned by the
shared window-action controller: an individual window can be pinned to its
current reliable workspace from its context menu. The controller also retains
workspace-monitor pin enforcement for callers that establish such a pin, though
the current workspace header has no pin menu. These pins are deliberately not
settings, Hyprland rules, or persistent configuration; restarting the Dockrail
host clears them.

A window workspace pin blocks Dockrail menu and drag relocations to another
workspace, including represented groups when any captured member is pinned.
Dockrail minimize/restore keeps the recorded origin and does not clear the pin.
A workspace monitor pin makes workspace-header, Ctrl app-icon, preview, cycling
and restore activation focus the workspace where it already lives instead of
pulling it to the dock monitor. Plain app-icon activation already stays in
place. External Hyprland shortcuts/tools remain free to
move windows and workspaces; once Dockrail observes a confirmed external move,
close, or monitor disconnect it drops only the affected session pin. Transient
or incomplete refreshes do not by themselves clear pin state. Group/Ungroup
changes leave window pins untouched.

Drag a grouped workspace header onto another monitor's Dockrail to move the
whole workspace there without sending a focus command. The source dock must
already be visible. An auto-hidden destination reveals when the pointer reaches
its normal edge strip; release over its visible background to move, or release
elsewhere, return to the source dock, or press Escape to cancel. A session pin
rejects the move. In `current-monitor` scope the card leaves the source dock and
appears on the destination; in `all` scope every dock mirrors the same move from
the source monitor section to the destination section. There is no drag setting,
and app reordering and window-to-card dragging are unchanged.

Grouped minimize/restore requires a validated recorded workspace: an unknown
origin never moves a window to a guessed focused workspace. Flat mode retains
its fallback. Sticky windows appear once on their monitor’s active normal
workspace with a small marker; minimized windows retain their recorded origin.
Local urgency marks its workspace and member icons. App-wide notification badges
have one visible owner per app per dock, without claiming a notification belongs
to a workspace.

Crowded cards and monitor prefixes stay in one bounded horizontal viewport. Use
the previous/next buttons with a mouse; app wheel cycling keeps its configured
behavior. Dock Controls and optional Trash stay fixed. The Dock Controls menu's **Add Pinned
Application** entry opens the searchable app picker. A workspace switch reveals
only the globally primary card's real header, not its monitor prefix; manual
scroll and drag suppression remain authoritative. Scrolling a popup's icon out
of view closes the popup. Compact and full-length layouts retain magnification
headroom without adding another row or increasing card height.

Both dock layouts use hover-highlighted icon tiles, accent window-count badges,
a broad focus underline, and spaced utility separators. Flat mode includes a
rounded workspace selector with a tinted active pill; grouped mode keeps every
workspace’s icons visible. Icon size, surface overrides and Show Trash still apply.

### Drag windows between workspace cards

In the bottom grouped layout, hold the left mouse button without modifiers
and drag a running icon past the normal drag threshold onto a workspace card's
visible header or app area. A grouped icon moves only the exact windows captured
from that icon, not other same-app windows elsewhere. The source artwork dims
and a floating icon shows the surviving group count. A click below the threshold
keeps its configured action. Flat/vertical layouts and their pinned reordering
remain unchanged; there is no new drag setting.

The floating icon uses the same `DockAppIcon` renderer as the dock, including
CLI icon overrides, bounded fallback and artwork reloads. The scene-local drag
coordinator remains QtQuick-only; the host supplies its artwork delegate.

Visible members move silently, without following or focusing them. Dockrail-
minimized members stay hidden on `special:smartdock-minimized`; only their saved
restore workspace and destination monitor change. An explicit valid drop can
establish a missing restore origin. Members already at the destination are
skipped. Closed members are never replaced by another window, and an entirely
closed group cancels. Sticky or unresolved surviving members are rejected.

Existing normal workspaces in the selected monitor scope remain valid
destinations, including empty cards, IDs above 10, and safely supported names
with spaces or Unicode. Named cards are resolved by their real identity, not the
compact `*` label. While a window-icon drag is active, Dockrail also shows a
temporary **New workspace** (+) target after the final workspace card for each
visible monitor section. Dropping there allocates the lowest free numeric
workspace, moves the exact captured window group into it, relocates that new
workspace to the target monitor, then follows the moved group. Monitor
labels/separators, their prefix gaps, **Other windows**, special sections,
ordinary gaps, Trash, navigation buttons and clipped-out areas are not
destinations. A non-sticky **Other windows** source is allowed only when its live
handle/address is resolvable. Window-icon dragging between separate monitor-dock
surfaces remains unsupported; workspace-header dragging between docks is
described above.

Hold over an overflow navigation button for 250 ms to scroll at 12 logical
pixels per 40 ms; scrolling stops at the boundary, on leaving the button, or when
the gesture ends. Releasing there cancels rather than switching workspaces. The
dock stays revealed during the drag; previews, tooltips, competing actions,
flicking and active-card auto-reveal pause. Card replacement is deferred, but
live window/destination validation continues. Release rechecks the final pointer
and live destination; lost grabs, invalid releases or incompatible layout changes
clear the feedback without moving windows. See the
[developer test notes](docs/superpowers/plans/2026-09-09-smartdock-workspace-drag.md)
for automated coverage and the pointer checks that need an Omarchy desktop.

### Global sidebar

The sidebar is configured with `presentationMode` (default `classic`),
`presentationModeByMonitor` (empty = every connector follows the effective
default, so one output can run the bottom dock while another runs the sidebar),
`sidebarEdge` (`left`), `sidebarMonitor` (empty = all connected monitors), `sidebarExpandedWidth` (320),
`sidebarCollapsed` (false), `sidebarCollapsedByMonitor` (`{}`),
`sidebarInlineSoloWorkspace` (true),
`sidebarBrowserTabsEnabled` (true), `sidebarWidgets` (empty), and
`sidebarWidgetCollapsed` (`{}`). It shows
monitor/workspace/application/window hierarchy or every individual window icon
in a rail; app groups fold, and Chrome windows can expand open tabs when the
provider is available (see [`docs/browser-tabs.md`](docs/browser-tabs.md)).
Classic preferences remain unchanged. Check the selected host with
`dockrail config schema --json` for the settings supported by your installation.
See the [sidebar developer reference](docs/SIDEBAR.md) for implementation details.

The [Widget system](docs/SIDEBAR_WIDGETS.md) shares host-owned provider leases
across independently scrollable hierarchy and Widget body panes. The Widget header, PINNED and Applications remain fixed.
A content-aware 55% hierarchy cap returns unused space; constrained height
preserves the full Widget header when possible and otherwise hides the section
without removing the main-header Add/Manage entry. Hidden Herdr fallback cards
reserve no space while keeping their leases. This is not the retired compact
footer or a configurable splitter.
`sidebarWidgets` stores enabled order and `sidebarWidgetCollapsed` stores card
body state. Empty configuration adds no Widget-section height/work; unknown imported
IDs are unavailable and never executed. Test providers exist only in fixtures.
Scrolling, focus and pointer behavior must be checked in the actual desktop session.
