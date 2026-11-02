pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "DockModel.js" as DockModel
import "DockSidebarModel.js" as SidebarModel
import "DockSidebarWidgetModel.js" as SidebarWidgetModel
import "DockWindowModel.js" as DockWindowModel
import "DockTrashModel.js" as TrashModel
import "DockConfigModel.js" as ConfigModel
import "DockIconModel.js" as DockIconModel
import "DockWorkspaceGroupModel.js" as WorkspaceGroupModel
import "DockScreenPresentationModel.js" as ScreenPresentationModel

// Exactly one host-owned target, never one target per screen/Variants delegate.
Item {
  id: root
  required property var host
  readonly property var defaults: JSON.parse(defaultsFile.text())
  readonly property var metadata: JSON.parse(schemaFile.text())

  FileView {
    id: defaultsFile
    path: Qt.resolvedUrl("../config/dock.json")
    blockLoading: true
  }
  FileView {
    id: schemaFile
    path: Qt.resolvedUrl("../config/settings-schema.json")
    blockLoading: true
  }

  function success(data, warnings) {
    return { apiVersion: 1, ok: true, data: data, warnings: warnings || [] }
  }

  function failure(code, message, data) {
    return { apiVersion: 1, ok: false, error: { code: code, message: message },
      data: data || {}, warnings: [] }
  }

  function statusData() {
    return {
      runtime: { mode: root.host.runtimeMode, instanceId: String(Quickshell.processId) },
      configPath: root.host.configPath,
      loadState: root.host.settingsLoadState,
      loadError: root.host.settingsLoadError,
      loadPending: root.host.settingsReloadPending || !root.host.settingsLoaded,
      revision: root.host.settingsRevision,
      writeState: root.host.settingsWriteState,
      writeError: root.host.settingsWriteError,
      persisted: root.host.settingsPersisted && !root.host.settingsReloadPending,
      defaultsInUse: root.host.settingsDefaultsInUse,
      presentation: root.presentationData(root.host.settings)
    }
  }

  function validationMetadata() {
    var result = JSON.parse(JSON.stringify(root.metadata))
    if (result.settings && result.settings.sidebarWidgets)
      result.settings.sidebarWidgets.registeredIds = SidebarWidgetModel.registeredIds(
        root.host.sidebarWidgetRegistry || {})
    return result
  }

  function schemaSettings(key) {
    var result = Object.create(null)
    var metadata = root.validationMetadata()
    var keys = key === undefined ? Object.keys(metadata.settings) : [key]
    for (var i = 0; i < keys.length; ++i) {
      var name = keys[i]
      if (!Object.prototype.hasOwnProperty.call(metadata.settings, name))
        throw new Error("Unknown setting: " + name)
      result[name] = Object.assign({}, metadata.settings[name], { default: root.defaults[name] })
    }
    return result
  }

  // Requested preferences remain untouched. These diagnostics resolve the same
  // per-screen presentation the renderers consume — from settings and connected
  // screens alone, so a dry run resolves without any renderer instance — plus
  // the sidebar geometry/collapse of the outputs actually showing a sidebar.
  // Geometry is unavailable without a connected screen.
  function presentationData(requested) {
    var controller = root.host.sidebarController
    var presentation = ScreenPresentationModel.resolve({
      presentationMode: requested.presentationMode,
      presentationModeByMonitor: requested.presentationModeByMonitor,
      sidebarMonitor: requested.sidebarMonitor,
      workspaceMonitorOrder: requested.workspaceMonitorOrder,
      screens: root.host.connectedScreens || [],
      monitors: root.host.hyprMonitors || [],
      previousSidebarScreens: controller && controller.mappedScreens
        ? controller.mappedScreens : [],
      busy: controller ? controller.interactionBusy === true : false
    })
    var sidebarScreens = presentation.sidebarScreens
    var hasSidebar = sidebarScreens.length > 0
    // Geometry and the classic-only settings list describe the configured
    // sidebar presentation: outputs that show one now, or — when no screen is
    // connected yet — the sidebar-only default itself, so a disconnected
    // sidebar profile still projects the same numbers it always has.
    var sidebarPresentation = hasSidebar || presentation.defaultMode === "sidebar"
    var screen = hasSidebar ? sidebarScreens[0] : null
    var map = DockModel.normalizeSetting("sidebarCollapsedByMonitor",
      requested.sidebarCollapsedByMonitor)
    var defaultCollapsed = requested.sidebarCollapsed === true
    var collapsedByScreen = ({})
    sidebarScreens.forEach(function(entry) {
      var name = entry && entry.name ? entry.name : ""
      if (!name) return
      collapsedByScreen[name] = Object.prototype.hasOwnProperty.call(map, name)
        ? map[name] === true : defaultCollapsed
    })
    var primaryCollapsed = screen && Object.prototype.hasOwnProperty.call(collapsedByScreen, screen.name)
      ? collapsedByScreen[screen.name] : defaultCollapsed
    var bounds = SidebarModel.geometry(screen ? screen.width : 0,
      requested.sidebarExpandedWidth, primaryCollapsed)
    return {
      // Legacy summary fields keep their meaning: `mode` is the inherited
      // default (per-output truth lives below), and `screen`/`screens` describe
      // the outputs actually showing a sidebar — empty when none do, even if
      // the default mode is sidebar.
      mode: presentation.defaultMode,
      screen: screen ? screen.name : null,
      screens: sidebarScreens.map(function(entry) { return entry.name }),
      collapsedByScreen: collapsedByScreen,
      width: sidebarPresentation ? bounds.width : null,
      expandedWidth: sidebarPresentation ? bounds.expandedWidth : null,
      mapped: sidebarPresentation ? bounds.mapped : null,
      // Per-output resolution shared with the renderers: every connected
      // output with its effective mode, where it came from, and whether the
      // legacy sidebar selection (or an explicit override) maps it.
      defaultMode: presentation.defaultMode,
      perMonitor: presentation.entries.map(function(entry) {
        return {
          connector: entry.connector,
          mode: entry.mode,
          source: entry.source,
          mapped: entry.mapped,
          sidebarSelected: entry.sidebarSelected
        }
      }),
      modeByMonitor: presentation.modeByMonitor,
      sourceByMonitor: presentation.sourceByMonitor,
      mappedByMonitor: presentation.mappedByMonitor,
      classicScreens: presentation.classicScreens.map(function(entry) { return entry.name }),
      mixed: presentation.mixed,
      // Classic-only settings are still honored by classic outputs; this lists
      // what the sidebar presentation ignores, so it is empty only when no
      // sidebar is configured or rendered.
      inactiveClassicSettings: DockModel.inactiveClassicSettings(sidebarPresentation),
      widgets: SidebarWidgetModel.describe(requested.sidebarWidgets, root.host.sidebarWidgetRegistry || {},
        controller && controller.widgetManager ? controller.widgetManager.diagnostics() : null),
      // Source slices remain unreleased until the integrated SB-06 runtime gate.
      sidebarStage: "shared-scroll widget foundation; integrated qualification pending"
    }
  }

  function effectiveSettings(requested) {
    var result = JSON.parse(JSON.stringify(requested))
    var keys = Object.keys(root.defaults)
    for (var i = 0; i < keys.length; ++i) {
      var key = keys[i]
      var value = requested[key] === undefined ? root.defaults[key] : requested[key]
      result[key] = DockModel.normalizeSetting(key, value)
    }
    result.sidebarWidgets = SidebarWidgetModel.effectiveIds(requested.sidebarWidgets, root.host.sidebarWidgetRegistry || {})
    result.iconOverrides = ConfigModel.effectiveIcons(requested.iconOverrides)
    result.windowIconOverrides = DockIconModel.normalizeWindowRules(requested.windowIconOverrides)
    result.workspaceGroups = WorkspaceGroupModel.normalizeWorkspaceGroups(
      requested.workspaceGroups === undefined ? root.defaults.workspaceGroups : requested.workspaceGroups)
    result.groupWindows = false
    result.showTrash = TrashModel.normalizeShowTrash(requested.showTrash)
    result.windowScope = DockWindowModel.normalizeWindowScope(requested.windowScope)
    result.showUrgentOutsideScope = DockWindowModel.normalizeShowUrgentOutsideScope(requested.showUrgentOutsideScope)
    result.attentionBadgesEnabled = typeof requested.attentionBadgesEnabled === "boolean"
      ? requested.attentionBadgesEnabled : true
    result.urgentWindowAnimationEnabled = typeof requested.urgentWindowAnimationEnabled === "boolean"
      ? requested.urgentWindowAnimationEnabled : true
    result.launcherBadgeMode = requested.launcherBadgeMode === "dots-only" ? "dots-only" : "automatic"
    result.reserveSpace = DockModel.shouldReserveSpace(result.reserveSpace, result.autoHide)
    if (result.workspaceLayout === "flat") result.workspaceMonitorScope = "all"
    // Sidebar rewrites describe an output that actually renders a sidebar. In a
    // mixed layout the classic outputs keep honoring their own values for these
    // keys, so the rewrite applies only when the inherited default is sidebar
    // and no classic surface exists; with no connected screen it still follows
    // the sidebar-only default, exactly as before per-monitor overrides existed.
    var presentation = root.presentationData(requested)
    if (presentation.defaultMode === "sidebar" && presentation.classicScreens.length === 0) {
      result.position = result.sidebarEdge
      result.sidebarMonitor = presentation.screen
      result.sidebarExpandedWidth = presentation.expandedWidth === null
        ? DockModel.normalizeSetting("sidebarExpandedWidth", requested.sidebarExpandedWidth)
        : presentation.expandedWidth
      result.windowScope = "all"
      result.workspaceMonitorScope = "all"
      result.workspaceLayout = "grouped"
      result.workspaceGroups = []
      result.reserveSpace = true
      result.autoHide = false
      result.showPreviews = false
      result.magnification = 1
      result.hoverGlowEnabled = false
      result.urgentWindowAnimationEnabled = false
      result.showUrgentOutsideScope = false
      result.backgroundOpacity = 1
      result.backgroundColorEnabled = false
      result.borderColorEnabled = false
      result.borderWidthEnabled = false
      result.workspaceBadgeBackgroundColorEnabled = false
      result.workspaceBadgeTextColorEnabled = false
      result.iconSize = 32
      result.sortByWorkspace = false
      result.fullLength = true
      result.margin = 0
      // Sidebar navigation is not the classic configurable launcher policy.
      result.clickAction = null
      result.middleClickAction = null
      result.scrollAction = null
    }
    // Rendering resolves theme values in each dock. Null is deliberately not an
    // invented resolved color/width; requested overrides remain fully available.
    var colors = ["backgroundColor", "borderColor", "workspaceBadgeBackgroundColor", "workspaceBadgeTextColor"]
    for (var c = 0; c < colors.length; ++c) {
      var color = colors[c]
      if (!result[color + "Enabled"] || !result[color] || result[color].charAt(0) === "@")
        result[color] = null
    }
    if (!result.borderWidthEnabled) result.borderWidth = null
    return result
  }

  function mutationData(before, requested, changedKeys, dryRun, applied) {
    var data = root.statusData()
    data.changedKeys = changedKeys
    data.requested = requested
    data.effective = root.effectiveSettings(requested)
    data.presentation = root.presentationData(requested)
    data.diff = Object.create(null)
    for (var i = 0; i < changedKeys.length; ++i) {
      var key = changedKeys[i]
      data.diff[key] = { from: before[key] === undefined ? null : before[key], to: requested[key] }
    }
    data.dryRun = dryRun
    data.noop = changedKeys.length === 0
    data.applied = applied
    data.sourcePersisted = data.persisted
    if (dryRun) data.persisted = false
    data.themeResolution = "not-reported"
    return data
  }

  function readWarnings() {
    var warnings = []
    if (root.host.settingsLoadState === "invalid") warnings.push("Invalid disk config; showing last-good live settings.")
    if (!root.host.settingsLoaded || root.host.settingsReloadPending) warnings.push("Settings load/readback is pending.")
    if (!root.statusData().persisted) warnings.push("Live settings are not confirmed persisted.")
    return warnings
  }

  function applicationCommand(command, args) {
    var action = command.slice(5)
    var allowed = action === "list" ? ["query", "pinned", "hidden"]
      : action === "move" ? ["id", "before", "after"]
      : action === "show" ? ["id", "all"]
      : ["pin", "unpin", "hide"].indexOf(action) >= 0 ? ["id"] : null
    if (!allowed || Object.keys(args).some(function(key) { return allowed.indexOf(key) < 0 }))
      return root.failure("E_USAGE", "Unsupported application command or arguments: " + command)
    if (action === "list") {
      if (Object.keys(args).length > 1
          || (args.query !== undefined && typeof args.query !== "string")
          || (args.pinned !== undefined && args.pinned !== true)
          || (args.hidden !== undefined && args.hidden !== true))
        return root.failure("E_USAGE", "Use at most one of query, pinned=true or hidden=true.")
      var data = root.statusData()
      data.applications = ConfigModel.applicationRows(root.host.settings, root.host.applications, args)
      return root.success(data, root.readWarnings())
    }
    if (action === "show" && args.all !== undefined) {
      if (args.all !== true || args.id !== undefined)
        return root.failure("E_USAGE", "Show requires one ID or all=true, not both.")
    } else if (typeof args.id !== "string")
      return root.failure("E_USAGE", "An exact application ID is required.")
    if (action === "move" && ((args.before === undefined) === (args.after === undefined)
        || (args.before !== undefined && typeof args.before !== "string")
        || (args.after !== undefined && typeof args.after !== "string")))
      return root.failure("E_USAGE", "Move requires exactly one before or after ID.")
    return root.host.changeApplication(action, args)
  }

  function iconCommand(command, args) {
    var action = command.slice(6)
    var allowed = action === "list" ? [] : action === "set" ? ["id", "source", "titlePattern"]
      : action === "reset" ? ["id", "titlePattern"]
      : action === "reload" ? ["id"] : null
    if (!allowed || Object.keys(args).some(function(key) { return allowed.indexOf(key) < 0 }))
      return root.failure("E_USAGE", "Unsupported icon command or arguments: " + command)
    if (action === "list") {
      var data = root.statusData()
      data.overrides = ConfigModel.isObject(root.host.settings.iconOverrides) ? root.host.settings.iconOverrides : {}
      data.effectiveOverrides = ConfigModel.effectiveIcons(root.host.settings.iconOverrides)
      data.windowOverrides = ConfigModel.isObject(root.host.settings) && Array.isArray(root.host.settings.windowIconOverrides)
        ? root.host.settings.windowIconOverrides : []
      data.effectiveWindowOverrides = DockIconModel.normalizeWindowRules(root.host.settings.windowIconOverrides)
      data.iconReloadRevision = root.host.iconReloadRevision
      data.renderVerified = false
      return root.success(data, root.readWarnings())
    }
    if (typeof args.id !== "string" || (action === "set" && typeof args.source !== "string"))
      return root.failure("E_USAGE", "An exact application ID and, for set, a source string are required.")
    if (action === "reload") return root.host.reloadIcon(args.id)
    // An empty set is invalid. Only the explicit reset command removes artwork.
    if (action === "set" && args.source === "")
      return root.failure("E_VALIDATION", "Select a local PNG or SVG file.")
    if (args.titlePattern !== undefined) {
      if (typeof args.titlePattern !== "string")
        return root.failure("E_USAGE", "titlePattern must be a string.")
      return root.host.saveWindowIconOverride(action, {
        mode: "cli", appId: args.id, titlePattern: args.titlePattern,
        source: action === "set" ? args.source : null
      })
    }
    return root.host.saveIconOverride(args.id, action === "reset" ? "" : args.source)
  }

  function handle(payload) {
    var request
    try {
      request = JSON.parse(payload)
    } catch (error) {
      return root.failure("E_USAGE", "Request must be a JSON object.")
    }
    if (!request || Array.isArray(request) || request.apiVersion !== 1
        || typeof request.command !== "string" || !request.arguments
        || typeof request.arguments !== "object" || Array.isArray(request.arguments))
      return root.failure("E_PROTOCOL", "Expected apiVersion=1, command and arguments object.")
    var args = request.arguments
    var command = request.command
    if (command.indexOf("apps.") === 0) return root.applicationCommand(command, args)
    if (command.indexOf("icons.") === 0) return root.iconCommand(command, args)
    var allowed = command === "config.get" ? ["key", "effective"]
      : command === "config.schema" ? ["key"]
      : command === "config.apply" ? ["patch", "dryRun"]
      : command === "config.reset" ? ["key", "preferences"] : []
    if (Object.keys(args).some(function(key) { return allowed.indexOf(key) < 0 })
        || (args.key !== undefined && typeof args.key !== "string")
        || (args.effective !== undefined && typeof args.effective !== "boolean")
        || (args.dryRun !== undefined && typeof args.dryRun !== "boolean"))
      return root.failure("E_USAGE", "Invalid arguments for " + command)
    if (command === "status" || command === "doctor") return root.success(root.statusData())
    if (command === "mode.toggle") return root.host.toggleFocusedMonitorMode()
    if (command === "config.apply") return root.host.saveSettings(args.patch, args.dryRun === true)
    if (command === "config.retry") return root.host.retrySettings()
    if (command === "config.reset") {
      if ((args.key === undefined) === (args.preferences !== true)
          || (args.preferences !== undefined && args.preferences !== true))
        return root.failure("E_USAGE", "Reset requires either one key or preferences=true.")
      var patch = Object.create(null)
      if (args.preferences === true) patch = ConfigModel.preferenceResetPatch(root.defaults, root.metadata)
      else {
        if (!Object.prototype.hasOwnProperty.call(root.metadata.settings, args.key))
          return root.failure("E_VALIDATION", "Unknown setting: " + args.key)
        patch[args.key] = root.defaults[args.key]
      }
      return root.host.saveSettings(patch, false)
    }
    if (command !== "config.schema" && command !== "config.get")
      return root.failure("E_USAGE", "Unsupported command: " + command)
    var data = root.statusData()
    if (command === "config.schema") {
      try {
        data.source = "runtime"
        data.schemaVersion = root.metadata.schemaVersion
        data.commands = root.metadata.commands
        data.settings = root.schemaSettings(args.key)
        return root.success(data)
      } catch (error) {
        return root.failure("E_VALIDATION", String(error), data)
      }
    }
    if (args.key !== undefined && !Object.prototype.hasOwnProperty.call(root.host.settings, args.key))
      return root.failure("E_VALIDATION", "Unknown setting: " + args.key, data)
    var values = args.effective ? root.effectiveSettings(root.host.settings) : root.host.settings
    data.source = args.effective ? "effective" : "requested"
    data.view = data.source
    data.settings = args.key === undefined ? values : Object.create(null)
    if (args.key !== undefined) data.settings[args.key] = values[args.key]
    data.themeResolution = "not-reported"
    var warnings = args.effective
      ? ["Theme-owned/token colors and theme-owned border width are null, not resolved by this headless host."] : []
    if (root.host.settingsLoadState === "invalid") warnings.push("Invalid disk config; showing last-good live settings.")
    if (!data.persisted) warnings.push("Live settings are not confirmed persisted.")
    return root.success(data, warnings)
  }

  IpcHandler {
    target: "dockrail-settings"
    function open(): string {
      return root.host.openSettingsForFocused() ? "opened" : "no-anchor"
    }
    function close(): string {
      root.host.closeSettings()
      return "closed"
    }
    function toggle(): string {
      return root.host.toggleSettings() ? "opened" : "closed"
    }
  }

  IpcHandler {
    target: "smartdock"
    function request(payload: string): string {
      try {
        return JSON.stringify(root.handle(payload))
      } catch (error) {
        return JSON.stringify(root.failure("E_PROTOCOL", "Host could not process request: " + String(error)))
      }
    }
  }
}
