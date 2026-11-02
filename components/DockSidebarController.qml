import QtQuick
import "DockModel.js" as DockModel
import "DockIconModel.js" as DockIconModel
import "DockWindowModel.js" as WindowModel
import "DockDesktopModel.js" as DesktopModel
import "DockSidebarModel.js" as SidebarModel
import "DockScreenPresentationModel.js" as ScreenPresentationModel
import "DockSidebarInteractionModel.js" as InteractionModel
import "DockSidebarWidgetModel.js" as SidebarWidgetModel
import "DockBadgeModel.js" as BadgeModel
import "DockBrowserActivityModel.js" as ActivityModel
import "DockFullscreenModel.js" as FullscreenModel

// Host-owned session/view state. All compositor data and action/writer services
// are injected. Widget leases belong to this host session, never to a view.
// This object adds no compositor watcher, notification daemon or config writer.
Item {
  id: root
  required property var host
  property var settings: ({})
  property var screens: []
  property var monitors: []
  property var workspaces: []
  property var applications: []
  property var toplevels: []
  property var hyprToplevels: []
  property var minimizedOrigins: ({})
  property string focusedWorkspace: ""
  property int scopeRevision: 0
  readonly property var windowActions: host ? host.windowActions || null : null
  readonly property var herdrWindowAgents: host ? host.herdrWindowAgents || null : null
  readonly property var herdrAgentActions: host ? host.herdrAgentActions || null : null
  readonly property var windowIconOverrides: DockIconModel.normalizeWindowRules(
    settings.windowIconOverrides || [])
  property var dragSession: null
  property var dragTarget: null
  property var dragRejection: null
  // R1 proposed policy, provisional until the owner accepts Task 4 for merge.
  // Internal guard, not a persisted setting; Ctrl-click policy is unchanged.
  property bool headerDropWithinMonitor: true
  // Session-local correlation only; no watcher, settings writer or polling.
  property double dropToken: 0
  property double dropSurfaceSerial: 0
  property var dropSurfaces: ({})
  property var dropOperation: null
  property int dropTimeoutMs: 1500
  property var dropClock: function() { return Date.now() }

  property var focusReturnTarget: null
  readonly property bool rowDragActive: dragSession !== null
  property bool interactionBusy: false
  property bool refreshPending: false
  property bool initialized: false
  // Mirrored panels: empty sidebarMonitor maps every connected screen; a set
  // connector maps only that output. selectedScreen is the primary (first mapped).
  property var mappedScreens: []
  property var selectedScreen: null
  readonly property string selectedConnector: selectedScreen ? selectedScreen.name : ""
  readonly property string edge: DockModel.normalizeSetting("sidebarEdge", settings.sidebarEdge)
  // Explicit monitor pin, watched so a change can cancel in-flight gestures:
  // selectScreens preserves the previous mapping while an interaction is busy,
  // so refreshBody alone cannot see that the host mapping moved underneath a
  // captured gesture.
  readonly property string sidebarMonitorPin: DockModel.normalizeSetting(
    "sidebarMonitor", settings.sidebarMonitor)
  readonly property bool collapsed: DockModel.normalizeSetting("sidebarCollapsed", settings.sidebarCollapsed)
  readonly property var collapsedByMonitor: DockModel.normalizeSetting(
    "sidebarCollapsedByMonitor", settings.sidebarCollapsedByMonitor)
  readonly property var persistentGeometry: SidebarModel.screenGeometry(selectedScreen,
    settings.sidebarExpandedWidth, collapsedFor(selectedScreen))
  property bool resizeActive: false
  property real resizeStartGlobalX: 0
  property int resizeStartWidth: 0
  property int resizePreviewWidth: 0
  property var resizeExpectedWidthAtStart: undefined
  property var resizeExpectedCollapseAtStart: undefined
  property string resizeEdgeAtStart: "left"
  property string resizeConnectorAtStart: ""
  property var resizeScreenAtStart: null
  readonly property var geometry: geometryFor(selectedScreen)
  // Source-registered factories only. Tests inject a registry here, never through
  // settings/CLI. Production DockHost supplies its own (initially empty) registry.
  property var widgetRegistry: ({})
  property var widgetManager: null
  property var widgetIds: []
  property int widgetRevision: 0
  property string widgetPopupId: ""
  property Item widgetPopupAnchor: null
  property string widgetDragId: ""
  readonly property bool widgetReorderActive: widgetDragId !== ""
  // Widget work follows actual sidebar membership, never the global default:
  // in a mixed layout only the outputs showing a sidebar may lease widgets.
  readonly property bool widgetWorkActive: mappedScreens.length > 0
  readonly property var widgetCollapsed: SidebarWidgetModel.collapsedMap(
    settings.sidebarWidgetCollapsed)
  // Compatibility/readback aliases. The host bridge owns the mutable state.
  readonly property int windowProcessRevision: herdrWindowAgents
    ? herdrWindowAgents.windowProcessRevision : 0
  readonly property string herdrAssociationEpoch: herdrWindowAgents
    ? herdrWindowAgents.herdrAssociationEpoch : ""
  readonly property var herdrAssociations: sidebarHerdrAssociations()
  property bool projecting: false

  // Map override when present; otherwise the global sidebarCollapsed default.
  // The lookup is shared with the classic dock's destination preview so both
  // resolve the same collapsed width.
  function collapsedFor(screen) {
    var name = screen && screen.name ? String(screen.name) : ""
    return DockModel.sidebarCollapsedForScreen(
      root.collapsedByMonitor, root.collapsed, name)
  }

  // Shared expanded-width preference, clamped per output so each panel fits its screen.
  function geometryFor(screen) {
    if (root.resizeActive)
      return SidebarModel.screenGeometry(screen, root.resizePreviewWidth, root.collapsedFor(screen))
    return SidebarModel.screenGeometry(screen, root.settings.sidebarExpandedWidth,
      root.collapsedFor(screen))
  }
  property var registry: ({ nextToken: 1, entries: [] })
  property var folds: ({})
  property var projection: SidebarModel.emptyProjection()
  property var railProjection: SidebarModel.emptyProjection()
  // Session-only scroll memory keyed by connector × expanded|rail. Not config.
  property var scrollStates: ({})
  property string focusedRowKey: ""
  property string mutationFeedback: ""
  // Intra-row keyboard focus for the browser-tab mute (eye) control.
  property string alertControlKey: ""
  readonly property var rowsByKey: SidebarModel.indexRowsByKey(projection, railProjection)
  signal aboutToRefresh()
  signal refreshed()
  signal surfaceInvalidated()
  signal widgetAnchorChanged()
  signal pinPickerRequested(var anchor)

  function projectionFor(collapsed) {
    return collapsed ? root.railProjection : root.projection
  }

  function readScrollState(connector, collapsed) {
    return SidebarModel.readScrollState(root.scrollStates, connector, collapsed)
  }

  function writeScrollState(connector, collapsed, anchor, keys) {
    root.scrollStates = SidebarModel.writeScrollState(
      root.scrollStates, connector, collapsed, anchor, keys)
  }

  function requestPinPicker(anchor) {
    root.pinPickerRequested(anchor || null)
  }

  function widgetView(id) {
    var revision = root.widgetRevision
    return root.widgetManager ? root.widgetManager.view(id) : null
  }

  function widgetCollapsedFor(id) {
    return root.widgetCollapsed && root.widgetCollapsed[id] === true
  }

  function widgetMutationFailure(code, message) {
    root.mutationFeedback = message
    return {accepted:false,pending:false,
      reply:{ok:false,error:{code:code,message:message},data:{applied:false}}}
  }

  function setWidgetEnabled(id, enabled) {
    var ids = SidebarWidgetModel.requestedIds(root.settings.sidebarWidgets)
    var index = ids.indexOf(id)
    if (enabled === true) {
      if (index >= 0) return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,changedKeys:[]},warnings:[]}}
      if (SidebarWidgetModel.descriptorFor(root.widgetRegistry, id) === null)
        return root.widgetMutationFailure("E_VALIDATION", "Widget is not source-registered: " + id)
      ids.push(id)
    } else {
      if (index < 0) return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,changedKeys:[]},warnings:[]}}
      ids.splice(index, 1)
      if (root.widgetPopupId === id) root.closeWidgetPopup()
    }
    var result = root.hostIntent("sidebarWidgets", ids, root.settings.sidebarWidgets)
    root.mutationFeedback = result.accepted ? ""
      : String(result.reply && result.reply.error && result.reply.error.message
        || "Widget preference was not accepted.")
    return result
  }

  // targetSlot is an insertion boundary in the original ordered list [0..length].
  function reorderWidget(id, targetSlot) {
    var ids = SidebarWidgetModel.requestedIds(root.settings.sidebarWidgets)
    var from = ids.indexOf(id)
    if (from < 0) return root.widgetMutationFailure("E_STATE", "Widget is no longer enabled.")
    var numeric = Number(targetSlot)
    var slot = isFinite(numeric) ? Math.max(0, Math.min(ids.length, Math.floor(numeric))) : from
    // Dropping on either side of the source's own occupied slot is a no-op.
    if (slot === from || slot === from + 1)
      return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,changedKeys:[]},warnings:[]}}
    ids.splice(from, 1)
    if (slot > from) slot--
    slot = Math.max(0, Math.min(ids.length, slot))
    ids.splice(slot, 0, id)
    var result = root.hostIntent("sidebarWidgets", ids, root.settings.sidebarWidgets)
    root.mutationFeedback = result.accepted ? ""
      : String(result.reply && result.reply.error && result.reply.error.message
        || "Widget order was not accepted.")
    return result
  }

  function setWidgetCollapsed(id, collapsed) {
    if (!SidebarWidgetModel.validId(id) || typeof collapsed !== "boolean")
      return root.widgetMutationFailure("E_VALIDATION", "Invalid widget collapse preference.")
    var expected = root.settings.sidebarWidgetCollapsed
    var next = Object.assign({}, root.widgetCollapsed)
    if (next[id] === collapsed)
      return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,changedKeys:[]},warnings:[]}}
    next[id] = collapsed
    var result = root.hostIntent("sidebarWidgetCollapsed", next, expected)
    root.mutationFeedback = result.accepted ? ""
      : String(result.reply && result.reply.error && result.reply.error.message
        || "Widget collapse preference was not accepted.")
    return result
  }

  function toggleWidgetCollapsed(id) {
    return root.setWidgetCollapsed(id, !root.widgetCollapsedFor(id))
  }

  function beginWidgetReorder(id) {
    if (root.interactionBusy || root.resizeActive || root.rowDragActive)
      return false
    if (root.widgetIds.indexOf(id) < 0) return false
    root.closeWidgetPopup()
    root.widgetDragId = id
    root.interactionBusy = true
    return true
  }

  function finishWidgetReorder(targetSlot, cancelled) {
    var id = root.widgetDragId
    root.widgetDragId = ""
    if (!root.resizeActive && !root.rowDragActive && !root.widgetPopupId)
      root.interactionBusy = false
    if (!id || cancelled === true)
      return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,changedKeys:[]},warnings:[]}}
    return root.reorderWidget(id, targetSlot)
  }

  function cancelWidgetReorder() {
    if (!root.widgetDragId) return
    root.widgetDragId = ""
    if (!root.resizeActive && !root.rowDragActive && !root.widgetPopupId)
      root.interactionBusy = false
  }

  function widgetsChanged() {
    if (!root.initialized || !root.widgetManager) return
    var ids = root.widgetManager.ids()
    // Snapshot updates must not reset the delegate model or popup anchor.
    if (JSON.stringify(ids) !== JSON.stringify(root.widgetIds)) root.widgetIds = ids
    root.widgetRevision = (root.widgetRevision + 1) % 1000000000
    // Herdr snapshot/association changes feed nested tree rows.
    if (!root.projecting)
      root.scheduleRefresh()
    if (!root.widgetPopupId) return
    var view = root.widgetManager.view(root.widgetPopupId)
    if (!ids.length || !view || !view.registered || !view.available)
      root.closeWidgetPopup()
  }

  function syncWidgets() {
    if (!root.initialized || !root.widgetManager) return
    root.widgetManager.reconcile(root.settings.sidebarWidgets, root.widgetRegistry,
      root.widgetWorkActive, root)
    root.widgetsChanged()
  }

  function openWidgetPopup(id, anchor) {
    if (!root.widgetWorkActive || !anchor || !anchor.visible || !root.widgetIds.length) return false
    if (root.interactionBusy && !root.widgetPopupId) return false
    var view = root.widgetView(id)
    // Unknown imported IDs never execute a factory or open a provider popup.
    if (!view || !view.registered || !view.available) return false
    root.widgetPopupAnchor = anchor
    root.widgetPopupId = id
    root.interactionBusy = true
    root.widgetAnchorChanged()
    return true
  }

  function closeWidgetPopup() {
    var hadPopup = root.widgetPopupId !== ""
    root.widgetPopupId = ""
    root.widgetPopupAnchor = null
    // Clear only the popup-owned busy bit when no other interaction remains.
    if (hadPopup && !root.resizeActive && !root.rowDragActive)
      root.interactionBusy = false
  }

  function widgetViewFailed(id, expected) {
    if (root.widgetManager) root.widgetManager.viewFailed(id, expected)
  }

  Connections {
    target: root.widgetPopupAnchor
    ignoreUnknownSignals: true
    function onDestroyed() { root.closeWidgetPopup() }
    function onVisibleChanged() { if (!root.widgetPopupAnchor || !root.widgetPopupAnchor.visible) root.closeWidgetPopup() }
    function onXChanged() { root.widgetAnchorChanged() }
    function onYChanged() { root.widgetAnchorChanged() }
    function onWidthChanged() { root.widgetAnchorChanged() }
    function onHeightChanged() { root.widgetAnchorChanged() }
  }
  onWidgetPopupAnchorChanged: if (!root.widgetPopupAnchor) root.closeWidgetPopup()
  onWidgetRegistryChanged: root.syncWidgets()
  onWidgetWorkActiveChanged: {
    if (!root.widgetWorkActive) root.closeWidgetPopup()
    root.syncWidgets()
  }
  onSurfaceInvalidated: {
    root.closeWidgetPopup()
    root.cancelWidgetReorder()
  }

  function scheduleRefresh() {
    if (initialized) Qt.callLater(root.refresh)
  }

  function clearResizeState() {
    root.resizeActive = false
    root.resizeStartGlobalX = 0
    root.resizeStartWidth = 0
    root.resizePreviewWidth = 0
    root.resizeExpectedWidthAtStart = undefined
    root.resizeExpectedCollapseAtStart = undefined
    root.resizeEdgeAtStart = "left"
    root.resizeConnectorAtStart = ""
    root.resizeScreenAtStart = null
    root.interactionBusy = false
  }

  function cancelResize(reason) {
    if (!root.resizeActive) return false
    root.clearResizeState()
    root.scheduleRefresh()
    return true
  }

  function invalidateSurface() {
    root.invalidateDropOperation()
    root.cancelRowDrag("surface-invalidated")
    root.focusReturnTarget = null
    root.cancelResize("surface-invalidated")
    root.surfaceInvalidated()
    root.interactionBusy = false
    root.scheduleRefresh()
  }

  // screen is the panel output initiating the gesture; shared width still commits once.
  // Eligibility is this output's sidebar membership, so a classic output in a
  // mixed layout can never start a sidebar resize.
  function beginResize(globalX, screen) {
    var target = screen || root.selectedScreen
    if (!target || !root.connectorIsMapped(target.name) || root.collapsedFor(target)
        || !root.geometryFor(target).mapped || root.interactionBusy || root.resizeActive)
      return false
    var pointer = Number(globalX)
    if (!isFinite(pointer)) return false
    root.resizeStartGlobalX = pointer
    root.resizeStartWidth = root.geometryFor(target).expandedWidth
    root.resizePreviewWidth = root.resizeStartWidth
    // Capture the exact host values for the stale check. Effective geometry may
    // normalize compatible legacy bytes, but that must not manufacture a conflict.
    root.resizeExpectedWidthAtStart = root.settings.sidebarExpandedWidth
    root.resizeExpectedCollapseAtStart = root.collapsedFor(target)
    root.resizeEdgeAtStart = root.edge
    root.resizeConnectorAtStart = target.name || ""
    root.resizeScreenAtStart = target
    root.resizeActive = true
    root.interactionBusy = true
    root.mutationFeedback = ""
    return true
  }

  function updateResize(globalX) {
    var target = root.resizeScreenAtStart
    if (!root.resizeActive || !target
        || (target.name || "") !== root.resizeConnectorAtStart) return false
    root.resizePreviewWidth = SidebarModel.resizeWidth(root.resizeStartWidth,
      root.resizeStartGlobalX, Number(globalX), root.resizeEdgeAtStart,
      SidebarModel.logicalScreenWidth(target))
    return true
  }

  function hostIntent(key, value, expectedValue) {
    if (root.host && typeof root.host.saveSettingIntent === "function")
      return root.host.saveSettingIntent(key, value, expectedValue)
    var reply = root.host.saveSetting(key, value)
    var applied = !!(reply && reply.data && reply.data.applied === true)
    return { accepted: !!(reply && (reply.ok || applied)),
      pending: applied && !reply.ok && reply.error && reply.error.code === "E_BUSY",
      reply: reply }
  }

  function finishResize(cancelled) {
    if (!root.resizeActive)
      return {accepted:false,pending:false,reply:{ok:false,error:{code:"E_STATE",message:"No resize is active."},data:{applied:false}}}
    var finalWidth = root.resizePreviewWidth
    var startWidth = root.resizeStartWidth
    var expected = root.resizeExpectedWidthAtStart
    root.clearResizeState()
    if (cancelled === true || finalWidth === startWidth) {
      root.scheduleRefresh()
      return {accepted:true,pending:false,noop:true,
        reply:{ok:true,data:{applied:false,persisted:true,changedKeys:[]},warnings:[]}}
    }
    var result = root.hostIntent("sidebarExpandedWidth", finalWidth, expected)
    if (!result.accepted)
      root.mutationFeedback = String(result.reply && result.reply.error && result.reply.error.message
        || "Preference changed elsewhere; resize was not saved.")
    else root.mutationFeedback = ""
    root.scheduleRefresh()
    return result
  }

  function resizePreferenceConflict() {
    return root.resizeActive && (
      root.settings.sidebarExpandedWidth !== root.resizeExpectedWidthAtStart
      || root.collapsedFor(root.resizeScreenAtStart) !== root.resizeExpectedCollapseAtStart)
  }

  function refresh() {
    if (!root.initialized) return
    if (root.projecting) {
      root.refreshPending = true
      return
    }
    if (root.dragSession && !root.rowDragIsCurrent()) root.cancelRowDrag("source-or-topology-changed")
    root.projecting = true
    try {
      root.refreshBody()
    } finally {
      root.projecting = false
      root.evaluateDropOperation()
      if (root.refreshPending && !root.interactionBusy)
        Qt.callLater(root.refresh)
    }
  }

  function refreshBody() {
    if (root.dragSession && !root.rowDragIsCurrent()) root.cancelRowDrag("source-or-topology-changed")
    root.registry = SidebarModel.reconcileHandles(root.registry, root.toplevels)
    // Sidebar membership comes from the shared per-screen resolver, the same
    // pure function the host owners and CLI diagnostics use, so every surface
    // and gate agrees on which outputs actually show a sidebar.
    var presentation = ScreenPresentationModel.resolve({
      presentationMode: root.settings.presentationMode,
      presentationModeByMonitor: root.settings.presentationModeByMonitor,
      sidebarMonitor: root.settings.sidebarMonitor,
      workspaceMonitorOrder: root.settings.workspaceMonitorOrder || [],
      screens: root.screens,
      monitors: root.monitors,
      previousSidebarScreens: root.mappedScreens,
      busy: root.interactionBusy === true
    })
    var nextMapped = presentation.sidebarScreens
    var nextPrimary = nextMapped.length ? nextMapped[0] : null
    var mappedChanged = nextMapped.length !== root.mappedScreens.length
      || nextMapped.some(function(screen, index) {
        return !root.mappedScreens[index] || root.mappedScreens[index].name !== screen.name
      })
    if (mappedChanged) {
      if (root.resizeActive && root.resizeScreenAtStart
          && !nextMapped.some(function(screen) { return screen.name === root.resizeConnectorAtStart }))
        root.cancelResize("host-changed")
      // A new or removed *other* sidebar must not abort a drag on a surviving
      // panel. Its own teardown or lost membership still cancels the gesture.
      if (root.dragSession && !nextMapped.some(function(screen) {
        return screen && screen.name === root.dragSession.connector
      })) root.cancelRowDrag("host-changed")
      // Do not tear down all panels on hotplug; Variants adopts mappedScreens.
      root.mappedScreens = nextMapped
      root.selectedScreen = nextPrimary
    } else if (nextPrimary !== root.selectedScreen) {
      root.selectedScreen = nextPrimary
    }
    root.syncWidgets()
    if (root.interactionBusy && nextMapped.length) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    root.aboutToRefresh()
    var previous = SidebarModel.unionProjectionRows(root.projection, root.railProjection)
      .map(function(row) { return row.key })
    if (!nextPrimary) {
      root.projection = SidebarModel.emptyProjection()
      root.railProjection = SidebarModel.emptyProjection()
      root.refreshed()
      return
    }
    var desktop = DesktopModel.build({
      mode: "sidebar", settings: {
        pinned: root.settings.pinned || [], hiddenApplications: DockModel.normalizeSetting(
          "hiddenApplications", root.settings.hiddenApplications), workspaceGroups: [],
        workspaceMonitorScope: "all", workspaceMonitorOrder: DockModel.normalizeSetting(
          "workspaceMonitorOrder", root.settings.workspaceMonitorOrder), sortByWorkspace: false
      }, applications: root.applications, toplevels: root.toplevels,
      windowRuleMatches: root.toplevels.map(function(toplevel) {
        return DockIconModel.matchWindowRule(root.windowIconOverrides,
          toplevel ? toplevel.appId : "", toplevel ? toplevel.title : "")
      }),
      filteredToplevels: root.toplevels, hyprToplevels: root.hyprToplevels,
      hyprWorkspaces: root.workspaces, hyprMonitors: root.monitors,
      dockMonitor: WindowModel.monitorForScreen(nextPrimary, root.monitors),
      minimizedOrigins: root.minimizedOrigins, focusedWorkspace: root.focusedWorkspace
    })
    var browserTabs = (function() {
      var service = root.host ? root.host.browserProfileService : null
      var revision = service ? service.revision : 0
      if (!service || !service.available) return ({})
      return service.tabs || ({})
    })()
    var herdrView = root.widgetView("herdr.agents")
    var t3View = root.widgetView("t3.threads")
    var herdrSnapshot = root.herdrWindowAgents && root.herdrWindowAgents.snapshotReady
      ? root.herdrWindowAgents.snapshot : null
    var ready = !!(root.herdrWindowAgents && root.herdrWindowAgents.snapshotReady)
    var herdrActive = !!herdrView && herdrView.active
    var t3Active = !!t3View && t3View.active
    var claudeOn = DockModel.normalizeSetting("dockClaudeIndicators", root.settings.dockClaudeIndicators)
    var herdrVerified = ready && (herdrActive || t3Active || claudeOn)
    var verifiedSources = { herdr: ready && herdrActive, t3: ready && t3Active,
                            t3Present: t3Active, claude: ready && claudeOn,
                            claudePresent: claudeOn }
    var projectInput = {
      desktop: desktop, screens: root.screens,
      monitors: root.monitors, monitorOrder: root.settings.workspaceMonitorOrder || [],
      pinned: root.settings.pinned || [],
      hiddenApplications: DockModel.normalizeSetting("hiddenApplications",
        root.settings.hiddenApplications),
      registry: root.registry,
      folds: root.folds,
      sidebarBrowserTabsEnabled: DockModel.normalizeSetting(
        "sidebarBrowserTabsEnabled", root.settings.sidebarBrowserTabsEnabled),
      sidebarInlineSoloWorkspace: DockModel.normalizeSetting(
        "sidebarInlineSoloWorkspace", root.settings.sidebarInlineSoloWorkspace),
      browserTabs: browserTabs,
      herdrSnapshot: herdrSnapshot,
      herdrAssociations: root.herdrAssociations,
      herdrAssociationsVerified: herdrVerified,
      herdrVerifiedSources: verifiedSources
    }
    var projected = SidebarModel.project(Object.assign({}, projectInput, { collapsed: false }))
    var railProjected = SidebarModel.project(Object.assign({}, projectInput, { collapsed: true }))
    var nextRows = SidebarModel.unionProjectionRows(projected, railProjected)
    // Scroll anchors are per connector×mode; viewports capture/restore via scrollStates.
    if (root.focusedRowKey) root.focusedRowKey = SidebarModel.recoverAnchor(
      {key:root.focusedRowKey,offset:0}, previous, nextRows).key
    // Prune vanished application and browser-tab folds from the filtered
    // projection. Herdr folds follow live registry window keys so hiding an
    // application cannot erase fold memory for a still-live window.
    var liveFolds = Object.create(null)
    projected.monitorSections.forEach(function(m) {
      m.workspaces.forEach(function(w) {
        w.applications.forEach(function(a) {
          if (root.folds[a.key]) liveFolds[a.key] = true
          a.windows.forEach(function(window) {
            var tabsKey = window.tabsKey || ("tabs:" + window.key)
            if (root.folds[tabsKey]) liveFolds[tabsKey] = true
          })
        })
      })
    })
    projected.unassignedWindows.forEach(function(window) {
      var tabsKey = window.tabsKey || ("tabs:" + window.key)
      if (root.folds[tabsKey]) liveFolds[tabsKey] = true
    })
    var entries = (root.registry && root.registry.entries) ? root.registry.entries : []
    for (var ei = 0; ei < entries.length; ei++) {
      var entry = entries[ei]
      if (!entry || typeof entry.key !== "string" || !entry.key) continue
      var herdrKey = "herdr:" + entry.key
      if (root.folds[herdrKey]) liveFolds[herdrKey] = true
    }
    root.folds = liveFolds
    root.projection = projected
    root.railProjection = railProjected
    root.refreshed()
  }

  // SidebarModel keeps its own registry keys. Translate the host bridge's
  // toplevel-lifetime keys without changing the projection contract.
  function sidebarHerdrAssociations() {
    var bridge = root.herdrWindowAgents
    var source = bridge && bridge.herdrAssociations
      ? bridge.herdrAssociations : ({ byWindowKey: ({}), unmatchedServerIds: [] })
    var byWindowKey = ({})
    var entries = root.registry && root.registry.entries ? root.registry.entries : []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.key || !entry.toplevel || !bridge) continue
      var bridgeKey = bridge.windowKeyFor(entry.toplevel)
      if (bridgeKey && source.byWindowKey[bridgeKey])
        byWindowKey[entry.key] = source.byWindowKey[bridgeKey]
    }
    return ({ byWindowKey: byWindowKey,
      unmatchedServerIds: source.unmatchedServerIds || [] })
  }

  // Captured on pointer press/menu open, not looked up by title/index on release.
  function captureTarget(key) {
    var row = root.rowsByKey[key]
    if (!row || !root.windowActions) return null
    var target = {key:row.key, kind:row.kind, desktopId:row.desktopId || "",
      workspaceIdentity:row.workspaceIdentity || "", monitorIdentity:row.monitorIdentity || ""}
    if (row.kind === "window") {
      var entry = SidebarModel.handleEntry(root.registry, row.toplevel)
      if (!entry || entry.key !== key || !root.windowActions.isAlive(row.toplevel)) return null
      target.toplevel = row.toplevel
      target.address = String(root.windowActions.addressFor(row.toplevel) || "")
    } else if (row.kind === "browser-tab") {
      var tabEntry = SidebarModel.handleEntry(root.registry, row.toplevel)
      if (!tabEntry || !root.windowActions.isAlive(row.toplevel)) return null
      target.toplevel = row.toplevel
      target.address = String(row.address || root.windowActions.addressFor(row.toplevel) || "")
      target.targetId = String(row.targetId || "")
      target.windowAddress = String(row.windowAddress || "").toLowerCase()
      target.windowKey = String(row.windowKey || "")
    } else if (row.kind === "herdr-agent") {
      return root.herdrAgentActions
        ? root.herdrAgentActions.captureAgentTarget(row.toplevel, row) : null
    } else if (row.kind === "workspace") {
      var destination = root.windowActions.resolveWorkspaceDropTarget(target.workspaceIdentity)
      if (!destination) return null
      target.monitorIdentity = destination.monitor
    } else if (row.kind !== "application" && row.kind !== "launcher") return null
    return target
  }

  function herdrFocusErrorFor(key) {
    return root.herdrAgentActions ? root.herdrAgentActions.focusErrorFor(key) : ""
  }

  function targetIsCurrent(target) {
    if (target && (target.kind === "herdr-agent"))
      return !!root.herdrAgentActions && root.herdrAgentActions.targetIsCurrent(target)
    if (!target || !root.windowActions || !root.mappedScreens.length) return false
    var row = root.rowsByKey[target.key]
    if (target.desktopId && DockModel.normalizeSetting("hiddenApplications", root.settings.hiddenApplications)
        .map(DockModel.normalizedId).indexOf(DockModel.normalizedId(target.desktopId)) >= 0) return false
    if (!row || row.kind !== target.kind) return false
    if (target.kind === "window") {
      var entry = SidebarModel.handleEntry(root.registry, target.toplevel)
      return !!entry && entry.key === target.key && row.toplevel === target.toplevel
        && root.windowActions.isAlive(target.toplevel)
        && String(root.windowActions.addressFor(target.toplevel) || "") === target.address
    }
    if (target.kind === "browser-tab") {
      return row.targetId === target.targetId
        && row.windowKey === target.windowKey
        && root.windowActions.isAlive(target.toplevel)
        && String(row.windowAddress || "").toLowerCase() === target.windowAddress
    }
    if (target.kind === "workspace") {
      var current = root.windowActions.resolveWorkspaceDropTarget(target.workspaceIdentity)
      return !!current && current.monitor === target.monitorIdentity
        && row.workspaceIdentity === target.workspaceIdentity
    }
    return row.desktopId === target.desktopId
  }

  // True when connector names a currently mapped sidebar panel output.
  function connectorIsMapped(name) {
    var connector = String(name || "")
    if (!connector) return false
    return (root.mappedScreens || []).some(function(screen) {
      return screen && screen.name === connector
    })
  }

  function activateTarget(target, control, clickedConnector, modifiers) {
    if (root.interactionBusy || !root.targetIsCurrent(target)) return false
    var accepted = false
    if (target.kind === "herdr-agent") {
      if (control === true) return false
      if (Number(modifiers || 0) !== Number(Qt.NoModifier)) return false
      return root.herdrAgentActions
        ? root.herdrAgentActions.activateHerdrTarget(target) : false
    }
    if (target.kind === "window") {
      // FDM-954's deliberate Ctrl route. Missing/untrusted modifier state cannot
      // authorize a move; no frozen workspace override and no focus-derived monitor.
      // Accept any currently mapped panel connector (mirrored surfaces), not only
      // the primary selectedScreen.
      var monitor = control === true ? String(clickedConnector || "") : ""
      if (control === true && !root.connectorIsMapped(monitor)) return false
      if (control === true) {
        monitor = root.windowActions.canonicalMonitorIdentity(monitor)
        if (!monitor) return false
        accepted = root.windowActions.pullToplevelToMonitorWorkspace(target.toplevel, true, monitor)
      } else {
        accepted = root.windowActions.activateToplevel(target.toplevel, true, monitor, true)
      }
    } else if (target.kind === "browser-tab") {
      accepted = root.activateBrowserTab(target)
    } else if (target.kind === "workspace") {
      if (control === true) {
        var workspaceMonitor = String(clickedConnector || "")
        if (!root.connectorIsMapped(workspaceMonitor)) return false
        workspaceMonitor = root.windowActions.canonicalMonitorIdentity(workspaceMonitor)
        if (!workspaceMonitor) return false
        var workspaceTarget = root.windowActions.workspaceCommandTarget(target.workspaceIdentity)
        if (!workspaceTarget) return false
        accepted = root.windowActions.dispatchRequests(root.windowActions.workspaceOnMonitorRequests(workspaceTarget, workspaceMonitor))
      } else {
        accepted = root.windowActions.focusWorkspaceInPlace(target.workspaceIdentity)
      }
    } else if (target.kind === "application") {
      return root.toggleApplication(target.key)
    } else if (target.kind === "launcher") {
      var row = root.rowsByKey[target.key]
      if (!row) return false
      // Focus-or-launch: prefer strip-attached windows, then hierarchy windows
      // with the same desktop id (covers catalog/id alias mismatches).
      var wins = (row.windows && row.windows.length) ? row.windows : []
      if (!wins.length) {
        var want = DockModel.normalizedId(row.desktopId || target.desktopId)
        var projectedRows = (root.projection && root.projection.rows) || []
        wins = projectedRows.filter(function(candidate) {
          return candidate && candidate.kind === "window"
            && DockModel.normalizedId(candidate.desktopId) === want
        })
      }
      if (wins.length) {
        var focus = wins[0]
        for (var i = 0; i < wins.length; ++i) {
          if (wins[i] && wins[i].toplevel && wins[i].toplevel.activated === true) {
            focus = wins[i]
            break
          }
        }
        if (focus && focus.urgent) {
          for (var u = 0; u < wins.length; ++u) {
            if (wins[u] && wins[u].urgent) { focus = wins[u]; break }
          }
        }
        if (focus && focus.toplevel)
          accepted = root.windowActions.activateToplevel(focus.toplevel, true, "", true)
      } else {
        var entry = row.item ? row.item.entry : null
        if (entry && typeof entry.execute === "function") { entry.execute(); accepted = true }
      }
    }
    if (accepted) root.focusReturnTarget = null
    return accepted
  }

  function rememberNavigationFocus() {
    if (root.focusReturnTarget || !root.windowActions) return
    var active = root.windowActions.activeToplevel
    if (root.windowActions.isAlive(active)) root.focusReturnTarget = {
      toplevel:active, address:String(root.windowActions.addressFor(active) || "")}
  }

  function releaseNavigationFocus() {
    root.clearAlertControl()
    var target = root.focusReturnTarget
    root.focusReturnTarget = null
    if (!target || !root.windowActions || !root.windowActions.isAlive(target.toplevel)
        || String(root.windowActions.addressFor(target.toplevel) || "") !== target.address) return false
    return root.windowActions.activateToplevel(target.toplevel, true, "", true)
  }

  function topologyStamp() {
    return JSON.stringify((root.monitors || []).map(function(m) {
      var ipc = m.lastIpcObject || m
      return [ipc.id, ipc.name, ipc.x, ipc.y, ipc.width, ipc.height, ipc.scale]
    }).concat((root.screens || []).map(function(s) {
      return [s.name, s.x, s.y, s.width, s.height]
    })))
  }

  function dragSourceLocation(target) {
    if (!root.targetIsCurrent(target)) return null
    if (target.kind === "workspace")
      return root.windowActions.resolveWorkspaceDropTarget(target.workspaceIdentity)
    if (target.kind !== "window" || !target.address) return null
    var location = root.windowActions.workspaceMoveLocation(target.toplevel, target.address)
    if (!location) return null
    var identity = root.windowActions.canonicalWorkspaceIdentity(location.workspace)
    var owner = root.windowActions.resolveWorkspaceDropTarget(identity)
    if (!owner) return null
    return {identity:identity, monitor:owner.monitor, minimized:location.minimized === true}
  }

  function registerDropSurface(connector) {
    var generation = ++root.dropSurfaceSerial
    var surfaces = Object.assign({}, root.dropSurfaces)
    surfaces[generation] = String(connector || "")
    root.dropSurfaces = surfaces
    return generation
  }

  function releaseDropSurface(generation) {
    var surfaces = Object.assign({}, root.dropSurfaces)
    delete surfaces[generation]
    root.dropSurfaces = surfaces
    if (root.dropOperation && root.dropOperation.originSurfaceGeneration === generation)
      root.invalidateDropOperation()
    if (root.dragSession && root.dragSession.originSurfaceGeneration === generation)
      root.cancelRowDrag("surface-invalidated")
  }

  function invalidateDropOperation() {
    dropDeadlineTimer.stop()
    root.dropToken = (Number(root.dropToken) || 0) + 1
    root.dropOperation = null
  }

  function endDropOperation(token) {
    if (token !== root.dropToken) return
    root.invalidateDropOperation()
  }

  function dropOriginIsCurrent(operation) {
    return !!operation && root.initialized && operation.token === root.dropToken
      && root.connectorIsMapped(operation.originConnector)
      && operation.originSurfaceGeneration > 0
      && root.dropSurfaces[operation.originSurfaceGeneration] === operation.originConnector
      && operation.topology === root.topologyStamp()
  }

  function dropEntityAlive(operation) {
    if (operation.sourceKind === "workspace") return true
    return WindowModel.handleForToplevel(operation.toplevel, root.hyprToplevels) === operation.hyprHandle
      && root.windowActions.isAlive(operation.toplevel)
      && DockModel.normalizeWindowAddress(root.windowActions.addressFor(operation.toplevel)) === operation.address
  }

  // A full location predicate, never a dispatch acknowledgment. For windows,
  // both the IPC monitor and workspace inventory owner must agree; conflicting
  // handles/readbacks remain unknown. Minimized storage is not a destination.
  function dropLocationMatches(operation) {
    if (!root.dropEntityAlive(operation)) return false
    var owner = root.windowActions.resolveWorkspaceDropTarget(operation.expectedWorkspace)
    if (!owner || owner.monitor !== operation.expectedMonitor) return false
    if (operation.sourceKind === "workspace") return true
    var location = root.windowActions.workspaceMoveLocation(operation.toplevel, operation.address)
    if (!location || location.minimized
        || root.windowActions.canonicalWorkspaceIdentity(location.workspace) !== operation.expectedWorkspace
        || root.windowActions.canonicalMonitorIdentity(location.monitor) !== operation.expectedMonitor) return false
    var handles = root.hyprToplevels || []
    var observed = false
    for (var i = 0; i < handles.length; ++i) {
      var handle = handles[i]
      if (!handle || handle.wayland !== operation.toplevel) continue
      var ipc = handle.lastIpcObject || ({})
      if (DockModel.normalizeWindowAddress(handle.address || ipc.address) !== operation.address
          || root.windowActions.canonicalWorkspaceIdentity(WindowModel.workspaceIdentity(ipc.workspace)) !== operation.expectedWorkspace
          || root.windowActions.canonicalMonitorIdentity(ipc.monitor) !== operation.expectedMonitor) return false
      observed = true
    }
    return observed
  }

  function dropSourceIsCurrent(operation) {
    if (!root.dropOriginIsCurrent(operation) || !root.dropEntityAlive(operation)) return false
    var owner = root.windowActions.resolveWorkspaceDropTarget(operation.sourceWorkspace)
    if (!owner || owner.monitor !== operation.sourceMonitor) return false
    if (operation.sourceKind === "workspace") return true
    var location = root.windowActions.workspaceMoveLocation(operation.toplevel, operation.address)
    return !!location && root.windowActions.canonicalWorkspaceIdentity(location.workspace) === operation.sourceWorkspace
      && root.windowActions.canonicalMonitorIdentity(location.monitor) === operation.sourceMonitor
      && (location.minimized === true) === operation.sourceMinimized
  }

  function makeDropOperation(session, destination) {
    root.invalidateDropOperation()
    var operation = {token:root.dropToken, sourceKind:session.target.kind,
      sourceKey:session.target.key, sourceWorkspace:session.location.identity,
      sourceMonitor:session.location.monitor, sourceMinimized:session.location.minimized === true,
      expectedWorkspace:destination ? destination.identity || "" : "",
      expectedMonitor:destination ? destination.monitor || "" : "",
      originConnector:session.connector,
      originSurfaceGeneration:session.originSurfaceGeneration || 0,
      topology:session.topology, deadline:Number(root.dropClock()) + Math.max(1, root.dropTimeoutMs),
      state:"submitting"}
    if (session.target.kind === "window") {
      operation.toplevel = session.target.toplevel
      operation.hyprHandle = WindowModel.handleForToplevel(session.target.toplevel, root.hyprToplevels)
      operation.address = DockModel.normalizeWindowAddress(session.target.address)
    }
    // Keeping a submitting record makes synchronous surface invalidation final.
    if (root.dropOriginIsCurrent(operation)) root.dropOperation = operation
    return operation
  }

  function evaluateDropOperation() {
    var operation = root.dropOperation
    if (!operation) return
    if (!root.dropOriginIsCurrent(operation) || !root.dropEntityAlive(operation)) {
      root.invalidateDropOperation()
      return
    }
    if (operation.state === "confirmed" && !root.dropLocationMatches(operation)) {
      root.invalidateDropOperation()
      return
    }
    if (operation.state !== "pending") return
    if (Number(root.dropClock()) >= operation.deadline) {
      root.expireDropOperation(operation.token)
      return
    }
    if (!root.dropLocationMatches(operation)) return
    dropDeadlineTimer.stop()
    root.dropOperation = Object.assign({}, operation, {state:"confirmed"})
  }

  function expireDropOperation(token) {
    var operation = root.dropOperation
    if (!operation || token !== operation.token || token !== root.dropToken
        || operation.state !== "pending" || Number(root.dropClock()) < operation.deadline) return
    dropDeadlineTimer.stop()
    root.dropOperation = Object.assign({}, operation, {state:"unconfirmed"})
  }

  function beginRowDrag(target, connector, surfaceGeneration) {
    if (root.interactionBusy || root.resizeActive || root.dragSession) return false
    var location = root.dragSourceLocation(target)
    var host = String(connector || root.selectedConnector || "")
    if (!location || !root.connectorIsMapped(host)) return false
    root.invalidateDropOperation()
    root.dragSession = {target:target, location:location, connector:host,
      originSurfaceGeneration:Number(surfaceGeneration) || 0, topology:root.topologyStamp()}
    root.dragTarget = null
    root.dragRejection = null
    root.interactionBusy = true
    return true
  }

  function rowDragIsCurrent() {
    var session = root.dragSession
    if (!session || !root.connectorIsMapped(session.connector)
        || session.topology !== root.topologyStamp()) return false
    var current = root.dragSourceLocation(session.target)
    return !!current && current.identity === session.location.identity
      && current.monitor === session.location.monitor
      && current.minimized === session.location.minimized
  }

  // Presentation reasons do not authorize moves. Optional labels use only
  // resolved identities; a stale/unknown row must never invent a destination.
  function rejectDragDestination(key, reason, identity, monitor) {
    var session = root.dragSession
    if (!session || !key) return null
    var rejection = {key:key, sourceKind:session.target.kind, reason:reason}
    if (identity) rejection.identity = identity
    if (monitor) rejection.monitor = monitor
    root.dragRejection = rejection
    return null
  }

  function dragDestination(key) {
    root.dragRejection = null
    var session = root.dragSession
    if (!session || !root.rowDragIsCurrent() || !key) return null
    var footerMonitor = InteractionModel.parseNewWorkspaceFooterKey(key)
    if (footerMonitor !== "") {
      if (!root.windowActions || session.target.kind !== "window") return null
      var footerCanonical = root.windowActions.canonicalMonitorIdentity(footerMonitor)
      if (!footerCanonical) return root.rejectDragDestination(key, "unknown-location")
      var source = root.windowActions.workspaceMoveLocation(
        session.target.toplevel, session.target.address)
      if (!source) return root.rejectDragDestination(key, "stale")
      var footerPin = root.windowActions.windowWorkspacePin(session.target.toplevel)
      if (footerPin) return root.rejectDragDestination(key, "pinned", footerPin.workspace)
      return {key:key, kind:"new-workspace", monitor:footerCanonical}
    }
    var row = root.rowsByKey[key]
    if (!row) return root.rejectDragDestination(key, "stale")
    if (session.target.kind === "workspace") {
      if (row.kind !== "monitor") return null
      var monitor = root.windowActions.canonicalMonitorIdentity(row.connector || row.monitorIdentity)
      if (!monitor) return root.rejectDragDestination(key, "unknown-location")
      var workspacePin = root.windowActions.workspaceMonitorPin(session.location.identity)
      if (workspacePin && workspacePin.monitor !== monitor)
        return root.rejectDragDestination(key, "workspace-pinned",
          session.location.identity, workspacePin.monitor)
      if (!root.windowActions.canMoveWorkspaceToMonitor(session.location.identity, monitor))
        return root.rejectDragDestination(key,
          session.location.monitor === monitor ? "same-monitor" : "unknown-location")
      return {key:key, identity:session.location.identity, monitor:monitor}
    }
    if (row.kind === "monitor") {
      var requested = root.windowActions.canonicalMonitorIdentity(row.connector || row.monitorIdentity)
      if (!requested) return root.rejectDragDestination(key, "unknown-location")
      var active = root.windowActions.monitorActiveWorkspaceIdentity(requested)
      var resolved = active ? root.windowActions.resolveWorkspaceDropTarget(active) : null
      if (!resolved) return root.rejectDragDestination(key, "unknown-location")
      if (resolved.monitor !== requested) return root.rejectDragDestination(key, "owner-mismatch")
      var headerPin = root.windowActions.windowWorkspacePin(session.target.toplevel)
      if (headerPin && headerPin.workspace !== resolved.identity)
        return root.rejectDragDestination(key, "pinned", headerPin.workspace)
      if (!root.windowActions.workspaceMoveWouldChange([session.target], resolved.identity))
        return root.rejectDragDestination(key, "same-workspace", resolved.identity)
      if (root.headerDropWithinMonitor === false && session.location.monitor === requested)
        return root.rejectDragDestination(key, "unknown-location")
      return {key:key, kind:"monitor", identity:resolved.identity, monitor:resolved.monitor}
    }
    if (["workspace", "application", "window"].indexOf(row.kind) < 0) return null
    if (!row.workspaceIdentity) return root.rejectDragDestination(key, "unknown-location")
    if (row.kind === "window" && root.windowActions.reliableWorkspaceForToplevel(row.toplevel)
        !== row.workspaceIdentity) return root.rejectDragDestination(key, "stale")
    var destination = root.windowActions.resolveWorkspaceDropTarget(row.workspaceIdentity)
    if (!destination) return root.rejectDragDestination(key, "unknown-location")
    var pin = root.windowActions.windowWorkspacePin(session.target.toplevel)
    if (pin && pin.workspace !== destination.identity)
      return root.rejectDragDestination(key, "pinned", pin.workspace)
    if (!root.windowActions.workspaceMoveWouldChange([session.target], destination.identity))
      return root.rejectDragDestination(key, "same-workspace", destination.identity)
    return {key:key, identity:destination.identity, monitor:destination.monitor}
  }

  function updateRowDrag(key) {
    if (!root.rowDragIsCurrent()) { root.cancelRowDrag("stale-source"); return false }
    root.dragTarget = root.dragDestination(key)
    return root.dragTarget !== null
  }

  function cancelRowDrag(reason) {
    root.dragRejection = null
    if (!root.dragSession) return false
    var session = root.dragSession
    if (["escape", "grab-loss", "cancelled"].indexOf(reason) >= 0) {
      var cancelled = root.makeDropOperation(session, null)
      if (root.dropOriginIsCurrent(cancelled) && root.dropEntityAlive(cancelled))
        root.dropOperation = Object.assign({}, cancelled, {state:"cancelled"})
    }
    root.dragSession = null
    root.dragTarget = null
    root.interactionBusy = false
    root.scheduleRefresh()
    return true
  }

  function finishRowDrag(key) {
    if (!root.dragSession) return false
    var session = root.dragSession
    var hovered = root.dragTarget
    var destination = root.dragDestination(key)
    if (destination && hovered && hovered.key === key) {
      var hoveredKind = hovered.kind || ""
      var destinationKind = destination.kind || ""
      if (hoveredKind === "new-workspace" || destinationKind === "new-workspace") {
        if (hoveredKind !== destinationKind || hovered.monitor !== destination.monitor)
          destination = null
      } else if (hovered.identity !== destination.identity || hovered.monitor !== destination.monitor) {
        destination = null
      }
    }
    // Snapshot identities and token before cleanup/submission, never the footer's
    // predicted allocation. Artwork/coordinates stay in the originating viewport.
    var operation = root.makeDropOperation(session, destination)
    root.cancelRowDrag("release")
    var accepted = false, outcome = "rejected", receipt = null
    try {
      if (destination && (destination.kind !== "monitor" || root.headerDropIsCurrent(session, destination))) {
        if (destination.kind === "new-workspace") {
          receipt = root.windowActions.moveCapturedWindowToNewWorkspaceResult(session.target, destination.monitor)
          accepted = receipt.accepted === true
          if (accepted) operation = Object.assign({}, operation, {
            expectedWorkspace:receipt.expectedWorkspace, expectedMonitor:receipt.expectedMonitor})
        } else if (session.target.kind === "workspace") {
          accepted = root.windowActions.moveWorkspaceToMonitor(session.location.identity, destination.monitor)
        } else {
          accepted = root.windowActions.moveCapturedToplevels([session.target], destination.identity, true)
        }
      }
      outcome = accepted ? "pending" : "rejected"
    } catch (error) {
      // Transport may have submitted before throwing. Never promise rollback,
      // retry, or animate a return on an ambiguous outcome.
      outcome = "unconfirmed"
    }
    if (root.dropOriginIsCurrent(operation) && root.dropEntityAlive(operation)) {
      root.dropOperation = Object.assign({}, operation, {state:outcome})
      if (outcome === "pending") {
        dropDeadlineTimer.operationToken = operation.token
        dropDeadlineTimer.interval = Math.max(1, operation.deadline - Number(root.dropClock()))
        dropDeadlineTimer.restart()
        root.evaluateDropOperation()
      }
    } else if (root.dropOperation && root.dropOperation.token === operation.token) {
      root.invalidateDropOperation()
    }
    return accepted
  }

  // Last check after gesture cleanup, immediately before the shared action.
  function headerDropIsCurrent(session, destination) {
    if (!root.targetIsCurrent(session.target) || session.topology !== root.topologyStamp()) return false
    var active = root.windowActions.monitorActiveWorkspaceIdentity(destination.monitor)
    var resolved = root.windowActions.resolveWorkspaceDropTarget(destination.identity)
    return !!resolved && active === destination.identity && resolved.monitor === destination.monitor
  }

  function toggleApplication(key) {
    if (root.interactionBusy) return false
    var row = root.rowsByKey[key]
    if (!row || row.kind !== "application") return false
    var next = Object.assign({}, root.folds)
    if (next[key]) delete next[key]
    else next[key] = true
    root.folds = next
    root.scheduleRefresh()
    return true
  }

  // Expand/fold Chrome tabs under a window row. Missing key => expanded;
  // folds[tabsKey] === true => folded.
  function toggleWindowTabs(key) {
    if (root.interactionBusy) return false
    var row = root.rowsByKey[key]
    if (!row || row.kind !== "window" || row.tabsExpandable !== true) return false
    var tabsKey = row.tabsKey || ("tabs:" + row.key)
    var next = Object.assign({}, root.folds)
    if (next[tabsKey]) delete next[tabsKey]
    else next[tabsKey] = true
    root.folds = next
    root.scheduleRefresh()
    return true
  }

  // Fold nested Herdr agents under a window. Missing key => expanded;
  // folds["herdr:"+windowKey] === true => folded. Counts stay on the parent.
  function toggleHerdrAgents(key) {
    if (root.interactionBusy) return false
    var row = root.rowsByKey[key]
    if (!row || row.kind !== "window" || row.herdrAssociated !== true) return false
    if (row.herdrExpandable !== true) return false
    var foldKey = row.herdrFoldKey || ("herdr:" + row.key)
    if (!foldKey) return false
    var next = Object.assign({}, root.folds)
    if (next[foldKey]) delete next[foldKey]
    else next[foldKey] = true
    root.folds = next
    root.scheduleRefresh()
    return true
  }

  function activateBrowserTab(target) {
    var service = root.host ? root.host.browserProfileService : null
    if (!service || !service.available
        || typeof service.allTabRows !== "function"
        || service.activationInFlight === true) return false
    var targetId = String(target && target.targetId || "")
    var address = String(target && target.windowAddress || "").toLowerCase()
    var verified = service.allTabRows().some(function(row) {
      return String(row.targetId || "") === targetId
        && String(row.windowAddress || "").toLowerCase() === address
    })
    if (!verified || !target.toplevel) return false
    if (!root.windowActions.activateToplevel(target.toplevel, true, "", true))
      return false
    return service.activateTarget(targetId)
  }

  // Toggle collapse for one panel connector. Writes only sidebarCollapsedByMonitor.
  function requestCollapse(screen) {
    var target = screen || root.selectedScreen
    var connector = target && target.name ? String(target.name) : ""
    if (!connector || !root.connectorIsMapped(connector))
      return {ok:false,error:{code:"E_STATE",message:"No sidebar output to collapse."},data:{applied:false}}
    if (root.resizeActive) root.cancelResize("collapse")
    if (root.interactionBusy)
      return {ok:false,error:{code:"E_BUSY",message:"Finish the active interaction."},data:{applied:false}}
    var expected = root.settings.sidebarCollapsedByMonitor
    var currentMap = DockModel.normalizeSetting("sidebarCollapsedByMonitor", expected)
    var nextMap = Object.assign({}, currentMap)
    nextMap[connector] = !root.collapsedFor(target)
    var intent = root.hostIntent("sidebarCollapsedByMonitor", nextMap, expected)
    var reply = intent.reply
    root.mutationFeedback = intent.accepted ? ""
      : String(reply && reply.error && reply.error.message || "Preference was not accepted.")
    return reply
  }

  function addressesForRow(row) {
    return (row.members || []).map(function(toplevel) {
      return WindowModel.locationForToplevel(toplevel, root.hyprToplevels, root.minimizedOrigins).address
    }).filter(function(address) { return !!address })
  }

  function profileForRow(row) {
    var service = root.host ? root.host.browserProfileService : null
    var revision = service ? service.revision : 0
    if (!service || !service.available || !row.members || !row.members.length) return null
    var addresses = root.addressesForRow(row)
    if (addresses.length !== row.members.length) return null
    var key = service.profileKeyForAddress(addresses[0])
    if (!key || addresses.some(function(a) { return service.profileKeyForAddress(a) !== key })) return null
    return {key:key, entry:service.profileFor(key)}
  }

  function badgeForRow(row) {
    var tracker = root.host ? root.host.badgeTracker : null
    var revision = tracker ? tracker.revision : 0
    if (!tracker || root.settings.attentionBadgesEnabled === false || !row.item) return "none"
    if (row.kind === "application" && !row.folded) return "none"
    var service = root.host ? root.host.browserProfileService : null
    var serviceRevision = service ? service.revision : 0
    var addresses = root.addressesForRow(row)
    var activities = service && service.available && typeof service.activityRowsForAddresses === "function"
      ? service.activityRowsForAddresses(addresses) : []
    return tracker.badgeFor(row.desktopId,
      {localUrgent:row.urgent === true,primaryOwner:row.primaryOwner === true}, activities)
  }

  // Read-only sidebar attention. Empty default: count 0 / countVisible false /
  // severity none. Browser windows use address-scoped activity presentation
  // (not app-wide launcher aggregates). Browser tabs match RAW activities by
  // targetId + windowAddress; own count stays visible even when the service is
  // muted. Expanded application groups omit attention (children own it).
  function attentionForRow(row) {
    var empty = BadgeModel.emptyAttention()
    if (!row || root.settings.attentionBadgesEnabled === false) return empty
    if (row.kind === "monitor" || row.kind === "workspace" || row.kind === "section")
      return empty
    if (row.kind === "application" && !row.folded) return empty

    var mode = root.settings.launcherBadgeMode === "dots-only"
      ? BadgeModel.BADGE_COUNT_MODE_DOTS_ONLY : BadgeModel.BADGE_COUNT_MODE_AUTOMATIC
    var mutedServices = DockModel.normalizeSetting(
      "browserActivityMutedServices", root.settings.browserActivityMutedServices)
    var tracker = root.host ? root.host.badgeTracker : null
    var trackerRevision = tracker ? tracker.revision : 0
    var service = root.host ? root.host.browserProfileService : null
    var serviceRevision = service ? service.revision : 0

    if (row.kind === "browser-tab") {
      if (!service || !service.available) return empty
      var raw = ActivityModel.activityForTarget(service.activities, row.targetId,
        row.windowAddress || row.address)
      if (!raw) return empty
      var muted = mutedServices.indexOf(raw.serviceId) >= 0
      var tabCount = {
        authoritative: true,
        count: raw.count,
        visible: true
      }
      var tabPresentation = BadgeModel.applicationBadgePresentation(
        true, mode, tabCount, BadgeModel.BADGE_NONE)
      return BadgeModel.attentionFromPresentation(tabPresentation, {
        serviceId: raw.serviceId,
        serviceLabel: raw.label,
        muted: muted
      })
    }

    var addresses = root.addressesForRow(row)
    // Window / folded-app browser counts: exact represented addresses only —
    // never the app-wide launcher aggregate when browser state is authoritative.
    if ((row.kind === "window" || row.kind === "application") && service
        && service.available && addresses.length && tracker) {
      var rawActivities = ActivityModel.rawRowsForAddresses(service.activities, addresses)
      var browser = tracker.browserCountFor(row.desktopId, rawActivities)
      if (browser && browser.authoritative === true) {
        var tokenSeverity = BadgeModel.decodeApplicationBadgeToken(
          root.badgeForRow(row)).severity
        var presented = ActivityModel.presentation(rawActivities, mutedServices)
        var top = null
        for (var i = 0; i < presented.rows.length; ++i) {
          if (!presented.rows[i].muted) { top = presented.rows[i]; break }
        }
        if (!top && presented.rows.length) top = presented.rows[0]
        var windowPresentation = BadgeModel.applicationBadgePresentation(
          true, mode, browser, tokenSeverity)
        return BadgeModel.attentionFromPresentation(windowPresentation, {
          serviceId: top ? top.serviceId : "",
          serviceLabel: top ? top.label : "",
          muted: top ? top.muted === true : false
        })
      }
    }

    // Non-browser / launcher ownership: preserve classic badgeForRow token.
    if (!tracker || !row.item) return empty
    return BadgeModel.attentionFromBadgeToken(root.badgeForRow(row))
  }

  // Window-only informational state. Pinned = Hyprland per-window IPC pinned
  // (sticky), not settings.pinned launcher membership or session movement locks.
  // Display fullscreen via isDisplayFullscreen(lastIpcObject) so Super+F
  // maximize, menu fullscreen, and client F11 all light the indicator without
  // broadening menu mode(). Application group headers never pretend a single
  // fullscreen state. Hyprland "fullscreen" / pin raw events refresh via
  // scopeRevision → scheduleRefresh, which re-reads handle.lastIpcObject.
  function windowStateForRow(row) {
    var none = { fullscreen: false, pinned: false, minimized: false }
    if (!row || row.kind !== "window") return none
    var minimized = row.minimized === true
    var fullscreen = false
    var pinned = false
    if (row.toplevel) {
      var handle = WindowModel.handleForToplevel(row.toplevel, root.hyprToplevels)
      if (handle) {
        var ipc = handle.lastIpcObject || ({})
        pinned = ipc.pinned === true
        fullscreen = FullscreenModel.isDisplayFullscreen(ipc)
      }
    }
    return { fullscreen: fullscreen, pinned: pinned, minimized: minimized }
  }

  function rowHasAlertControl(row) {
    if (!row || row.kind !== "browser-tab") return false
    var attention = root.attentionForRow(row)
    return !!attention.serviceId && (attention.count > 0 || attention.muted === true
      || attention.countVisible === true)
  }

  function toggleRowActivityMute(rowKey) {
    var row = root.rowsByKey[rowKey]
    if (!row || !root.host || typeof root.host.toggleBrowserActivityMute !== "function")
      return false
    var attention = root.attentionForRow(row)
    if (!attention.serviceId) return false
    var reply = root.host.toggleBrowserActivityMute(attention.serviceId)
    var accepted = !!(reply && (reply.ok || (reply.data && reply.data.applied === true)))
    root.mutationFeedback = accepted ? ""
      : String(reply && reply.error && reply.error.message
        || "Preference was not accepted.")
    return accepted
  }

  function clearAlertControl() {
    root.alertControlKey = ""
  }

  onSettingsChanged: {
    if (root.resizePreferenceConflict()) root.cancelResize("preference-conflict")
    root.syncWidgets()
    root.scheduleRefresh()
  }
  // Presentation mode and per-monitor overrides never invalidate here: owners
  // recreate only the affected surface, and refreshBody cancels in-flight
  // gestures when sidebar membership itself changes.
  onEdgeChanged: root.invalidateSurface()
  // Per-panel collapse updates geometry bindings; do not tear the Loader down.
  onCollapsedChanged: {
    root.closeWidgetPopup()
    root.cancelWidgetReorder()
    root.scheduleRefresh()
  }
  onCollapsedByMonitorChanged: {
    root.closeWidgetPopup()
    if (root.resizePreferenceConflict()) root.cancelResize("preference-conflict")
    root.scheduleRefresh()
  }
  // The pin moves this panel to another output; cancel in-flight gestures that
  // captured the previous host mapping, then refresh with the busy flag cleared
  // so selectScreens resolves the new pin instead of preserving the old set.
  onSidebarMonitorPinChanged: {
    root.cancelResize("host-changed")
    root.cancelRowDrag("host-changed")
    root.scheduleRefresh()
  }
  onScreensChanged: root.refresh()
  onMonitorsChanged: root.scheduleRefresh()
  onWorkspacesChanged: root.scheduleRefresh()
  onApplicationsChanged: root.scheduleRefresh()
  onToplevelsChanged: root.scheduleRefresh()
  onHyprToplevelsChanged: root.scheduleRefresh()
  onMinimizedOriginsChanged: root.scheduleRefresh()
  onFocusedWorkspaceChanged: root.scheduleRefresh()
  onScopeRevisionChanged: root.scheduleRefresh()
  onInteractionBusyChanged: if (!interactionBusy) root.scheduleRefresh()
  Connections {
    target: root.host && root.host.browserProfileService
      ? root.host.browserProfileService : null
    function onRevisionChanged() { root.scheduleRefresh() }
    function onAvailableChanged() { root.scheduleRefresh() }
  }
  // Claude has no sidebar Widget lease, so bridge snapshot and association
  // changes must refresh the projection directly.
  Connections {
    target: root.herdrWindowAgents
    ignoreUnknownSignals: true
    function onViewRevisionChanged() { root.scheduleRefresh() }
    function onHerdrAssociationsChanged() { root.scheduleRefresh() }
    function onSnapshotReadyChanged() { root.scheduleRefresh() }
  }
  Timer {
    id: dropDeadlineTimer
    property double operationToken: 0
    interval: 1500
    repeat: false
    onTriggered: root.expireDropOperation(operationToken)
  }
  Component.onCompleted: {
    root.widgetManager = SidebarWidgetModel.createManager(function() { root.widgetsChanged() })
    root.initialized = true
    root.refresh()
  }
  Component.onDestruction: {
    root.invalidateDropOperation()
    root.initialized = false
    root.closeWidgetPopup()
    if (root.widgetManager) root.widgetManager.dispose()
  }
}
