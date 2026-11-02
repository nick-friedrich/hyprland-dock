pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "components"
import "components/DockModel.js" as DockModel
import "components/DockWindowModel.js" as DockWindowModel
import "components/DockTrashModel.js" as TrashModel
import "components/DockConfigModel.js" as ConfigModel
import "components/DockIconModel.js" as DockIconModel
import "components/DockScreenPresentationModel.js" as ScreenPresentationModel

Item {
  id: root

  required property string configPath
  required property string runtimeMode
  property var settingsAnchors: []
  property Item settingsAnchor: null
  property string settingsConnector: ""
  readonly property alias settingsPanel: settingsSurface
  DockSettingsPanel {
    id: settingsSurface
    host: root
    metadata: dockControl.metadata
  }
  function registerSettingsAnchor(item, connector, mode) {
    if (!item) return false
    unregisterSettingsAnchor(item)
    settingsAnchors = settingsAnchors.concat([{item:item, connector:String(connector || ""), mode:mode}])
    if (settingsPanel.panelOpen) Qt.callLater(refreshSettingsAnchor)
    return true
  }
  function unregisterSettingsAnchor(item) {
    settingsAnchors = settingsAnchors.filter(function(entry) {return entry.item !== item})
    if (settingsAnchor === item) settingsAnchor = null
    if (settingsPanel && settingsPanel.panelOpen) Qt.callLater(refreshSettingsAnchor)
  }
  function usableSettingsAnchor(entry) {
    var item = entry && entry.item
    if (!item || !item.visible || item.width <= 0 || item.height <= 0) return false
    var window = item.QsWindow.window
    if (!window || !window.screen) return false
    var connector = root.settingsAnchorConnector(entry)
    var screen = ScreenPresentationModel.entryFor(currentPresentation(),connector)
    return !!screen && (!entry.mode || screen.mode === entry.mode)
  }
  function settingsAnchorConnector(entry) {
    var item = entry && entry.item
    var window = item ? item.QsWindow.window : null
    // The surface Loader assigns its owner after child completion/registration.
    return window && window.screen ? window.screen.name : String(entry && entry.connector || "")
  }
  // Focused output for keyboard/CLI/IPC summon. Hyprland monitor names match
  // Quickshell screen connectors; fall back to the remembered connector.
  // The authoritative focused monitor is Hyprland.focusedMonitor — the
  // per-monitor `focused` flag is not maintained on Quickshell 0.3.2, so the
  // monitor-list scan alone resolves nothing on a fresh summon and degrades to
  // candidates[0]. Prefer the singleton, then the monitor scan (test fixtures),
  // then the remembered connector.
  function focusedSettingsConnector() {
    var focusedMonitor = focusedHyprlandMonitor
    if (focusedMonitor) {
      var fmName = String(focusedMonitor.name || "").trim()
      if (fmName) return fmName
    }
    var monitors = hyprMonitors || []
    for (var i = 0; i < monitors.length; ++i) {
      var monitor = monitors[i]
      if (!monitor) continue
      var focused = monitor.focused !== undefined ? monitor.focused === true
        : ((monitor.lastIpcObject || {}).focused === true)
      if (!focused) continue
      var ipc = monitor.lastIpcObject || monitor
      var name = String(ipc.name !== undefined ? ipc.name : monitor.name || "").trim()
      if (name) return name
    }
    return settingsConnector || ""
  }
  function defaultSetting(key) {
    return dockControl.defaults[key]
  }
  function resetSettingIntent(key, expectedValue) {
    return saveSettingIntent(key, defaultSetting(key), expectedValue)
  }
  function openSettings(anchor, connector, section) {
    var candidates = settingsAnchors.filter(function(entry) { return usableSettingsAnchor(entry) })
      .map(function(entry) {return {item:entry.item,mode:entry.mode,connector:root.settingsAnchorConnector(entry)}})
    var chosen = null
    if (anchor) {
      chosen = candidates.filter(function(entry) {return entry.item === anchor})[0]
    } else {
      var focused = focusedSettingsConnector()
      var wanted = [connector, focused, settingsConnector]
      for (var w = 0; w < wanted.length && !chosen; ++w) {
        var name = String(wanted[w] || "")
        if (!name) continue
        chosen = candidates.filter(function(entry) {return entry.connector === name})[0]
      }
      if (!chosen) chosen = candidates[0]
    }
    if (!chosen) return false
    var candidate = chosen.item
    var previous = activeIconDialog
    if (previous && previous.dialogActive) previous.closeDialog()
    settingsAnchor = candidate
    settingsConnector = chosen.connector || candidate.QsWindow.window.screen.name
    var onScreen = ScreenPresentationModel.entryFor(currentPresentation(), settingsConnector)
    var edge = onScreen && onScreen.mode === "sidebar"
      ? DockModel.normalizeSetting("sidebarEdge", settings.sidebarEdge) : "bottom"
    return settingsPanel.openFor(candidate, edge, section)
  }
  function refreshSettingsAnchor() {
    if (!settingsPanel.panelOpen) return
    if (!openSettings(null,settingsConnector)) closeSettings()
  }
  function shownSetting(key) {
    if (key === "sidebarExpandedWidth" && sidebarController) {
      var sidebarScreens = currentPresentation().sidebarScreens || []
      var screen = sidebarScreens.filter(function(screen) {return screen.name === root.settingsConnector})[0]
        || sidebarScreens[0]
      if (screen) return sidebarController.geometryFor(screen).expandedWidth
    }
    return dockControl.effectiveSettings(settings)[key]
  }
  function closeSettings() { settingsSurface.close() }
  function toggleSettings() {
    if (settingsSurface.panelOpen) { closeSettings(); return false }
    return openSettings(null, focusedSettingsConnector() || settingsConnector)
  }
  function openSettingsForFocused(section) {
    return openSettings(null, focusedSettingsConnector() || settingsConnector, section)
  }
  function releaseSettingsPanel(panel) {
    if (panel === settingsSurface) settingsSurface.panelOpen = false
  }
  // Demo.* entries are visible in Settings only for an explicit development session.
  readonly property bool settingsDeveloperBuild: typeof Quickshell.env === "function"
    && String(Quickshell.env("DOCKRAIL_DEV_BUILD") || "") === "1"
  readonly property alias settingsActions: settingsActionBroker
  DockSettingsActions {
    id: settingsActionBroker
  }
  // The panel toggles this visibility in SET-03; when closed, no polling.
  readonly property alias featureReadinessBridge: featureReadinessProbe
  DockFeatureReadinessBridge {
    id: featureReadinessProbe
  }
  property string dataRoot: ""
  property var notificationService: null
  property var launcherBadgeService: null
  property var browserProfileService: null
  property var herdrService: null
  property var t3Service: null
  property var claudeService: null
  property bool herdrBinaryInstalled: false
  property bool herdrBinaryProbePending: false
  property bool t3BinaryInstalled: false
  property bool t3BinaryProbePending: false
  readonly property var applications: DesktopEntries.applications.values || []
  property int iconReloadRevision: 0
  // Menus may cache popup instances, but only one editor owns a live session.
  property var activeIconDialog: null
  // Reuse the exact app picker and Change Icon dialog used by dock menus.
  // Settings never owns a second artwork editor or application-list writer.
  LazyLoader {
    id:settingsAppPickerLoader
    active:false
    DockAppPicker {
      anchorItem:root.settingsAnchor
      position:root.settingsPanel.anchorPosition
      pinned:root.settings.pinned || []
      iconOverrides:root.settings.iconOverrides || ({})
      iconReloadRevision:root.iconReloadRevision
      onApplicationSelected:function(desktopId) {
        root.settingsPanel.reportWrite(root.pinApplication(desktopId))
      }
    }
  }
  LazyLoader {
    id:settingsIconDialogLoader
    active:false
    DockIconDialog {mutationController:root}
  }
  function closeAppPickerFromSettings() {
    // Standalone PopupWindow does not follow KeyboardPanel visibility.
    // In source-only writer tests the UI Loader is deliberately absent.
    if(typeof settingsAppPickerLoader !== "undefined" && settingsAppPickerLoader)
      settingsAppPickerLoader.active=false
  }
  function openAppPickerFromSettings() {
    if(!settingsPanel.panelOpen || !settingsAnchor) return false
    settingsAppPickerLoader.active=true
    return !!settingsAppPickerLoader.item && (settingsAppPickerLoader.item.open(),true)
  }
  function openIconFromSettings(item) {
    if(!settingsPanel.panelOpen || !settingsAnchor || !item || !item.desktopId) return false
    closeAppPickerFromSettings()
    var options={
      anchorItem:settingsAnchor,position:settingsPanel.anchorPosition,
      desktopId:item.desktopId,appName:item.name||item.desktopId,
      profileKey:item.profileKey||"",profileName:item.profileKey||"",
      appId:item.appId||"",existingTitlePattern:item.kind==="window"?item.titlePattern:"",
      specificWindow:false
    }
    settingsIconDialogLoader.active=true
    return !!settingsIconDialogLoader.item && settingsIconDialogLoader.item.openFor(options)
  }
  function windowIconTargetKey(appId,pattern) {
    return DockIconModel.windowRuleKey(appId,pattern)
  }

  readonly property bool iconDialogActive: root.activeIconDialog !== null
    && root.activeIconDialog.dialogActive === true

  function claimIconDialog(dialog) {
    if (!dialog || typeof dialog.closeDialog !== "function") return false
    var previous = root.activeIconDialog
    // Publish the new owner first: cleanup by the previous owner cannot release it.
    root.activeIconDialog = dialog
    if (root.settingsPanel && root.settingsPanel.panelOpen) root.settingsPanel.close()
    if (previous && previous !== dialog && previous.dialogActive === true)
      previous.closeDialog()
    return true
  }

  function releaseIconDialog(dialog) {
    if (root.activeIconDialog === dialog) root.activeIconDialog = null
  }

  // Picker readiness is deliberately independent from DockHerdrService.available:
  // the service reports the bundled provider, while this bounded probe reports
  // whether the user's Herdr CLI is currently discoverable on PATH.
  function refreshHerdrBinaryAvailability() {
    if (herdrBinaryProbe.running) return false
    root.herdrBinaryProbePending = true
    herdrBinaryProbeTimeout.restart()
    herdrBinaryProbe.running = true
    return true
  }

  function refreshT3BinaryAvailability() {
    if (t3BinaryProbe.running) return false
    root.t3BinaryProbePending = true
    t3BinaryProbeTimeout.restart()
    t3BinaryProbe.running = true
    return true
  }

  // Keep the lease boundary stable while unrelated registry entries refresh.
  function acquireHerdrWidget(owner) {
    return root.herdrWindowAgents.createConsumerLease(owner)
  }

  function acquireT3Widget(owner) {
    return root.herdrWindowAgents.createConsumerLease(owner)
  }

  function sidebarWidgetActive(id) {
    var view = sidebarState.widgetView(id)
    return !!(view && view.active)
  }

  readonly property bool herdrSourceWanted: (DockModel.normalizeSetting(
      "dockHerdrIndicators", root.settings.dockHerdrIndicators)
      && root.presentation.classicScreens.length > 0)
    || root.sidebarWidgetActive("herdr.agents")
  readonly property bool t3SourceWanted: (DockModel.normalizeSetting(
      "dockT3Indicators", root.settings.dockT3Indicators)
      && root.presentation.classicScreens.length > 0)
    || root.sidebarWidgetActive("t3.threads")
  // The dock and the sidebar both show Claude Desktop sessions; the setting alone creates demand.
  readonly property bool claudeSourceWanted: DockModel.normalizeSetting(
      "dockClaudeIndicators", root.settings.dockClaudeIndicators)
  readonly property var connectedScreens: Quickshell.screens
  readonly property var hyprMonitors: Hyprland.monitors ? Hyprland.monitors.values || [] : []
  readonly property var focusedHyprlandMonitor: Hyprland.focusedMonitor
  readonly property var hyprWorkspaces: Hyprland.workspaces ? Hyprland.workspaces.values || [] : []
  readonly property var desktopToplevels: ToplevelManager.toplevels.values || []
  readonly property var hyprToplevels: Hyprland.toplevels ? Hyprland.toplevels.values || [] : []
  // Branch-only synthetic Widget fixtures are combined with internal source-owned
  // providers. Neither accepts commands, paths, or credentials from settings.
  readonly property var sidebarWidgetRegistry: {
    var registry = {}
    var demoDescriptors = root.settingsDeveloperBuild ? demoWidgetRegistry.descriptors : ({})
    Object.keys(demoDescriptors).forEach(function(widgetId) {
      registry[widgetId] = demoDescriptors[widgetId]
    })
    if (root.herdrService) {
      registry["herdr.agents"] = {
        id: "herdr.agents",
        label: "Herdr agents",
        description: "Show coding-agent sessions from Herdr in the sidebar.",
        feature: "herdr",
        manageable: root.herdrBinaryInstalled,
        available: root.herdrBinaryInstalled && root.herdrService.available !== false,
        revision: 1,
        acquire: root.acquireHerdrWidget,
        expandedView: herdrExpandedView,
        compactView: herdrCompactView,
        popupView: herdrPopupView
      }
    }
    if (root.t3Service) {
      registry["t3.threads"] = {
        id: "t3.threads",
        label: "T3 Code threads",
        description: "Show T3 Code threads from the local T3 server in the sidebar.",
        feature: "t3",
        manageable: root.t3BinaryInstalled,
        available: root.t3BinaryInstalled && root.t3Service.available !== false,
        revision: 1,
        acquire: root.acquireT3Widget,
        expandedView: t3ExpandedView,
        compactView: t3CompactView,
        popupView: t3PopupView
      }
    }
    var externalDescriptors = externalWidgetRegistry.descriptors || ({})
    Object.keys(externalDescriptors).sort().forEach(function(widgetId) {
      if (!Object.prototype.hasOwnProperty.call(registry, widgetId))
        registry[widgetId] = externalDescriptors[widgetId]
    })
    return registry
  }
  readonly property var sidebarController: sidebarState
  readonly property var sidebarPanels: ScreenPresentationModel.aggregateSidebarPanels(
    presentationOwners.instances)
  // Primary surface for harnesses that still expect a single panel reference.
  readonly property var sidebarPanel: sidebarPanels.length ? sidebarPanels[0] : null

  // Pure per-screen presentation resolution, the same function the sidebar
  // controller and CLI diagnostics run: each connected output resolves its own
  // mode from presentationModeByMonitor, inheriting the global presentationMode
  // when unmapped, so classic and sidebar surfaces coexist. Owners bind to the
  // `presentation` copy declaratively; gesture writes re-resolve through this
  // function so they always validate against live state.
  function currentPresentation() {
    return ScreenPresentationModel.resolve({
      presentationMode: settings.presentationMode,
      presentationModeByMonitor: settings.presentationModeByMonitor,
      sidebarMonitor: settings.sidebarMonitor,
      workspaceMonitorOrder: settings.workspaceMonitorOrder,
      screens: connectedScreens,
      monitors: hyprMonitors,
      previousSidebarScreens: sidebarState ? sidebarState.mappedScreens : [],
      busy: sidebarState ? sidebarState.interactionBusy === true : false
    })
  }
  readonly property var presentation: currentPresentation()
  onPresentationChanged: if (settingsPanel && settingsPanel.panelOpen) Qt.callLater(refreshSettingsAnchor)
  onSettingsChanged: if (settingsPanel && settingsPanel.panelOpen) Qt.callLater(refreshSettingsAnchor)

  property int trashItemCount: 0
  property bool trashStateKnown: false
  // One listing settles only after both its exit code and its output arrive.
  property int trashListExitCode: -1
  property bool trashListOutputDone: false
  property bool settingsLoaded: false
  property bool showTrashSetting: true
  property string settingsLoadState: "missing"
  property string settingsLoadError: ""
  property int settingsRevision: 0
  property bool settingsDefaultsInUse: true
  property bool settingsPersisted: false
  property string settingsWriteState: "idle"
  property string settingsWriteError: ""
  // Background mode-switch feedback keyed by output connector. Each renderer
  // reports only its own connector, and the host owns the map — so a stale or
  // rejected gesture on one monitor can never display on another, even across
  // renderer replacement. Drag persistence failures stay host-wide through
  // settingsWriteState; menu persistence failures use modeMenuWriteConnector.
  // Feedback clears when settings reload or save, and is overwritten by the next
  // gesture for that connector.
  property var modeGestureFeedbackByMonitor: ({})
  // A menu-initiated save failure belongs to the menu's output; background
  // gesture failures retain their existing host-wide persistence feedback.
  property string modeMenuWriteConnector: ""
  property bool settingsReloadPending: false
  property string settingsLoadedText: ""
  property string settingsWriteBaseText: ""
  property string settingsWriteText: ""
  property var workspaceWindowCounts: ({})
  property bool workspaceCountsReady: false
  property int workspaceCountsRevision: 0
  property bool workspaceCountsRefreshPending: false
  property int scopeRevision: scopeRefreshController.revision
  readonly property var windowActions: windowActionsController
  readonly property var herdrWindowAgents: herdrWindowAgentsController
  readonly property var herdrAgentActions: herdrAgentActionsController
  readonly property var workspaceMonitorDrag: workspaceMonitorDragController
  readonly property var badgeTracker: badgeTrackerController
  readonly property bool showTrash: showTrashSetting

  // Shared with the read-only CLI metadata; defaults are never persisted merely
  // by discovery or by loading a host whose user configuration does not exist.
  property var settings: dockControl.defaults

  function loadSettings(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
          || !Array.isArray(parsed.pinned))
        throw new Error("Configuration must be an object with a 'pinned' array")
      var requested = Object.create(null)
      Object.keys(dockControl.defaults).forEach(function(key) {
        requested[key] = dockControl.defaults[key]
      })
      Object.keys(parsed).forEach(function(key) { requested[key] = parsed[key] })
      showTrashSetting = TrashModel.normalizeShowTrash(parsed.showTrash)
      if (ConfigModel.iconsChanged(settings.iconOverrides, requested.iconOverrides)
          || ConfigModel.windowIconsChanged(settings.windowIconOverrides, requested.windowIconOverrides))
        iconReloadRevision++
      if (JSON.stringify(settings) !== JSON.stringify(requested)) settingsRevision++
      modeGestureFeedbackByMonitor = ({})
      modeMenuWriteConnector = ""
      settings = requested
      settingsLoadState = "loaded"
      settingsLoadError = ""
      settingsLoadedText = raw
      settingsDefaultsInUse = false
      settingsPersisted = true
      settingsWriteState = "idle"
      settingsWriteError = ""
    } catch (error) {
      settingsLoadState = "invalid"
      settingsLoadError = String(error)
      settingsPersisted = false
      console.warn("Dock: could not load " + configPath + ":", error)
    }
    settingsLoaded = true
    if (showTrash) Qt.callLater(root.refreshTrash)
  }

  function reorderPinned(sourceDesktopId, targetDesktopId) {
    var pins = Array.isArray(settings.pinned) ? settings.pinned : []
    var sourceKey = ConfigModel.canonicalApplicationId(sourceDesktopId)
    var targetKey = ConfigModel.canonicalApplicationId(targetDesktopId)
    var sourceIndex = ConfigModel.identityIndex(pins, sourceKey)
    var targetIndex = ConfigModel.identityIndex(pins, targetKey)
    if (sourceKey && targetKey && sourceIndex >= 0 && sourceIndex === targetIndex)
      return saveSettings({}, false)
    // A forward drop occupies the target's old slot (after it once removed);
    // a backward drop goes before it. Use the same legacy-preserving primitive
    // as CLI moves instead of revalidating every untouched stored pin.
    var args = { id: sourceDesktopId }
    args[sourceIndex < targetIndex ? "after" : "before"] = targetDesktopId
    return changeApplication("move", args)
  }

  function pinApplication(desktopId) {
    return changeApplication("pin", { id: desktopId })
  }

  function unpinApplication(desktopId) {
    return changeApplication("unpin", { id: desktopId })
  }

  function hideApplication(desktopId) {
    return changeApplication("hide", { id: desktopId })
  }

  function groupWorkspaceApplication(desktopId, workspace) {
    return changeWorkspaceGroup("group", desktopId, workspace)
  }

  function ungroupWorkspaceApplication(desktopId, workspace) {
    return changeWorkspaceGroup("ungroup", desktopId, workspace)
  }

  function changeWorkspaceGroup(action, desktopId, workspace) {
    var blocked = mutationBlocked()
    if (blocked) return blocked
    return commitSettings(ConfigModel.workspaceGroupIntent(
      settings, applications, action,
      { desktopId: desktopId, workspace: workspace }), false)
  }

  function toggleBrowserActivityMute(serviceId) {
    var blocked = mutationBlocked()
    if (blocked) return blocked
    var current = DockModel.normalizeSetting(
      "browserActivityMutedServices", settings.browserActivityMutedServices)
    return saveSetting("browserActivityMutedServices",
      DockModel.toggleBrowserActivityServiceMute(current, serviceId))
  }

  function changeApplication(action, args) {
    var blocked = mutationBlocked()
    if (blocked) return blocked
    return commitSettings(ConfigModel.applicationIntent(settings, applications, action, args), false)
  }

  function iconResult(reply, reloaded) {
    reply.data.iconReloadRevision = iconReloadRevision
    reply.data.reloaded = reloaded
    reply.data.renderVerified = false
    reply.data.windowOverrides = Array.isArray(settings.windowIconOverrides)
      ? settings.windowIconOverrides : []
    reply.data.effectiveWindowOverrides = DockIconModel.normalizeWindowRules(
      settings.windowIconOverrides)
    reply.warnings.push("Artwork is referenced in place. Saving or requesting a reload does not verify decoding or rendering.")
    return reply
  }

  function saveIconOverride(desktopId, sourceUrl) {
    var blocked = mutationBlocked()
    if (blocked) return iconResult(blocked, false)
    var source = sourceUrl === "" ? null : sourceUrl
    var result = ConfigModel.iconIntent(settings, desktopId, source)
    var revision = iconReloadRevision
    var reply = commitSettings(result, false)
    // Same-path Apply deliberately reloads bytes, but never creates a redundant
    // config write. Failed persistence still leaves the accepted live intent.
    if (result.ok && source !== null && iconReloadRevision === revision) iconReloadRevision++
    return iconResult(reply, iconReloadRevision !== revision)
  }

  function saveWindowIconOverride(action, args) {
    var blocked = mutationBlocked()
    if (blocked) return iconResult(blocked, false)
    var result = ConfigModel.windowIconIntent(settings, action, args)
    var revision = iconReloadRevision
    var reply = commitSettings(result, false)
    // A same-source set is an explicit byte reload without a redundant settings write.
    if (result.ok && action === "set" && iconReloadRevision === revision) iconReloadRevision++
    return iconResult(reply, iconReloadRevision !== revision)
  }

  // Change Icon dialog: remove the captured override and/or set the new one in
  // a single settings write.
  function saveIconChange(args) {
    var blocked = mutationBlocked()
    if (blocked) return iconResult(blocked, false)
    var result = ConfigModel.iconChangeIntent(settings, args)
    var revision = iconReloadRevision
    var reply = commitSettings(result, false)
    if (result.ok && args && args.set && iconReloadRevision === revision) iconReloadRevision++
    return iconResult(reply, iconReloadRevision !== revision)
  }

  function reloadIcon(desktopId) {
    var blocked = mutationBlocked()
    if (blocked) return iconResult(blocked, false)
    var key = ConfigModel.canonicalApplicationId(desktopId)
    var configured = ConfigModel.effectiveIcons(settings.iconOverrides)
    if (!key || !Object.prototype.hasOwnProperty.call(configured, key))
      return iconResult(dockControl.failure("E_VALIDATION", "Reload requires an existing local icon mapping."), false)
    // The retained renderer uses one host revision; other mapped icons can also
    // refresh. No settings revision or persistence write is involved; file
    // edits also refresh automatically through iconReloadScheduler.
    iconReloadRevision++
    return iconResult(mutationOutcome(dockControl.mutationData(settings, settings, [], false, false)), true)
  }

  function savePinned(pinned) {
    return saveSetting("pinned", pinned)
  }

  function saveSetting(key, value) {
    var patch = Object.create(null)
    patch[key] = value
    return saveSettings(patch, false)
  }

  // Gesture-owned preferences need one small adapter around the sole writer.
  // It distinguishes a rejected preflight/stale intent from a live intent that
  // was accepted but whose async FileView persistence is still pending.
  function saveSettingIntent(key, value, expectedValue) {
    var blocked = mutationBlocked()
    if (blocked) return { accepted: false, pending: false, reply: blocked }
    // Structural comparison: object settings (override/collapse maps) must not
    // read as stale merely because the same value is a different instance.
    if (!DockModel.sameSettingValue(settings[key], expectedValue)) {
      var stale = dockControl.mutationData(settings, settings, [], false, false)
      stale.currentValue = settings[key]
      stale.expectedValue = expectedValue
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_STALE",
          "Preference changed after the interaction started; refresh before retrying.", stale) }
    }
    var reply = saveSetting(key, value)
    var applied = !!(reply && reply.data && reply.data.applied === true)
    var accepted = !!(reply && (reply.ok || applied))
    var pending = accepted && !reply.ok && !!reply.error && reply.error.code === "E_BUSY"
    return { accepted: accepted, pending: pending, reply: reply }
  }

  // The Settings page owns the user-visible draft; the host owns the one
  // canonical writer. Compare the complete touched-key snapshot synchronously
  // before validation or mutation; a stale colour/feature pair changes nothing.
  // Expected values are mandatory for every touched key, never inferred here.
  function saveSettingsIntent(patch, expectedValues) {
    var blocked = mutationBlocked()
    if (blocked) return { accepted: false, pending: false, reply: blocked }
    var valid = patch && typeof patch === "object" && !Array.isArray(patch)
      && expectedValues && typeof expectedValues === "object" && !Array.isArray(expectedValues)
    var keys = valid ? Object.keys(patch) : []
    if (!valid || !keys.length || keys.some(function(key) {
      return !Object.prototype.hasOwnProperty.call(expectedValues, key)
    })) {
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_VALIDATION",
          "Every touched setting needs an expected starting value.") }
    }
    for (var i = 0; i < keys.length; ++i) {
      var key = keys[i]
      if (!DockModel.sameSettingValue(settings[key], expectedValues[key])) {
        var stale = dockControl.mutationData(settings, settings, [], false, false)
        stale.key = key
        stale.currentValue = settings[key]
        stale.expectedValue = expectedValues[key]
        return { accepted: false, pending: false,
          reply: dockControl.failure("E_STALE",
            "Preference changed after the interaction started; refresh before retrying.", stale) }
      }
    }
    // saveSettings reuses ConfigModel.applyPatch, commitSettings and FileView;
    // this synchronous call never opens a second writer or editor.
    var reply = saveSettings(patch, false)
    var applied = !!(reply && reply.data && reply.data.applied === true)
    var accepted = !!(reply && (reply.ok || applied))
    var pending = accepted && !reply.ok && !!reply.error && reply.error.code === "E_BUSY"
    return { accepted: accepted, pending: pending, reply: reply }
  }

  // Per-connector rejection text stored for a completed background gesture.
  function modeGestureFeedbackFor(connector) {
    var text = modeGestureFeedbackByMonitor[String(connector || "")]
    return typeof text === "string" ? text : ""
  }

  function setModeGestureFeedback(connector, text) {
    var name = String(connector || "")
    if (!name) return
    var next = ({})
    Object.keys(modeGestureFeedbackByMonitor).forEach(function(key) {
      next[key] = modeGestureFeedbackByMonitor[key]
    })
    next[name] = String(text || "")
    modeGestureFeedbackByMonitor = next
  }

  // What a surface displays: its own connector's rejection first, plus a
  // persistence failure. Drag failures remain host-wide; menu failures appear
  // only on the output whose menu started the write.
  function modeGestureDisplayFor(connector) {
    var local = modeGestureFeedbackFor(connector)
    if (settingsWriteState !== "error") return local
    if (modeMenuWriteConnector && String(connector || "") !== modeMenuWriteConnector)
      return local
    var persistence = DockModel.persistenceFeedback(settingsWriteError)
    return local ? local + " · " + persistence : persistence
  }

  // A completed background mode gesture, routed through the same sole writer.
  // Exactly one intent per gesture, scoped to the connector it started on:
  // only that connector's presentationModeByMonitor entry may change. Feedback
  // is stored on the host because the gesture's own renderer may be the one
  // torn down by a successful switch.
  function commitMonitorModeGesture(connector, destination, capturedState, menuOrigin) {
    if (menuOrigin !== true) modeMenuWriteConnector = ""
    var feedback = DockModel.modeDragWriteError(
      monitorModeIntent(connector, destination, capturedState))
    setModeGestureFeedback(connector, feedback)
    return feedback
  }

  function commitMonitorModeMenu(connector, destination, capturedState) {
    var previousOrigin = modeMenuWriteConnector
    modeMenuWriteConnector = String(connector || "")
    var feedback = commitMonitorModeGesture(connector, destination, capturedState, true)
    if (feedback) modeMenuWriteConnector = previousOrigin
    return feedback
  }

  function monitorModeIntent(connector, destination, capturedState) {
    var name = String(connector || "")
    var mode = ["sidebar", "classic", "default"].indexOf(destination) >= 0 ? destination : ""
    if (!name || !mode)
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_VALIDATION",
          "A mode switch needs a connected output and a destination mode.") }
    var blocked = mutationBlocked()
    if (blocked) return { accepted: false, pending: false, reply: blocked }
    var live = currentPresentation()
    var entry = ScreenPresentationModel.entryFor(live, name)
    if (!entry)
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_STALE",
          "This output is no longer connected; the mode was not changed.") }
    if (!ScreenPresentationModel.modeGestureTokenCurrent(capturedState, live, name))
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_STALE",
          "Preference changed after the interaction started; refresh before retrying.") }
    // Preserve the existing mode-switch contract shared by menu, drag and
    // Settings: normalize malformed legacy values before constructing a new
    // validated map. Do not turn a shortcut-only hardening change into a
    // rejection for unrelated, disconnected invalid entries.
    // The writer's stale check still compares the entire live raw value.
    var expected = settings.presentationModeByMonitor
    var nextMap = Object.assign({},
      DockModel.normalizeSetting("presentationModeByMonitor", expected))
    if (mode === "default") delete nextMap[name]
    else nextMap[name] = mode
    return saveSettingIntent("presentationModeByMonitor", nextMap, expected)
  }

  // A shortcut targets Hyprland's currently focused output, never the
  // Settings panel's remembered connector or the first connected display.
  // Reuse the same token guard and sole FileView writer as menu/drag switching.
  function toggleFocusedMonitorMode() {
    var focused = focusedHyprlandMonitor
    var connector = focused ? String(focused.name || "").trim() : ""
    if (!connector)
      return dockControl.failure("E_RUNTIME_NOT_FOUND",
        "Hyprland has no focused monitor; no presentation was changed.")
    var current = currentPresentation()
    var entry = ScreenPresentationModel.entryFor(current, connector)
    // During hotplug Quickshell may still list a screen Hyprland has removed.
    // Require the connector in both inventories before applying a shortcut.
    if (!entry || !DockWindowModel.monitorForScreen(entry.screen, hyprMonitors))
      return dockControl.failure("E_STALE",
        "The focused monitor is not a connected Dockrail output; no presentation was changed.")
    // An inherited sidebar can be intentionally unmapped by sidebarMonitor.
    // First reveal that screen's sidebar; only a visible sidebar toggles to dock.
    var destination = entry.mode === "sidebar" && entry.mapped ? "classic" : "sidebar"
    var token = ScreenPresentationModel.modeGestureToken(current, connector)
    // Scope a failed save to this output, as the existing menu switch does.
    var previousOrigin = modeMenuWriteConnector
    modeMenuWriteConnector = connector
    var outcome = monitorModeIntent(connector, destination, token)
    var feedback = DockModel.modeDragWriteError(outcome)
    setModeGestureFeedback(connector, feedback)
    if (feedback) modeMenuWriteConnector = previousOrigin
    // A rejected/busy preflight is only a proposal, not a mode switch.
    if (outcome.accepted && outcome.reply && outcome.reply.data)
      outcome.reply.data.modeSwitch = {
        connector: connector, from: entry.mapped ? entry.mode : "unmapped", to: destination
      }
    return outcome.reply
  }

  // One position request from either renderer. Dragging the bottom dock's empty
  // background left switches that output to the sidebar; dragging empty sidebar
  // background down switches that output back to the classic dock. The gesture
  // writes this monitor's presentationModeByMonitor entry, never the global
  // position setting, and expectedPosition only exists to keep the legacy
  // signal shape — a stale gesture is rejected through its token instead.
  function handlePositionRequest(connector, position, expectedPosition, gestureToken) {
    if (position !== "left" && position !== "bottom")
      return { accepted: false, pending: false,
        reply: dockControl.failure("E_VALIDATION",
          "Unsupported gesture destination: " + String(position)) }
    return commitMonitorModeGesture(connector,
      position === "left" ? "sidebar" : "classic", gestureToken)
  }

  function mutationBlocked() {
    var data = dockControl.mutationData(settings, settings, [], false, false)
    if (!settingsLoaded || settingsReloadPending || settingsWriteState === "saving")
      return dockControl.failure("E_BUSY", "Settings are loading or saving. Read status before retrying.", data)
    if (settingsLoadState === "invalid")
      return dockControl.failure("E_CONFIG_INVALID", "Repair the invalid existing config externally before changing settings: " + settingsLoadError, data)
    return null
  }

  function mutationOutcome(data) {
    if (settingsWriteState === "error")
      return dockControl.failure("E_PERSISTENCE", settingsWriteError, data)
    if (settingsWriteState === "saving" || settingsReloadPending)
      return dockControl.failure("E_BUSY", "Live intent accepted; save/readback has not completed. Read status before retrying.", data)
    var warnings = data.persisted ? [] : ["Live settings are not confirmed persisted."]
    return dockControl.success(data, warnings)
  }

  function saveSettings(patch, dryRun) {
    var blocked = mutationBlocked()
    if (blocked) return blocked
    return commitSettings(ConfigModel.applyPatch(settings, patch,
      dockControl.validationMetadata()), dryRun)
  }

  // Only validated config/app/icon model results reach this common live commit.
  // IPC never accepts a prevalidated result or a full replacement snapshot.
  function commitSettings(result, dryRun) {
    var before = settings
    if (!result.ok) {
      var rejected = dockControl.mutationData(before, before, [], false, false)
      rejected.validationErrors = result.errors
      return dockControl.failure(result.errorCode || "E_VALIDATION",
        result.errorCode === "E_CONFLICT"
          ? "The icon changed while the edit was open; reopen it and try again."
          : "Patch rejected; no values were changed.", rejected)
    }
    if (dryRun === true)
      return dockControl.success(dockControl.mutationData(before, result.settings, result.changedKeys, true, false),
        ["Dry run only. Theme-owned/token colors and theme-owned border width are unresolved null values."])
    if (result.changedKeys.length === 0)
      return mutationOutcome(dockControl.mutationData(before, before, [], false, false))
    showTrashSetting = TrashModel.normalizeShowTrash(result.settings.showTrash)
    if (ConfigModel.iconsChanged(before.iconOverrides, result.settings.iconOverrides)
        || ConfigModel.windowIconsChanged(before.windowIconOverrides, result.settings.windowIconOverrides))
      iconReloadRevision++
    settings = result.settings
    settingsRevision++
    settingsDefaultsInUse = false
    settingsPersisted = false
    writeSettings()
    return mutationOutcome(dockControl.mutationData(before, settings, result.changedKeys, false, true))
  }

  function retrySettings() {
    var blocked = mutationBlocked()
    if (blocked) return blocked
    if (settingsPersisted)
      return dockControl.success(dockControl.mutationData(settings, settings, [], false, false))
    // Retry persists the complete current snapshot, including later successful
    // intents. It does not replay a stale failed patch or create another revision.
    writeSettings()
    return mutationOutcome(dockControl.mutationData(settings, settings, [], false, true))
  }

  // Retained FDM-881 writer behavior from PR #43 @7473a23: actual saved/error
  // completion, bounded retry bytes and failed-write echo protection. One write
  // path is shared by CLI and existing dock-menu intents.
  function writeSettings() {
    var text = JSON.stringify(settings, null, 2) + "\n"
    settingsWriteBaseText = settingsLoadedText
    if (text === configFile.cachedText) text += "\n"
    settingsWriteText = text
    settingsWriteState = "saving"
    configFile.setText(text)
  }

  function settingsFileLoaded(raw) {
    if (settingsReloadPending) {
      settingsReloadPending = false
      if (settingsWriteState === "error" && raw === settingsWriteBaseText) return
    }
    loadSettings(raw)
  }

  function settingsLoadFailed(error) {
    settingsReloadPending = false
    settingsLoaded = true
    settingsPersisted = false
    settingsLoadState = error === FileViewError.FileNotFound ? "missing" : "invalid"
    settingsLoadError = error === FileViewError.FileNotFound ? "" : FileViewError.toString(error)
    if (showTrash) Qt.callLater(root.refreshTrash)
  }

  function settingsSaved() {
    settingsWriteError = ""
    settingsWriteState = "saved"
    modeGestureFeedbackByMonitor = ({})
    modeMenuWriteConnector = ""
    settingsLoadedText = settingsWriteText
    settingsLoadState = "loaded"
    settingsLoadError = ""
    settingsDefaultsInUse = false
    settingsPersisted = true
    reloadSettingsIfPending()
  }

  function settingsSaveFailed(error) {
    settingsWriteError = "Settings changed for this session, but could not be saved. "
      + "Retry before restarting. " + FileViewError.toString(error)
    settingsWriteState = "error"
    settingsPersisted = false
    // Every surface derives the persistence result from settingsWriteState;
    // modeGestureDisplayFor applies the menu origin when one is recorded.
    console.warn("Dock: could not save " + configPath + ":", error)
    reloadSettingsIfPending()
  }

  function reloadSettingsIfPending() {
    if (!settingsReloadPending || settingsWriteState === "saving") return
    Qt.callLater(function() {
      if (root.settingsReloadPending && root.settingsWriteState !== "saving") configFile.reload()
    })
  }

  function refreshTrash() {
    if (!TrashModel.shouldRefresh(showTrash, trashListProcess.running, settingsLoaded)) return
    trashListExitCode = -1
    trashListOutputDone = false
    trashListProcess.running = true
  }

  // A failed listing is unknown, never an empty Trash.
  function settleTrashList() {
    if (trashListExitCode < 0) return
    if (trashListExitCode === 0 && !trashListOutputDone) return
    var code = trashListExitCode
    trashListExitCode = -1
    if (code !== 0) {
      trashStateKnown = false
      return
    }
    trashItemCount = DockModel.trashItemCount(trashListOutput.text)
    trashStateKnown = true
  }

  function refreshWorkspaceCounts() {
    if (workspaceCountsProcess.running) {
      root.workspaceCountsRefreshPending = true
      return
    }
    root.workspaceCountsRefreshPending = false
    workspaceCountsProcess.running = true
  }

  function openTrash() {
    Quickshell.execDetached(["gio", "open", "trash:///"])
  }

  function emptyTrash() {
    if (!trashEmptyProcess.running) trashEmptyProcess.running = true
  }

  DockDemoWidgetRegistry { id: demoWidgetRegistry }
  DockExternalWidgetRegistry {
    id: externalWidgetRegistry
    dataRoot: root.dataRoot
  }

  DockControl {
    id: dockControl
    host: root
  }

  DockScopeRefreshController {
    id: scopeRefreshController
    toplevelModel: Hyprland.toplevels
    monitorModel: Hyprland.monitors
    workspaceModel: Hyprland.workspaces
    refreshSource: Hyprland
  }

  onShowTrashChanged: {
    if (!settingsLoaded || !showTrash) return
    trashStateKnown = false
    Qt.callLater(root.refreshTrash)
  }

  Component.onCompleted: {
    refreshWorkspaceCounts()
    refreshHerdrBinaryAvailability()
    refreshT3BinaryAvailability()
    scopeRefreshController.requestRefresh()
  }

  Timer {
    interval: 3000
    repeat: true
    // The Trash item exists only in the classic dock.
    running: root.settingsLoaded && root.showTrash
      && root.presentation.classicScreens.length > 0
    triggeredOnStart: true
    onTriggered: root.refreshTrash()
  }

  Timer {
    id: workspaceCountsRefreshTimer
    interval: 100
    repeat: false
    onTriggered: root.refreshWorkspaceCounts()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? event.name : ""
      if (DockModel.shouldRefreshWorkspaceState(name)) workspaceCountsRefreshTimer.restart()
      if (DockWindowModel.shouldRefreshWindowScope(name)) scopeRefreshController.requestRefresh()
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      scopeRefreshController.invalidate()
      scopeRefreshController.requestRefresh()
    }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() {
      workspaceCountsRefreshTimer.restart()
    }
  }

  Process {
    id: herdrBinaryProbe
    command: ["sh", "-c", "command -v herdr >/dev/null 2>&1"]
    onExited: function(exitCode) {
      herdrBinaryProbeTimeout.stop()
      if (!root.herdrBinaryProbePending) return
      root.herdrBinaryProbePending = false
      root.herdrBinaryInstalled = exitCode === 0
    }
  }

  Timer {
    id: herdrBinaryProbeTimeout
    interval: 1500
    repeat: false
    onTriggered: {
      if (!root.herdrBinaryProbePending) return
      root.herdrBinaryProbePending = false
      root.herdrBinaryInstalled = false
      if (herdrBinaryProbe.running) herdrBinaryProbe.running = false
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refreshHerdrBinaryAvailability()
  }

  Process {
    id: t3BinaryProbe
    command: ["sh", "-c", "command -v t3 >/dev/null 2>&1"]
    onExited: function(exitCode) {
      t3BinaryProbeTimeout.stop()
      if (!root.t3BinaryProbePending) return
      root.t3BinaryProbePending = false
      root.t3BinaryInstalled = exitCode === 0
    }
  }

  Timer {
    id: t3BinaryProbeTimeout
    interval: 1500
    repeat: false
    onTriggered: {
      if (!root.t3BinaryProbePending) return
      root.t3BinaryProbePending = false
      root.t3BinaryInstalled = false
      if (t3BinaryProbe.running) t3BinaryProbe.running = false
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refreshT3BinaryAvailability()
  }

  Process {
    id: workspaceCountsProcess
    command: ["hyprctl", "workspaces", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var counts = DockModel.parseWorkspaceWindowCounts(text)
        if (counts) {
          root.workspaceWindowCounts = counts
          root.workspaceCountsReady = true
          root.workspaceCountsRevision++
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("Dock: could not read workspace counts (hyprctl exited " + exitCode + ")")
      if (root.workspaceCountsRefreshPending) Qt.callLater(root.refreshWorkspaceCounts)
    }
  }

  Process {
    id: trashListProcess
    command: ["gio", "trash", "--list"]
    stdout: StdioCollector {
      id: trashListOutput
      waitForEnd: true
      onStreamFinished: {
        root.trashListOutputDone = true
        root.settleTrashList()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("Dock: could not inspect Trash (gio exited " + exitCode + ")")
      root.trashListExitCode = exitCode
      root.settleTrashList()
    }
  }

  Process {
    id: trashEmptyProcess
    command: ["gio", "trash", "--empty"]
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("Dock: could not empty Trash (gio exited " + exitCode + ")")
      root.refreshTrash()
    }
  }

  FileView {
    id: configFile
    readonly property string cachedText: text()
    path: root.configPath
    watchChanges: true
    printErrors: false
    blockWrites: true
    atomicWrites: true
    onLoaded: root.settingsFileLoaded(text())
    onLoadFailed: error => root.settingsLoadFailed(error)
    onFileChanged: {
      root.settingsReloadPending = true
      root.reloadSettingsIfPending()
    }
    onSaved: root.settingsSaved()
    onSaveFailed: error => root.settingsSaveFailed(error)
  }

  // Custom icons are referenced in place; editing a referenced PNG/SVG
  // refreshes the renderer without a CLI reload or any settings write.
  DockIconReloadScheduler {
    id: iconReloadScheduler
    iconOverrides: root.settings.iconOverrides
    windowIconOverrides: root.settings.windowIconOverrides
    onReloadRequested: root.iconReloadRevision++
  }

  Instantiator {
    model: iconReloadScheduler.watchedPaths
    delegate: FileView {
      required property string modelData
      path: modelData
      // Watch only: never read image bytes. Deletes, rename-saves and files
      // that appear later all report fileChanged.
      preload: false
      watchChanges: true
      printErrors: false
      onFileChanged: iconReloadScheduler.noteFileChanged()
    }
  }

  DockWindowActions {
    id: windowActionsController
    applicationMutationController: root
  }

  DockHerdrWindowAgents {
    id: herdrWindowAgentsController
    herdrService: agentSourceMux
    toplevels: root.desktopToplevels
    hyprToplevels: root.hyprToplevels
    focusedToplevel: ToplevelManager.activeToplevel
    scopeRevision: root.scopeRevision
    // Claude has no sidebar Widget lease, so its setting keeps the bridge active for the sidebar too.
    dockConsumerActive: ((DockModel.normalizeSetting("dockHerdrIndicators", root.settings.dockHerdrIndicators)
        || DockModel.normalizeSetting("dockT3Indicators", root.settings.dockT3Indicators))
      && root.presentation.classicScreens.length > 0)
      || root.claudeSourceWanted
  }

  DockAgentSourceMux {
    id: agentSourceMux
    sources: [
      { id: "herdr", service: root.herdrService, enabled: root.herdrSourceWanted && !!root.herdrService },
      { id: "t3", service: root.t3Service, enabled: root.t3SourceWanted && !!root.t3Service },
      { id: "claude", service: root.claudeService, enabled: root.claudeSourceWanted && !!root.claudeService }
    ]
  }

  DockHerdrAgentActions {
    id: herdrAgentActionsController
    bridge: root.herdrWindowAgents
    windowActions: root.windowActions
    herdrService: agentSourceMux
  }

  DockWorkspaceMonitorDrag {
    id: workspaceMonitorDragController
    windowActions: root.windowActions
  }

  DockBadgeTracker {
    id: badgeTrackerController
    notificationService: root.notificationService
    launcherBadgeService: root.launcherBadgeService
    browserProfileService: root.browserProfileService
    browserActivityMutedServices: DockModel.normalizeSetting(
      "browserActivityMutedServices", root.settings.browserActivityMutedServices)
    launcherBadgeMode: root.settings.launcherBadgeMode === "dots-only" ? "dots-only" : "automatic"
  }

  Component { id: herdrExpandedView; DockHerdrAgentsView { sourceFilter: "herdr" } }
  Component { id: herdrCompactView; DockHerdrAgentsView { sourceFilter: "herdr" } }
  Component { id: herdrPopupView; DockHerdrAgentsView { sourceFilter: "herdr" } }
  Component { id: t3ExpandedView; DockHerdrAgentsView { sourceFilter: "t3" } }
  Component { id: t3CompactView; DockHerdrAgentsView { sourceFilter: "t3" } }
  Component { id: t3PopupView; DockHerdrAgentsView { sourceFilter: "t3" } }

  DockSidebarController {
    id: sidebarState
    widgetRegistry: root.sidebarWidgetRegistry
    host: root
    settings: root.settings
    screens: root.connectedScreens
    monitors: root.hyprMonitors
    workspaces: root.hyprWorkspaces
    applications: root.applications
    toplevels: root.desktopToplevels
    hyprToplevels: root.hyprToplevels
    minimizedOrigins: root.windowActions.minimizedOriginsSnapshot
    scopeRevision: root.scopeRevision
    focusedWorkspace: {
      var revision = root.scopeRevision
      return DockWindowModel.focusedWorkspaceIdentity(root.hyprMonitors, Hyprland.focusedWorkspace)
    }
  }

  // One stable owner per connected output. Owners exist for every screen and
  // each maps exactly one surface, so switching one screen's presentation
  // tears down and rebuilds only that screen's surface — every other output
  // keeps its renderer instance, interactions and popups untouched.
  Variants {
    id: presentationOwners
    model: root.connectedScreens
    delegate: Component {
      DockScreenPresentation {
        required property var modelData
        readonly property var resolvedEntry: ScreenPresentationModel.entryFor(
          root.presentation, modelData.name)
        connector: modelData.name
        screenObject: modelData
        presentation: root.presentation
        mode: resolvedEntry ? resolvedEntry.mode : root.presentation.defaultMode
        source: resolvedEntry ? resolvedEntry.source : "inherited"
        // Sidebar needs both the resolved mapping and live controller
        // membership (the controller defers membership changes while an
        // interaction is in flight); classic outputs always map.
        mapped: !resolvedEntry ? true : (resolvedEntry.mode === "sidebar"
          ? resolvedEntry.mapped && sidebarState.connectorIsMapped(modelData.name)
          : resolvedEntry.mapped)
        // A sidebar edge change re-anchors its layer shell: recreate only
        // sidebar surfaces, teardown-first.
        surfaceKey: mode === "sidebar"
          ? "sidebar:" + DockModel.normalizeSetting("sidebarEdge", root.settings.sidebarEdge)
          : "classic"
        surfaceComponent: mode === "sidebar" ? sidebarSurface : classicSurface
      }
    }
  }

  Component {
    id: classicSurface
    Item {
      id: classicRoot
      property var owner: null
      readonly property var panels: []
      Dock {
        host: root
        screen: classicRoot.owner ? classicRoot.owner.screenObject : null
        settings: root.settings
        iconOverrides: root.settings.iconOverrides || ({})
        iconReloadRevision: root.iconReloadRevision
        browserProfileService: root.browserProfileService
        browserProfileBadgesEnabled: root.settings.browserProfileBadgesEnabled !== false
        showTrash: root.showTrash
        windowActions: root.windowActions
        herdrWindowAgents: root.herdrWindowAgents
        herdrAgentActions: root.herdrAgentActions
        workspaceMonitorDrag: workspaceMonitorDragController
        badgeTracker: root.badgeTracker
        trashItemCount: root.trashItemCount
        trashStateKnown: root.trashStateKnown
        workspaceWindowCounts: root.workspaceWindowCounts
        workspaceCountsReady: root.workspaceCountsReady
        workspaceCountsRevision: root.workspaceCountsRevision
        scopeRevision: root.scopeRevision
        presentationMode: classicRoot.owner ? classicRoot.owner.mode : "classic"
        modeGestureFeedback: classicRoot.owner
          ? root.modeGestureDisplayFor(classicRoot.owner.connector) : ""
        modeGestureToken: classicRoot.owner ? classicRoot.owner.gestureToken : null
        onReorderRequested: (sourceDesktopId, targetDesktopId) => root.reorderPinned(sourceDesktopId, targetDesktopId)
        onPinRequested: desktopId => root.pinApplication(desktopId)
        onUnpinRequested: desktopId => root.unpinApplication(desktopId)
        onHideRequested: desktopId => root.hideApplication(desktopId)
        onBrowserActivityMuteToggled: serviceId => root.toggleBrowserActivityMute(serviceId)
        onAutoHideRequested: enabled => root.saveSetting("autoHide", enabled)
        onSettingsRequested: anchor => root.openSettings(anchor,
          classicRoot.owner ? classicRoot.owner.connector : "")
        onPositionRequested: (position, expectedPosition, gestureToken) =>
          root.handlePositionRequest(classicRoot.owner ? classicRoot.owner.connector : "",
            position, expectedPosition, gestureToken)
        onMenuModeSwitchRequested: token =>
          root.commitMonitorModeMenu(classicRoot.owner ? classicRoot.owner.connector : "",
            "sidebar", token)
        onOpenTrashRequested: root.openTrash()
        onEmptyTrashRequested: root.emptyTrash()
      }
    }
  }

  Component {
    id: sidebarSurface
    Item {
      id: sidebarRoot
      property var owner: null
      readonly property var panels: dockSidebar ? [dockSidebar] : []
      DockSidebar {
        id: dockSidebar
        screen: sidebarRoot.owner ? sidebarRoot.owner.screenObject : null
        host: root
        controller: sidebarState
        presentationMode: sidebarRoot.owner ? sidebarRoot.owner.mode : "sidebar"
        modeGestureToken: sidebarRoot.owner ? sidebarRoot.owner.gestureToken : null
      }
    }
  }
}
