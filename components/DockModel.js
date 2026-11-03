.pragma library
.import "DockSidebarWidgetModel.js" as SidebarWidgetModel

function normalizedId(value) {
  return String(value || "").toLowerCase().replace(/\.desktop$/, "")
}

var TERMINAL_APP_IDS = [
  "com.mitchellh.ghostty", "ghostty",
  "kitty", "alacritty", "org.alacritty",
  "foot", "footclient",
  "org.wezfurlong.wezterm", "wezterm",
  "gnome-terminal", "org.gnome.terminal",
  "konsole", "org.kde.konsole",
  "ptyxis", "org.gnome.ptyxis",
  "xterm", "uxterm"
]

var TERMINAL_CLI_APP_IDS = [
  "opencode", "herdr", "kimi", "codex", "hermes",
  "smartdock-agent-pi", "smartdock-agent-oh-my-pi",
  "smartdock-agent-command-code", "smartdock-agent-cursor",
  "smartdock-agent-claude-code", "smartdock-agent-kilo-code",
  "smartdock-agent-cline", "smartdock-agent-herdr"
]

var TERMINAL_AGENT_APP_IDS = [
  "smartdock-agent-pi", "smartdock-agent-oh-my-pi",
  "smartdock-agent-command-code", "smartdock-agent-cursor",
  "smartdock-agent-claude-code", "smartdock-agent-kilo-code",
  "smartdock-agent-cline", "smartdock-agent-herdr"
]

var TERMINAL_AGENT_APP_ID_MAPPINGS = [
  ["io.github.fernandodamaso.smartdock.agent.pi", "smartdock-agent-pi"],
  ["io.github.fernandodamaso.smartdock.agent.oh-my-pi", "smartdock-agent-oh-my-pi"],
  ["io.github.fernandodamaso.smartdock.agent.command-code", "smartdock-agent-command-code"],
  ["io.github.fernandodamaso.smartdock.agent.cursor", "smartdock-agent-cursor"],
  ["io.github.fernandodamaso.smartdock.agent.claude-code", "smartdock-agent-claude-code"],
  ["io.github.fernandodamaso.smartdock.agent.kilo-code", "smartdock-agent-kilo-code"],
  ["io.github.fernandodamaso.smartdock.agent.cline", "smartdock-agent-cline"],
  ["io.github.fernandodamaso.smartdock.agent.herdr", "smartdock-agent-herdr"]
]

var TERMINAL_AGENT_SPINNER_FRAMES = [
  "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
]

var TERMINAL_AGENT_CLAUDE_STATUS_SYMBOLS = [
  "✳", "✱", "✢", "✶", "✻", "✽", "⠂", "⠐", "◐", "◓", "◑", "◒"
]

var TERMINAL_AGENT_KILO_STATUS_SYMBOLS = [
  "◔", "⚠", "✓", "💭", "🔶", "✅"
]

function hasNonemptyTitleSuffix(title, prefix) {
  return title.indexOf(prefix) === 0
    && title.slice(prefix.length).trim() !== ""
}

function hasKnownStatusPrefix(title, base, symbols) {
  for (var i = 0; i < symbols.length; ++i) {
    if (title === symbols[i] + " " + base) return true
  }
  return false
}

function hasKnownStatusSessionTitle(title, base, symbols) {
  for (var i = 0; i < symbols.length; ++i) {
    if (hasNonemptyTitleSuffix(title, symbols[i] + " " + base + " | "))
      return true
  }
  return false
}

function hasKnownStatusTitle(title, prefix, symbols) {
  for (var i = 0; i < symbols.length; ++i) {
    var marker = prefix + symbols[i]
    if (title.indexOf(marker) !== 0) continue
    var suffix = title.slice(marker.length)
    if (suffix === "" || /^\s+\S/.test(suffix)) return true
  }
  return false
}

function terminalCliAppId(title) {
  var text = String(title || "").trim()
  var raw = text.toLowerCase()
  if (!raw) return ""
  if (/^π - .*\S.*$/.test(text))
    return "smartdock-agent-pi"
  if (text === "π"
      || /^π\s*[:>!](?:\s+.*\S)?$/.test(text)
      || hasKnownStatusTitle(text, "π ", TERMINAL_AGENT_SPINNER_FRAMES))
    return "smartdock-agent-oh-my-pi"
  if (/^⌘ Command Code(?: · .*\S)?$/.test(text))
    return "smartdock-agent-command-code"
  if (text === "Cursor Agent" || text === "Cursor Agent (local-agent)")
    return "smartdock-agent-cursor"
  if (text === "Claude Code"
      || hasKnownStatusPrefix(text, "Claude Code",
        TERMINAL_AGENT_CLAUDE_STATUS_SYMBOLS))
    return "smartdock-agent-claude-code"
  if (text === "Kilo CLI"
      || hasKnownStatusPrefix(text, "Kilo CLI",
        TERMINAL_AGENT_KILO_STATUS_SYMBOLS)
      || hasKnownStatusSessionTitle(text, "Kilo CLI",
        TERMINAL_AGENT_KILO_STATUS_SYMBOLS)
      || hasNonemptyTitleSuffix(text, "Kilo CLI | "))
    return "smartdock-agent-kilo-code"
  if (text === "Cline")
    return "smartdock-agent-cline"
  // opencode replaces the window title with its session title
  // (e.g. "OC | <session>") shortly after launch.
  if (raw.indexOf("opencode") >= 0 || /^oc\s*\|/.test(raw))
    return "opencode"
  // Herdr writes its own marker to the terminal title via window_title
  // (e.g. "omarchy · herdr · Lumen Media Hub").
  if (raw.indexOf("herdr") >= 0)
    return "herdr"
  // Kimi leaves the terminal title alone, so a shell wrapper marks it
  // (see ~/.bashrc): the title is "kimi" for the whole session.
  if (raw.indexOf("kimi") >= 0)
    return "kimi"
  // Same for Codex: terminal_title is set to [] so the wrapper-set
  // "codex" title survives for the whole session.
  if (raw.indexOf("codex") >= 0)
    return "codex"
  // Hermes CLI: marked by a shell wrapper like kimi/codex
  // (see ~/.bashrc).
  if (raw.indexOf("hermes") >= 0)
    return "hermes"
  return ""
}

function entryForCliAppId(cliAppId, entries) {
  var wanted = normalizedId(cliAppId)
  if (!wanted) return null
  var list = entries || []
  for (var i = 0; i < list.length; ++i) {
    if (normalizedId(list[i].id) === wanted)
      return list[i]
  }
  for (var j = 0; j < list.length; ++j) {
    if (normalizedId(list[j].name) === wanted)
      return list[j]
  }
  return null
}

function entryForTerminalAgentAppId(appId, entries) {
  var wanted = normalizedId(appId)
  var list = entries || []
  for (var i = 0; i < list.length; ++i) {
    if (normalizedId(list[i].id) === wanted)
      return list[i]
  }
  return null
}

function terminalAgentDesktopId(appId) {
  var wanted = normalizedId(appId)
  for (var i = 0; i < TERMINAL_AGENT_APP_ID_MAPPINGS.length; ++i) {
    if (TERMINAL_AGENT_APP_ID_MAPPINGS[i][0] === wanted)
      return TERMINAL_AGENT_APP_ID_MAPPINGS[i][1]
  }
  return ""
}

function toplevelAppId(toplevel, entries) {
  var appId = toplevel ? toplevel.appId : ""
  if (!appId) return ""
  var normalizedAppId = normalizedId(appId)
  var agentDesktopId = terminalAgentDesktopId(normalizedAppId)
  if (agentDesktopId) {
    var agentEntry = entryForTerminalAgentAppId(agentDesktopId, entries)
    return agentEntry ? agentEntry.id : appId
  }
  if (TERMINAL_APP_IDS.indexOf(normalizedAppId) < 0)
    return appId
  var cliAppId = terminalCliAppId(toplevel.title)
  if (!cliAppId || TERMINAL_CLI_APP_IDS.indexOf(cliAppId) < 0)
    return appId
  var cliEntry = TERMINAL_AGENT_APP_IDS.indexOf(cliAppId) >= 0
    ? entryForTerminalAgentAppId(cliAppId, entries)
    : entryForCliAppId(cliAppId, entries)
  if (!cliEntry)
    return appId
  return cliEntry.id
}

function normalizeApplicationIds(value) {
  if (!Array.isArray(value)) return []

  var normalized = []
  for (var i = 0; i < value.length; ++i) {
    var id = String(value[i] === undefined || value[i] === null
      ? "" : value[i]).trim()
    if (!id) continue

    var key = id.toLowerCase()
    var duplicate = false
    for (var j = 0; j < normalized.length; ++j) {
      if (normalized[j].toLowerCase() === key) {
        duplicate = true
        break
      }
    }
    if (!duplicate) normalized.push(id)
  }
  return normalized
}

function normalizeMonitorConnectors(value) {
  if (!Array.isArray(value)) return []
  var normalized = []
  for (var i = 0; i < value.length; ++i) {
    if (typeof value[i] !== "string" || !value[i]
        || value[i] !== value[i].trim() || /[\x00-\x1f\x7f]/.test(value[i])
        || normalized.indexOf(value[i]) >= 0)
      return []
    normalized.push(value[i])
  }
  return normalized
}

function addHiddenApplication(ids, desktopId) {
  var normalized = normalizeApplicationIds(ids)
  var id = String(desktopId === undefined || desktopId === null
    ? "" : desktopId).trim()
  if (!id) return normalized

  var key = id.toLowerCase()
  for (var i = 0; i < normalized.length; ++i) {
    if (normalized[i].toLowerCase() === key) return normalized
  }

  normalized.push(id)
  return normalized
}

function removeHiddenApplication(ids, desktopId) {
  var normalized = normalizeApplicationIds(ids)
  var id = String(desktopId === undefined || desktopId === null
    ? "" : desktopId).trim().toLowerCase()
  if (!id) return normalized

  var remaining = []
  for (var i = 0; i < normalized.length; ++i) {
    if (normalized[i].toLowerCase() !== id) remaining.push(normalized[i])
  }
  return remaining
}

function normalizeBrowserActivityServiceId(value) {
  var id = String(value === undefined || value === null ? "" : value)
    .trim().toLowerCase()
  if (!id || id.length > 64 || !/^[a-z0-9][a-z0-9_-]*$/.test(id)) return ""
  return id
}

function normalizeBrowserActivityMutedServices(value) {
  if (!Array.isArray(value)) return []
  var normalized = []
  for (var i = 0; i < value.length; ++i) {
    var id = normalizeBrowserActivityServiceId(value[i])
    if (!id || normalized.indexOf(id) >= 0) continue
    normalized.push(id)
  }
  return normalized
}

function isBrowserActivityServiceMuted(ids, serviceId) {
  var wanted = normalizeBrowserActivityServiceId(serviceId)
  if (!wanted) return false
  var list = normalizeBrowserActivityMutedServices(ids)
  return list.indexOf(wanted) >= 0
}

function muteBrowserActivityService(ids, serviceId) {
  var normalized = normalizeBrowserActivityMutedServices(ids)
  var id = normalizeBrowserActivityServiceId(serviceId)
  if (!id || normalized.indexOf(id) >= 0) return normalized
  normalized.push(id)
  return normalized
}

function unmuteBrowserActivityService(ids, serviceId) {
  var normalized = normalizeBrowserActivityMutedServices(ids)
  var id = normalizeBrowserActivityServiceId(serviceId)
  if (!id) return normalized
  var remaining = []
  for (var i = 0; i < normalized.length; ++i) {
    if (normalized[i] !== id) remaining.push(normalized[i])
  }
  return remaining
}

function toggleBrowserActivityServiceMute(ids, serviceId) {
  return isBrowserActivityServiceMuted(ids, serviceId)
    ? unmuteBrowserActivityService(ids, serviceId)
    : muteBrowserActivityService(ids, serviceId)
}

function reorderPinnedById(pinnedIds, sourceDesktopId, targetDesktopId) {
  if (!Array.isArray(pinnedIds)) return []

  var sourceKey = normalizedId(sourceDesktopId).trim()
  var targetKey = normalizedId(targetDesktopId).trim()
  var sourceIndex = -1
  var targetIndex = -1

  if (!sourceKey || !targetKey || sourceKey === targetKey)
    return pinnedIds.slice()

  for (var i = 0; i < pinnedIds.length; ++i) {
    var itemKey = normalizedId(pinnedIds[i]).trim()
    if (itemKey === sourceKey && sourceIndex < 0) sourceIndex = i
    if (itemKey === targetKey && targetIndex < 0) targetIndex = i
  }

  if (sourceIndex < 0 || targetIndex < 0) return pinnedIds.slice()

  var reordered = pinnedIds.slice()
  var moved = reordered.splice(sourceIndex, 1)[0]
  reordered.splice(Math.min(targetIndex, reordered.length), 0, moved)
  return reordered
}

function controlCommand(settings) {
  var configured = settings && settings.controlCommand
  var command = String(configured === undefined || configured === null
    ? "" : configured).trim()
  return command || "omarchy-menu toggle apps"
}

function applicationActionValues() {
  return [
    "none",
    "minimize-restore",
    "previews",
    "close",
    "focus-or-launch"
  ]
}

function normalizeApplicationActionConfig(settings) {
  var source = settings || ({})
  return {
    clickAction: normalizeSetting("clickAction", source.clickAction),
    middleClickAction: normalizeSetting(
      "middleClickAction", source.middleClickAction),
    scrollAction: normalizeSetting("scrollAction", source.scrollAction)
  }
}

function resolveApplicationPointerAction(config, input, modifiers) {
  var actionConfig = normalizeApplicationActionConfig(config)
  var kind = String(input || "")
  var keys = modifiers || ({})
  var shift = keys.shift === true
  var control = keys.control === true
  var alt = keys.alt === true
  var meta = keys.meta === true

  if (kind === "right") return "context-menu"
  if (alt || meta) return "none"

  if (kind === "left")
    return shift ? "none" : actionConfig.clickAction
  if (kind === "middle")
    return shift ? "none" : actionConfig.middleClickAction
  if (kind === "scroll")
    return shift || control ? "none" : actionConfig.scrollAction
  return "none"
}

function applicationActionCanRun(action, runningCount) {
  var value = String(action === undefined || action === null ? "" : action).trim()
  if (value === "cycle-windows") return Number(runningCount) >= 2
  if (applicationActionValues().indexOf(value) < 0 || value === "none")
    return false
  if (value === "focus-or-launch") return true
  return Number(runningCount) > 0
}

function minimizeRestoreMode(states) {
  var counts = windowStateCounts(states || [])
  if (counts.total === 0) return "none"
  return counts.visible > 0 ? "minimize" : "restore"
}

function settingsDefaults() {
  return {
    iconSize: 42,
    magnification: 1.2,
    magnificationRadius: 95,
    hoverGlowEnabled: true,
    hoverGlowOpacity: 0.72,
    hoverGlowRadius: 28,
    showPreviews: true,
    dragHoverNavigationEnabled: true,
    dragHoverDelayMs: 500,
    showTrash: true,
    backgroundOpacity: 0.88,
    backgroundColorEnabled: false,
    backgroundColor: "",
    borderColorEnabled: false,
    borderColor: "",
    workspaceBadgeBackgroundColorEnabled: false,
    workspaceBadgeBackgroundColor: "",
    workspaceBadgeTextColorEnabled: false,
    workspaceBadgeTextColor: "",
    borderWidthEnabled: false,
    borderWidth: 2,
    presentationMode: "classic",
    presentationModeByMonitor: {},
    sidebarEdge: "left",
    sidebarMonitor: "",
    sidebarExpandedWidth: 320,
    sidebarCollapsed: false,
    sidebarCollapsedByMonitor: {},
    sidebarInlineSoloWorkspace: true,
    sidebarWidgets: [],
    sidebarWidgetCollapsed: {},
    sidebarBrowserTabsEnabled: true,
    position: "bottom",
    fullLength: false,
    reserveSpace: true,
    autoHide: false,
    clickAction: "focus-or-launch",
    middleClickAction: "none",
    scrollAction: "none",
    controlCommand: "omarchy-menu toggle apps",
    sortByWorkspace: false,
    workspaceLayout: "flat",
    workspaceMonitorScope: "all",
    workspaceMonitorOrder: [],
    groupWindows: true,
    interfaceAnimationsEnabled: true,
    browserProfileBadgesEnabled: true,
    dockHerdrIndicators: false,
    dockT3Indicators: false,
    dockClaudeIndicators: false,
    windowIconOverrides: []
  }
}

function shouldReserveSpace(reserveSpace, autoHide) {
  return Boolean(reserveSpace) && !Boolean(autoHide)
}

function classicDockPosition(value) {
  // The classic dock renders on the bottom edge only; the left vertical
  // presentation is the sidebar mode. Legacy left/right/top reads fall back
  // to bottom without rewriting the user's stored value.
  return "bottom"
}

// Gesture edges for the mode-switch drag surface: the bottom dock and the
// left sidebar. Independent from classicDockPosition, which no longer maps
// legacy values onto a vertical classic dock.
function dockGestureEdge(value) {
  return (value === "left" || value === "right") ? "left" : "bottom"
}

function dockPositionDragTarget(position, deltaX, deltaY, threshold) {
  var current = dockGestureEdge(position)
  var x = Number(deltaX)
  var y = Number(deltaY)
  var distance = Number(threshold)
  if (!isFinite(x)) x = 0
  if (!isFinite(y)) y = 0
  if (!isFinite(distance) || distance <= 0) distance = 48

  if (current === "bottom" && x <= -distance) return "left"
  if (current === "left" && y >= distance) return "bottom"
  return current
}

// Mode-switch feedback copy. `edge` is the gesture edge the press started from,
// so every label names the destination it would commit to: the classic dock
// lives on the bottom edge, the sidebar on its configured left/right edge.
function modeDragHint(edge) {
  return dockGestureEdge(edge) === "left"
    ? "Drag down to switch to dock" : "Drag left to switch to sidebar"
}

function modeDragArmedLabel(edge) {
  return dockGestureEdge(edge) === "left"
    ? "Release to switch to dock" : "Release to switch to sidebar"
}

function modeDragDestination(edge) {
  return dockGestureEdge(edge) === "left" ? "classic" : "sidebar"
}

// Edge the destination renders on. Always derived from the configured
// sidebarEdge so the silhouette is never drawn on one edge and rendered on
// another.
function modeDragDestinationEdge(edge, sidebarEdge) {
  if (dockGestureEdge(edge) === "left") return "bottom"
  return sidebarEdge === "right" ? "right" : "left"
}

// Small movement dead zone before the directional hint appears. Wrong-direction
// movement never arms a switch, so this only gates the hint, never the commit.
function modeDragHintVisible(deltaX, deltaY, deadZone) {
  var x = Number(deltaX)
  var y = Number(deltaY)
  if (!isFinite(x)) x = 0
  if (!isFinite(y)) y = 0
  var distance = Number(deadZone)
  if (!isFinite(distance) || distance < 0) distance = 6
  return x * x + y * y >= distance * distance
}

// Destination silhouette bounds in screen-local logical pixels. Shared by both
// presentations so neither duplicates the other renderer's layout math.
// `edgeInset` is the classic dock's bottom margin; side panels sit flush.
function modeDragPreviewRect(edge, screenWidth, screenHeight, bandExtent, edgeInset) {
  var sw = Math.max(0, Number(screenWidth) || 0)
  var sh = Math.max(0, Number(screenHeight) || 0)
  var band = Math.min(Math.max(0, Number(bandExtent) || 0), edge === "bottom" ? sh : sw)
  var inset = Math.max(0, Number(edgeInset) || 0)
  if (edge === "left" || edge === "right")
    return { edge: edge, x: edge === "right" ? Math.max(0, sw - band) : 0,
      y: 0, width: band, height: sh }
  var y = Math.max(0, sh - inset - band)
  return { edge: "bottom", x: 0, y: y, width: sw, height: Math.min(band, sh - y) }
}

// Visible classic bottom-dock band, mirroring Dock.qml's dockBackground sizing.
function classicBandExtent(iconSize, grouped) {
  var size = Number(iconSize)
  if (!isFinite(size) || size <= 0) size = 42
  return Math.round(size) + (grouped === true ? 32 : 44)
}

// The only background the sidebar ListView exposes: the tail below its content
// while that content is shorter than the viewport. Empty as soon as the content
// overflows or the list has scrolled, because then every pixel belongs to a
// delegate. Both the panel binding and the hit-region fixture use this, so the
// gesture surface and its tested geometry can never drift apart.
function sidebarBlankRegion(contentHeight, viewportHeight, contentY, viewportWidth) {
  var h = Number(viewportHeight)
  var ch = Number(contentHeight)
  var cy = Number(contentY)
  var w = Number(viewportWidth)
  if (!(h > 0) || !isFinite(ch) || !isFinite(cy)) return emptySidebarBlankRegion()
  if (ch >= h || cy > 0) return emptySidebarBlankRegion()
  var top = Math.max(0, ch - cy)
  var height = h - top
  if (!(height > 0)) return emptySidebarBlankRegion()
  return { x: 0, y: top, width: isFinite(w) ? Math.max(0, w) : 0, height: height }
}

function emptySidebarBlankRegion() {
  return { x: 0, y: 0, width: 0, height: 0 }
}

// Shared wording for a host persistence failure. Both presentations read the
// same host state, so whichever renderer survives the failed write reports it
// identically instead of inventing its own copy.
function persistenceFeedback(settingsWriteError) {
  return "Unsaved preferences: " + String(settingsWriteError || "Persistence failed")
}

// Structural equality for a stored setting comparison. The writer's stale check
// used `!==`, which reports every object setting (override/collapse/monitor
// maps) as changed; arrays compare in order, plain objects compare as key sets
// so two logically identical maps never manufacture a conflict.
function sameSettingValue(left, right) {
  if (left === right) return true
  if (!left || !right || typeof left !== "object" || typeof right !== "object") return false
  if (Array.isArray(left) !== Array.isArray(right)) return false
  if (Array.isArray(left)) {
    if (left.length !== right.length) return false
    for (var i = 0; i < left.length; ++i)
      if (!sameSettingValue(left[i], right[i])) return false
    return true
  }
  var leftKeys = Object.keys(left).sort()
  var rightKeys = Object.keys(right).sort()
  if (leftKeys.length !== rightKeys.length) return false
  for (var k = 0; k < leftKeys.length; ++k) {
    if (leftKeys[k] !== rightKeys[k]) return false
    if (!sameSettingValue(left[leftKeys[k]], right[rightKeys[k]])) return false
  }
  return true
}

// Feedback text for a completed background gesture's writer result. An accepted
// write returns "" so the renderer clears any earlier message; a rejected
// preflight intent (stale, busy, invalid config) surfaces its own reason
// instead of being silently discarded. Shared so both presentations word a
// failed mode switch identically.
function modeDragWriteError(result) {
  if (result && result.accepted) return ""
  var error = result && result.reply && result.reply.error ? result.reply.error : null
  return "Preferences were not saved: "
    + String(error && (error.message || error.code) || "request rejected")
}

// Per-connector sidebar collapse lookup, shared by the live controller and the
// classic dock's preview so both resolve the same destination width.
function sidebarCollapsedForScreen(collapsedByMonitor, collapsedDefault, screenName) {
  var name = screenName ? String(screenName) : ""
  var map = collapsedByMonitor
  if (name && map && Object.prototype.hasOwnProperty.call(map, name))
    return map[name] === true
  return collapsedDefault === true
}

function applicationStateIndicatorGeometry(position, iconWidth, iconHeight,
                                           running, focused, edgeGap) {
  var edge = ["top", "bottom", "left", "right"].indexOf(position) >= 0
    ? position : "bottom"
  var width = Math.max(0, Number(iconWidth) || 0)
  var height = Math.max(0, Number(iconHeight) || 0)
  var minimumDimension = Math.max(1, Math.min(width || 1, height || 1))
  var thickness = Math.max(3,
    Math.min(5, Math.round(minimumDimension * 0.1)))
  var focusedLength = Math.max(10,
    Math.min(72, Math.round(minimumDimension * 0.72)))
  var markerLength = focused ? focusedLength : thickness
  var vertical = edge === "left" || edge === "right"
  var markerWidth = vertical ? thickness : markerLength
  var markerHeight = vertical ? markerLength : thickness
  var gap = Number(edgeGap)
  if (!isFinite(gap) || gap < 0) gap = 7
  var x = Math.round((width - markerWidth) / 2)
  var y = Math.round((height - markerHeight) / 2)

  if (edge === "top")
    y = -(markerHeight + gap)
  else if (edge === "bottom")
    y = height + gap
  else if (edge === "left")
    x = width + gap
  else if (edge === "right")
    x = -(markerWidth + gap)

  return {
    visible: Boolean(running),
    x: x,
    y: y,
    width: markerWidth,
    height: markerHeight,
    radius: thickness / 2
  }
}

function dockControlIcon(action, autoHide) {
  switch (action) {
  case "launcher":
    return "rocket"
  case "add":
    return "plus"
  case "auto-hide":
    return autoHide ? "eye" : "eye-off"
  default:
    return ""
  }
}

function steppedNumber(value, minimum, maximum, step, fallback, precision) {
  var number = Number(value)
  if (!isFinite(number)) number = fallback
  number = Math.max(minimum, Math.min(maximum, number))
  number = minimum + Math.round((number - minimum) / step) * step
  return Number(number.toFixed(precision || 0))
}

function normalizedHexColor(value) {
  var color = String(value === undefined || value === null ? "" : value)
    .trim().toLowerCase()
  return /^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/.test(color) ? color : ""
}

// Color settings may be either a literal hex value or a symbolic
// Omarchy theme token such as "@accent" / "@menu.background". Keeping the
// token in the existing setting means it follows theme changes automatically.
function normalizedColorValue(value) {
  var hex = normalizedHexColor(value)
  if (hex !== "") return hex

  var token = String(value === undefined || value === null ? "" : value)
    .trim().toLowerCase()
  return /^@[a-z][a-z0-9_.-]*$/.test(token) ? token : ""
}

function resolveColorValue(value, tokens, fallback) {
  var normalized = normalizedColorValue(value)
  if (normalized === "") return fallback
  if (normalized.charAt(0) !== "@") return normalized

  var token = normalized.slice(1)
  var resolved = tokens && tokens[token]
  return resolved === undefined || resolved === null ? fallback : resolved
}

function effectiveColor(enabled, override, themeColor, tokens) {
  return Boolean(enabled)
    ? resolveColorValue(override, tokens, themeColor)
    : themeColor
}

function effectiveBorderWidth(enabled, override, themeWidth) {
  if (!Boolean(enabled)) return themeWidth
  return steppedNumber(override, 0, 8, 1, 2, 0)
}

// Exact connector → boolean. Invalid keys/values dropped; disconnected names kept.
function normalizeSidebarCollapsedByMonitor(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return ({})
  var result = ({})
  Object.keys(value).forEach(function(key) {
    if (typeof key !== "string" || !key || /[\x00-\x1f\x7f-\x9f]/.test(key)) return
    if (typeof value[key] !== "boolean") return
    result[key] = value[key]
  })
  return result
}

// Exact connector → presentation mode. Invalid keys/values dropped;
// disconnected names kept, mirroring normalizeSidebarCollapsedByMonitor.
function normalizePresentationModeByMonitor(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return ({})
  var result = ({})
  Object.keys(value).forEach(function(key) {
    if (typeof key !== "string" || !key || /[\x00-\x1f\x7f-\x9f]/.test(key)) return
    if (value[key] !== "classic" && value[key] !== "sidebar") return
    result[key] = value[key]
  })
  return result
}

function normalizeSetting(key, value) {
  var defaults = settingsDefaults()
  switch (key) {
  case "presentationMode":
    return value === "sidebar" ? "sidebar" : "classic"
  case "presentationModeByMonitor":
    return normalizePresentationModeByMonitor(value)
  case "sidebarEdge":
    return value === "right" ? "right" : "left"
  case "sidebarMonitor":
    return typeof value === "string" && !/[\x00-\x1f\x7f-\x9f]/.test(value) ? value : ""
  case "sidebarExpandedWidth":
    return steppedNumber(value, 240, 480, 1, defaults.sidebarExpandedWidth, 0)
  case "sidebarWidgets":
    return SidebarWidgetModel.requestedIds(value)
  case "sidebarWidgetCollapsed":
    return SidebarWidgetModel.collapsedMap(value)
  case "sidebarCollapsed":
    return typeof value === "boolean" ? value : false
  case "sidebarCollapsedByMonitor":
    return normalizeSidebarCollapsedByMonitor(value)
  case "sidebarInlineSoloWorkspace":
    return typeof value === "boolean" ? value : defaults.sidebarInlineSoloWorkspace
  case "iconSize":
    return steppedNumber(value, 24, 96, 1, defaults.iconSize, 0)
  case "magnification":
    return steppedNumber(value, 1, 2, 0.05, defaults.magnification, 2)
  case "magnificationRadius":
    return steppedNumber(value, 40, 240, 5, defaults.magnificationRadius, 0)
  case "hoverGlowOpacity":
    return steppedNumber(value, 0, 1, 0.05, defaults.hoverGlowOpacity, 2)
  case "hoverGlowRadius":
    return steppedNumber(value, 0, 100, 5, defaults.hoverGlowRadius, 0)
  case "backgroundOpacity":
    return steppedNumber(value, 0, 1, 0.05, defaults.backgroundOpacity, 2)
  case "dragHoverDelayMs":
    return steppedNumber(value, 100, 2000, 100, defaults.dragHoverDelayMs, 0)
  case "hoverGlowEnabled":
  case "showPreviews":
  case "dragHoverNavigationEnabled":
  case "showTrash":
  case "backgroundColorEnabled":
  case "borderColorEnabled":
  case "workspaceBadgeBackgroundColorEnabled":
  case "workspaceBadgeTextColorEnabled":
  case "borderWidthEnabled":
  case "interfaceAnimationsEnabled":
  case "browserProfileBadgesEnabled":
  case "dockHerdrIndicators":
  case "dockT3Indicators":
  case "dockClaudeIndicators":
  case "sidebarBrowserTabsEnabled":
    return typeof value === "boolean" ? value : defaults[key]
  case "backgroundColor":
  case "borderColor":
  case "workspaceBadgeBackgroundColor":
  case "workspaceBadgeTextColor":
    return normalizedColorValue(value)
  case "borderWidth":
    return steppedNumber(value, 0, 8, 1, defaults.borderWidth, 0)
  case "workspaceMonitorScope":
    return value === "current-monitor" ? "current-monitor" : "all"
  case "workspaceMonitorOrder":
    return normalizeMonitorConnectors(value)
  case "workspaceLayout":
    return value === "grouped" ? "grouped" : "flat"
  case "position":
    return classicDockPosition(value)
  case "fullLength":
  case "reserveSpace":
  case "autoHide":
  case "sortByWorkspace":
  case "groupWindows":
    return typeof value === "boolean" ? value : defaults[key]
  case "scrollAction": {
    var scrollAction = String(
      value === undefined || value === null ? "" : value).trim()
    return scrollAction === "cycle-windows" ? scrollAction : defaults.scrollAction
  }
  case "clickAction":
  case "middleClickAction": {
    var action = String(value === undefined || value === null ? "" : value).trim()
    // Older settings exposed Focus and Launch separately. Treat both legacy
    // values as the single combined action so existing files keep working.
    if (action === "focus" || action === "launch")
      return "focus-or-launch"
    return applicationActionValues().indexOf(action) >= 0 ? action : defaults[key]
  }
  case "controlCommand":
    return controlCommand({ controlCommand: value })
  case "hiddenApplications":
    return normalizeApplicationIds(value)
  case "browserActivityMutedServices":
    return normalizeBrowserActivityMutedServices(value)
  default:
    return value
  }
}

function mergeSettings(settings, patch) {
  return Object.assign({}, settings || {}, patch || {})
}

function workspaceGridPosition(position, parentWidth, parentHeight,
                               iconSize, gridWidth, gridHeight) {
  var width = Math.max(0, Number(parentWidth) || 0)
  var height = Math.max(0, Number(parentHeight) || 0)
  var gridW = Math.max(0, Number(gridWidth) || 0)
  var gridH = Math.max(0, Number(gridHeight) || 0)

  return {
    x: Math.round(width / 2 - gridW / 2),
    y: Math.round(height / 2 - gridH / 2)
  }
}

function ipcWorkspaceFromHandle(handle) {
  var ipc = handle && handle.lastIpcObject ? handle.lastIpcObject : null
  return ipc && ipc.workspace ? ipc.workspace : null
}

function workspaceIpcWindowCount(workspace) {
  if (!workspace) return -1
  var ipc = workspace.lastIpcObject || ({})
  var count = Number(ipc.windows)
  if (Number.isInteger(count) && count >= 0) return count
  return -1
}

function isCountableWorkspaceHandle(handle) {
  var workspace = ipcWorkspaceFromHandle(handle)
  if (!workspace) return false
  var workspaceId = Number(workspace.id)
  var workspaceName = String(workspace.name || "")
  if (workspaceName.indexOf("special:") === 0) return false
  if (Number.isInteger(workspaceId) && workspaceId < 0) return false
  return Number.isInteger(workspaceId) && workspaceId > 0
}

function parseWorkspaceWindowCounts(output) {
  var counts = {}
  try {
    var values = JSON.parse(String(output || "[]"))
    for (var i = 0; i < values.length; ++i) {
      var workspace = values[i]
      var id = Number(workspace ? workspace.id : NaN)
      if (!Number.isInteger(id) || id < 1) continue
      counts[String(id)] = Math.max(0, Number(workspace.windows) || 0)
    }
  } catch (error) {
    return null
  }
  return counts
}

function workspaceWindowCount(workspaceId, handles, workspaces, counts, countsReady) {
  var target = Number(workspaceId)
  if (!Number.isInteger(target) || target < 1) return 0

  if (countsReady && counts) {
    var mapped = counts[String(target)]
    if (mapped !== undefined) {
      var fromMap = Number(mapped)
      if (Number.isInteger(fromMap) && fromMap >= 0) return fromMap
    }
    return 0
  }

  var workspaceValues = workspaces || []
  for (var w = 0; w < workspaceValues.length; ++w) {
    var workspace = workspaceValues[w]
    if (Number(workspace ? workspace.id : -1) !== target) continue
    var fromWorkspace = workspaceIpcWindowCount(workspace)
    if (fromWorkspace >= 0) return fromWorkspace
    break
  }

  var count = 0
  var values = handles || []
  for (var i = 0; i < values.length; ++i) {
    var handle = values[i]
    if (!handle || !isCountableWorkspaceHandle(handle)) continue
    if (Number(ipcWorkspaceFromHandle(handle).id) === target) count++
  }
  return count
}

function workspaceOccupied(workspace, handles, counts, countsReady) {
  var id = Number(workspace ? workspace.id : -1)
  if (countsReady && Number.isInteger(id) && id > 0) {
    if (counts && counts[String(id)] !== undefined)
      return Number(counts[String(id)]) > 0
    return false
  }

  var fromWorkspace = workspaceIpcWindowCount(workspace)
  if (fromWorkspace >= 0) return fromWorkspace > 0

  if (handles && Number.isInteger(id) && id > 0)
    return workspaceWindowCount(id, handles) > 0

  if (!workspace || !workspace.toplevels) return false
  var toplevels = Array.isArray(workspace.toplevels)
    ? workspace.toplevels : workspace.toplevels.values
  return Boolean(toplevels && toplevels.length > 0)
}

function focusedWorkspaceIdFromMonitors(monitors, focusedWorkspace) {
  var values = monitors || []
  var hasMonitorIpc = false

  for (var i = 0; i < values.length; ++i) {
    var monitor = values[i]
    var ipc = monitor.lastIpcObject || ({})
    var activeWorkspace = monitor.activeWorkspace !== undefined
      ? monitor.activeWorkspace : ipc.activeWorkspace
    if (!activeWorkspace) continue
    hasMonitorIpc = true
    var focused = monitor.focused !== undefined ? monitor.focused === true
      : ipc.focused === true
    if (focused) {
      var id = Number(activeWorkspace.id)
      if (Number.isInteger(id) && id > 0) return id
    }
  }

  if (hasMonitorIpc) return -1

  var fallback = focusedWorkspace ? Number(focusedWorkspace.id) : -1
  return Number.isInteger(fallback) && fallback > 0 ? fallback : -1
}

function visibleWorkspaceIds(workspaces, focusedWorkspaceId, handles, counts, countsReady) {
  var ids = [1, 2]
  var values = workspaces || []
  var focused = Number(focusedWorkspaceId)

  for (var i = 0; i < values.length; ++i) {
    var workspace = values[i]
    var id = Number(workspace ? workspace.id : -1)
    if (!Number.isInteger(id) || id < 1 || id > 10) continue
    if (id === 1 || id === 2 || id === focused
        || workspaceOccupied(workspace, handles, counts, countsReady)) {
      if (ids.indexOf(id) < 0) ids.push(id)
    }
  }

  if (Number.isInteger(focused) && focused >= 1 && focused <= 10
      && ids.indexOf(focused) < 0)
    ids.push(focused)

  ids.sort(function(left, right) { return left - right })
  return ids
}

function focusWorkspaceTargetRequest(workspace, usingLua) {
  var target = normalizeWorkspaceTarget(workspace)
  if (!target) return ""
  if (usingLua) return 'hl.dsp.focus({ workspace = "' + target + '" })'
  return "workspace " + target
}

function normalizeMonitorTarget(value) {
  var target = String(value || "").trim()
  if (/^name:[^,;"\\\r\n\t]+$/.test(target)) return target
  if (/^id:[0-9]+$/.test(target)) return target
  return ""
}

function moveCurrentWorkspaceToMonitorRequest(monitor, usingLua) {
  var target = normalizeMonitorTarget(monitor)
  if (!target) return ""
  var selector = target.indexOf("id:") === 0 ? target.slice(3)
    : target.indexOf("name:") === 0 ? target.slice(5) : ""
  if (!selector) return ""
  if (usingLua) return 'hl.dsp.workspace.move({ monitor = "' + selector + '" })'
  return "movecurrentworkspacetomonitor " + selector
}

function moveWorkspaceToMonitorRequest(workspace, monitor, usingLua) {
  var workspaceTarget = normalizeWorkspaceTarget(workspace)
  var monitorTarget = normalizeMonitorTarget(monitor)
  if (!workspaceTarget || !monitorTarget) return ""
  var selector = monitorTarget.indexOf("id:") === 0 ? monitorTarget.slice(3)
    : monitorTarget.indexOf("name:") === 0 ? monitorTarget.slice(5) : ""
  if (!selector) return ""
  if (usingLua)
    return 'hl.dsp.workspace.move({ workspace = "' + workspaceTarget
      + '", monitor = "' + selector + '" })'
  if (/\s/.test(workspaceTarget)) return ""
  return "moveworkspacetomonitor " + workspaceTarget + " " + selector
}

function focusWorkspaceRequest(workspace, usingLua) {
  var id = Number(workspace)
  if (!Number.isInteger(id) || id < 1 || id > 10) return ""
  if (usingLua)
    return 'hl.dsp.focus({ workspace = "' + id + '" })'
  return "workspace " + id
}

function focusWindowRequest(address, usingLua) {
  var target = normalizeWindowAddress(address)
  if (!target) return ""
  if (usingLua)
    return 'hl.dsp.focus({ window = "address:' + target + '" })'
  return "focuswindow address:" + target
}

function trashItemCount(output) {
  var listing = String(output || "").trim()
  if (!listing) return 0
  var lines = listing.split(/\r?\n/)
  var count = 0
  for (var i = 0; i < lines.length; ++i) {
    if (lines[i].trim()) count++
  }
  return count
}

function trashTooltip(itemCount) {
  var count = Math.max(0, Math.floor(Number(itemCount) || 0))
  if (count === 0) return "Trash — empty"
  return "Trash — " + count + (count === 1 ? " item" : " items")
}

function surfaceOpacity(themeAlpha, configuredOpacity) {
  var theme = Number(themeAlpha)
  var configured = Number(configuredOpacity)
  if (!isFinite(theme)) theme = 1
  if (!isFinite(configured)) configured = 1
  theme = Math.max(0, Math.min(1, theme))
  configured = Math.max(0, Math.min(1, configured))
  return theme * configured
}

function normalizeWindowAddress(value) {
  var address = String(value || "").trim().toLowerCase()
  if (address.slice(0, 2) === "0x") address = address.slice(2)
  return /^[0-9a-f]+$/.test(address) ? "0x" + address : ""
}

function moveWindowRequest(address, workspace, usingLua) {
  var target = normalizeWindowAddress(address)
  var raw = String(workspace === undefined || workspace === null ? "" : workspace)
  var workspaceTarget = normalizeWorkspaceTarget(raw)
  // Reject unsafe input rather than silently changing a named workspace.
  if (!target || !workspaceTarget || raw !== workspaceTarget
      || /[\x00-\x1f\x7f]/.test(raw)) return ""

  if (usingLua)
    return 'hl.dsp.window.move({ window = "address:' + target
      + '", workspace = "' + workspaceTarget + '", follow = false })'
  return "movetoworkspacesilent " + workspaceTarget + ",address:" + target
}

function minimizeWindowRequest(address, usingLua) {
  var target = normalizeWindowAddress(address)
  if (!target) return ""

  var workspace = "special:smartdock-minimized"
  if (usingLua)
    return 'hl.dsp.window.move({ window = "address:' + target
      + '", workspace = "' + workspace + '", follow = false })'
  return "movetoworkspacesilent " + workspace + ",address:" + target
}

function normalizeWorkspaceTarget(value) {
  var workspace = String(value || "").trim()
  if (/^[1-9][0-9]*$/.test(workspace)) return workspace
  if (/^name:[^,;"\\\r\n\t]+$/.test(workspace)) return workspace
  return ""
}

function restoreWindowRequest(address, workspace, usingLua) {
  var target = normalizeWindowAddress(address)
  var workspaceTarget = normalizeWorkspaceTarget(workspace)
  if (!target || !workspaceTarget) return ""

  if (usingLua)
    return 'hl.dsp.window.move({ window = "address:' + target
      + '", workspace = "' + workspaceTarget + '", follow = true })'
  return "movetoworkspace " + workspaceTarget + ",address:" + target
}

function fakeFullscreenRequest(address, enabled, usingLua) {
  var target = normalizeWindowAddress(address)
  if (!target || !usingLua) return ""

  var state = enabled ? 1 : 0
  return 'hl.dsp.window.fullscreen_state({ internal = ' + state
    + ', client = 0, action = "set", window = "address:' + target + '" })'
}

function windowStateCounts(states) {
  var total = states ? states.length : 0
  var minimized = 0
  for (var i = 0; i < total; ++i) {
    if (states[i] && states[i].minimized === true) minimized++
  }
  return {
    total: total,
    minimized: minimized,
    visible: total - minimized
  }
}

function isFakeFullscreen(info) {
  return Boolean(info)
    && Number(info.fullscreen || 0) === 1
    && Number(info.fullscreenClient || 0) === 0
}

function isFullscreenWithBars(info) {
  return Boolean(info) && Number(info.fullscreen || 0) === 1
}

function fullscreenOwner(toplevels, handles, focusedWorkspaceId, activeToplevel) {
  var workspaceId = Number(focusedWorkspaceId)
  if (!Number.isInteger(workspaceId)) return null

  var windows = toplevels || []
  var hyprHandles = handles || []
  var owner = null
  var activeOnFocusedWorkspace = false
  for (var i = 0; i < hyprHandles.length; ++i) {
    var handle = hyprHandles[i]
    if (!handle || !handle.wayland || windows.indexOf(handle.wayland) < 0)
      continue

    // Quickshell's object-level workspace relationship can be stale; prefer
    // the authoritative IPC record carried by lastIpcObject.
    var ipc = handle.lastIpcObject || ({})
    var handleWorkspace = ipc.workspace || handle.workspace || ({})
    var handleWorkspaceId = Number(handleWorkspace.id)
    if (handleWorkspaceId !== workspaceId) continue
    if (handle.wayland === activeToplevel)
      activeOnFocusedWorkspace = true
    if (!owner && isFullscreenWithBars(ipc))
      owner = handle.wayland
  }
  return owner && activeOnFocusedWorkspace ? activeToplevel : owner
}

function workspaceFullscreenOwners(groups, handles, activeToplevel, minimizedToplevels) {
  var owners = {}
  var cards = groups || []
  var hyprHandles = handles || []
  var minimized = minimizedToplevels || []

  for (var g = 0; g < cards.length; ++g) {
    var group = cards[g]
    if (!group || !group.identity) continue

    var members = []
    var items = group.items || []
    for (var i = 0; i < items.length; ++i) {
      var itemToplevels = items[i] && items[i].toplevels || []
      for (var t = 0; t < itemToplevels.length; ++t) {
        var member = itemToplevels[t]
        if (member && members.indexOf(member) < 0)
          members.push(member)
      }
    }

    var owner = null
    var activeEligible = false
    for (var h = 0; h < hyprHandles.length; ++h) {
      var handle = hyprHandles[h]
      if (!handle || !handle.wayland
          || members.indexOf(handle.wayland) < 0
          || minimized.indexOf(handle.wayland) >= 0)
        continue

      if (handle.wayland === activeToplevel)
        activeEligible = true
      if (!owner && isFullscreenWithBars(handle.lastIpcObject || ({})))
        owner = handle.wayland
    }

    if (owner)
      owners[group.identity] = activeEligible ? activeToplevel : owner
  }
  return owners
}

function fullscreenIconPresentation(modeActive, isOwner, hovered) {
  if (isOwner)
    return { scale: 1.15, opacity: 1.0 }
  if (!modeActive || hovered)
    return { scale: 1.0, opacity: 1.0 }
  return { scale: 0.9, opacity: 0.45 }
}

function shouldRefreshWorkspaceState(eventName) {
  return [
    "openwindow",
    "closewindow",
    "movewindow",
    "movewindowv2",
    "workspace",
    "workspacev2",
    "createworkspace",
    "createworkspacev2",
    "destroyworkspace",
    "destroyworkspacev2",
    "focusedmon",
    "activewindow",
    "activewindowv2"
  ].indexOf(String(eventName || "")) >= 0
}

function workspaceBadgeText(toplevels, handles) {
  var windows = toplevels || []
  var hyprHandles = handles || []
  var labels = []

  for (var i = 0; i < windows.length; ++i) {
    var window = windows[i]
    var label = ""
    for (var j = 0; j < hyprHandles.length; ++j) {
      var handle = hyprHandles[j]
      if (!handle || handle.wayland !== window) continue

      // Quickshell's object-level workspace relationship can be stale; prefer
      // the authoritative IPC record carried by lastIpcObject.
      var ipc = handle.lastIpcObject || ({})
      var workspace = ipc.workspace || handle.workspace || ({})
      var workspaceId = Number(workspace.id)
      var workspaceName = String(workspace.name || "")
      if (workspaceName.indexOf("special:") === 0
          || (Number.isInteger(workspaceId) && workspaceId < 0))
        continue
      else if (Number.isInteger(workspaceId) && workspaceId > 0)
        label = String(workspaceId)
      break
    }

    if (label && labels.indexOf(label) < 0)
      labels.push(label)
  }

  labels.sort(function(left, right) {
    return Number(left) - Number(right)
  })

  if (labels.length > 3)
    return labels.slice(0, 2).join("·") + "+"
  return labels.join("·")
}

function windowStatusLabel(state) {
  if (!state) return ""
  if (state.minimized === true) return "[minimized]"

  var workspace = String(state.workspace || "").trim()
  if (!workspace) return ""
  if (workspace.indexOf("name:") === 0)
    workspace = workspace.slice(5)
  return "[" + workspace + "]"
}

function nextToplevelIndex(currentIndex, count) {
  if (count <= 0) return -1
  if (currentIndex < 0 || currentIndex >= count - 1) return 0
  return currentIndex + 1
}

function entryForDesktopId(desktopId, entries) {
  var wanted = normalizedId(desktopId)
  for (var i = 0; i < entries.length; ++i) {
    if (normalizedId(entries[i].id) === wanted)
      return entries[i]
  }
  return null
}

function entryForAppId(appId, entries) {
  var wanted = normalizedId(appId)
  for (var i = 0; i < entries.length; ++i) {
    var entry = entries[i]
    if (normalizedId(entry.id) === wanted
        || normalizedId(entry.startupClass) === wanted)
      return entry
  }
  return null
}

function webAppId(entry) {
  if (!entry || !entry.command) return ""

  for (var i = 0; i < entry.command.length; ++i) {
    var match = String(entry.command[i]).match(/https?:\/\/[^?#\s]+/i)
    if (!match) continue

    var url = match[0].replace(/^https?:\/\//i, "").replace(/\/$/, "")
    try {
      url = decodeURIComponent(url)
    } catch (error) {
      // The encoded URL can still match a generated browser app ID.
    }
    return url.toLowerCase().replace(/[^a-z0-9]/g, "")
  }
  return ""
}

function entryMatchesAppId(desktopId, entry, appId) {
  var wanted = normalizedId(appId)
  if (!wanted) return false

  if (normalizedId(desktopId) === wanted
    || (entry && normalizedId(entry.id) === wanted)
    || (entry && normalizedId(entry.startupClass) === wanted))
    return true

  var generatedId = webAppId(entry)
  return generatedId.length >= 6
    && wanted.replace(/[^a-z0-9]/g, "").indexOf(generatedId) >= 0
}

function itemWorkspaceId(item, handles) {
  if (!item || !item.toplevels || item.toplevels.length === 0)
    return Infinity

  var values = Array.isArray(item.toplevels)
    ? item.toplevels : item.toplevels.values
  var ids = []

  for (var i = 0; i < values.length; ++i) {
    var window = values[i]
    if (!window) continue
    for (var j = 0; j < handles.length; ++j) {
      var handle = handles[j]
      if (!handle || handle.wayland !== window) continue

      // Quickshell's object-level workspace relationship can be stale; prefer
      // the authoritative IPC record carried by lastIpcObject.
      var ipc = handle.lastIpcObject || ({})
      var workspace = ipc.workspace || handle.workspace || ({})
      var id = Number(workspace.id)
      if (Number.isInteger(id) && id > 0 && ids.indexOf(id) < 0)
        ids.push(id)
      break
    }
  }

  if (ids.length === 0) return Infinity
  ids.sort(function(a, b) { return a - b })
  return ids[0]
}

function visibleItemsEqual(current, next) {
  if (!Array.isArray(current) || !Array.isArray(next)
      || current.length !== next.length)
    return false

  for (var i = 0; i < current.length; ++i) {
    var currentItem = current[i]
    var nextItem = next[i]
    if (!currentItem || !nextItem
        || currentItem.desktopId !== nextItem.desktopId
        || currentItem.pinned !== nextItem.pinned
        || currentItem.presentationId !== nextItem.presentationId
        || currentItem.identityToplevel !== nextItem.identityToplevel
        || String(currentItem.windowRuleKey || "") !== String(nextItem.windowRuleKey || "")
        || String(currentItem.windowOverrideSource || "") !== String(nextItem.windowOverrideSource || "")
        || !Array.isArray(currentItem.toplevels)
        || !Array.isArray(nextItem.toplevels)
        || currentItem.toplevels.length !== nextItem.toplevels.length)
      return false

    for (var j = 0; j < currentItem.toplevels.length; ++j) {
      if (currentItem.toplevels[j] !== nextItem.toplevels[j]) return false
    }
  }

  return true
}

function buildVisibleItems(pinnedIds, toplevels, entries, handles, sortByWorkspace,
                           groupWindows, hiddenApplicationIds, windowRuleMatches) {
  var items = []
  var runningByKey = {}
  var nextOriginalIndex = 0
  var mergeWindows = groupWindows !== false
  var catalog = entries || []

  for (var i = 0; i < pinnedIds.length; ++i) {
    var pinnedId = pinnedIds[i]
    items.push({
      desktopId: pinnedId,
      pinned: true,
      toplevels: [],
      windowRuleKey: "",
      windowOverrideSource: "",
      originalIndex: nextOriginalIndex++
    })
  }

  for (var topIndex = 0; topIndex < toplevels.length; ++topIndex) {
    var toplevel = toplevels[topIndex]
    var matchedPinned = false
    // The host-facing surface matched raw Wayland appId/title before this
    // desktop/pin resolution step and supplies the aligned result here.
    var windowRule = Array.isArray(windowRuleMatches)
      ? (windowRuleMatches[topIndex] || null) : null
    var windowRuleKey = windowRule ? windowRule.key : ""
    var windowOverrideSource = windowRule ? windowRule.source : ""
    // Terminal windows running a recognized CLI app (e.g. opencode)
    // group under that app instead of the terminal emulator.
    var effectiveAppId = toplevelAppId(toplevel, catalog)

    if (mergeWindows && !windowRule) {
      for (var pinnedIndex = 0; pinnedIndex < items.length; ++pinnedIndex) {
        var item = items[pinnedIndex]
        var pinnedEntry = entryForDesktopId(item.desktopId, catalog)
        if (!entryMatchesAppId(item.desktopId, pinnedEntry, effectiveAppId))
          continue

        item.toplevels.push(toplevel)
        matchedPinned = true
        break
      }

      if (matchedPinned) continue
    }

    var runningEntry = entryForAppId(effectiveAppId, catalog)
    var desktopId = runningEntry && runningEntry.id
      ? runningEntry.id
      : String(effectiveAppId || "unknown-application")

    if (!mergeWindows) {
      var attachedPinned = false
      for (var pinIndex = 0; !windowRule && pinIndex < items.length; ++pinIndex) {
        var pinnedItem = items[pinIndex]
        if (pinnedItem.toplevels.length > 0) continue
        var pinnedEntry = entryForDesktopId(pinnedItem.desktopId, catalog)
        if (!entryMatchesAppId(pinnedItem.desktopId, pinnedEntry, effectiveAppId))
          continue
        pinnedItem.toplevels.push(toplevel)
        attachedPinned = true
        break
      }
      if (attachedPinned) continue

      items.push({
        desktopId: desktopId,
        pinned: false,
        toplevels: [toplevel],
        windowRuleKey: windowRuleKey,
        windowOverrideSource: windowOverrideSource,
        originalIndex: nextOriginalIndex++
      })
      continue
    }

    var key = normalizedId(desktopId) + "\u001f"
      + (windowRuleKey || "@unmatched")
    var runningItem = runningByKey[key]
    if (!runningItem) {
      runningItem = {
        desktopId: desktopId,
        pinned: false,
        toplevels: [],
        windowRuleKey: windowRuleKey,
        windowOverrideSource: windowOverrideSource,
        originalIndex: nextOriginalIndex++
      }
      runningByKey[key] = runningItem
      items.push(runningItem)
    }
    runningItem.toplevels.push(toplevel)
  }

  if (sortByWorkspace) {
    items.sort(function(a, b) {
      // Closed pinned apps stay at the front in their configured order.
      var aClosedPinned = a.pinned && a.toplevels.length === 0
      var bClosedPinned = b.pinned && b.toplevels.length === 0
      if (aClosedPinned && !bClosedPinned) return -1
      if (!aClosedPinned && bClosedPinned) return 1

      // Everything else is ordered by the lowest workspace id it occupies.
      var aWorkspace = itemWorkspaceId(a, handles)
      var bWorkspace = itemWorkspaceId(b, handles)
      if (aWorkspace !== bWorkspace) return aWorkspace - bWorkspace

      // Pinned items precede unpinned items on the same workspace.
      if (a.pinned && !b.pinned) return -1
      if (!a.pinned && b.pinned) return 1

      // Preserve the original construction order for a stable layout.
      return a.originalIndex - b.originalIndex
    })
  }

  var hiddenIds = normalizeApplicationIds(hiddenApplicationIds)
  var visibleItems = []
  for (var itemIndex = 0; itemIndex < items.length; ++itemIndex) {
    var visibleItem = items[itemIndex]
    var itemKey = normalizedId(visibleItem.desktopId)
    var hidden = false
    for (var hiddenIndex = 0; hiddenIndex < hiddenIds.length; ++hiddenIndex) {
      if (normalizedId(hiddenIds[hiddenIndex]) === itemKey) {
        hidden = true
        break
      }
    }
    if (hidden) continue
    // Attach once for sidebar/classic consumers of item.entry. Classic DockItem
    // still resolves DesktopEntries.byId reactively; this is the shared catalog
    // object when the caller already supplied applications. entryForAppId covers
    // both desktop id and startupClass in one pass.
    visibleItem.entry = entryForAppId(visibleItem.desktopId, catalog)
    visibleItems.push(visibleItem)
  }

  return visibleItems
}

// Shared pure inventory for Settings UI and runtime projection.
var classicOnlySettings = [
  "position",
  "workspaceLayout",
  "workspaceGroups",
  "windowScope",
  "workspaceMonitorScope",
  "reserveSpace",
  "autoHide",
  "showPreviews",
  "clickAction",
  "middleClickAction",
  "scrollAction",
  "magnification",
  "iconSize",
  "sortByWorkspace",
  "fullLength",
  "margin",
  "backgroundOpacity",
  "backgroundColorEnabled",
  "backgroundColor",
  "borderColorEnabled",
  "borderColor",
  "borderWidthEnabled",
  "borderWidth",
  "workspaceBadgeBackgroundColorEnabled",
  "workspaceBadgeBackgroundColor",
  "workspaceBadgeTextColorEnabled",
  "workspaceBadgeTextColor",
  "hoverGlowEnabled",
  "hoverGlowOpacity",
  "hoverGlowRadius",
  "magnificationRadius",
  "urgentWindowAnimationEnabled",
  "showUrgentOutsideScope",
  "dockHerdrIndicators",
  "dockT3Indicators"
]

function inactiveClassicSettings(hasSidebar) {
  return hasSidebar ? classicOnlySettings.slice() : []
}
