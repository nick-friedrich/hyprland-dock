pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel
import "DockIconModel.js" as DockIconModel
import "DockDesktopModel.js" as DesktopModel
import "DockWindowModel.js" as DockWindowModel
import "DockWindowPreviewModel.js" as PreviewModel
import "DockWorkspaceModel.js" as WorkspaceModel
import "DockWorkspaceGroupModel.js" as WorkspaceGroupModel
import "DockBadgeModel.js" as BadgeModel
import "DockTrashModel.js" as TrashModel
import "DockSidebarModel.js" as SidebarModel
import "DockHerdrModel.js" as HerdrModel

PanelWindow {
  id: root

  required property var settings
  required property bool showTrash
  required property var windowActions
  property var herdrWindowAgents: null
  property var herdrAgentActions: null
  required property var workspaceMonitorDrag
  required property var badgeTracker
  required property int trashItemCount
  required property bool trashStateKnown
  required property var workspaceWindowCounts
  required property bool workspaceCountsReady
  required property int workspaceCountsRevision
  required property int scopeRevision
  property var iconOverrides: ({})
  property int iconReloadRevision: 0
  property var browserProfileService: null
  property bool browserProfileBadgesEnabled: true
  readonly property var browserActivityMutedServices: DockModel.normalizeSetting(
    "browserActivityMutedServices", settings.browserActivityMutedServices)
  signal reorderRequested(string sourceDesktopId, string targetDesktopId)
  signal pinRequested(string desktopId)
  signal unpinRequested(string desktopId)
  signal hideRequested(string desktopId)
  signal browserActivityMuteToggled(string serviceId)
  signal autoHideRequested(bool enabled)
  signal settingsRequested(var anchor)
  property var host: null
  signal positionRequested(string position, var expectedPosition, var gestureToken)
  signal menuModeSwitchRequested(var token)
  signal openTrashRequested()
  signal emptyTrashRequested()

  function monitorLogicalOrigin(monitor, fallbackScreen) {
    var ipc = monitor ? monitor.lastIpcObject || monitor : ({})
    var x = Number(ipc.x)
    var y = Number(ipc.y)
    if (!isFinite(x)) x = Number(fallbackScreen && fallbackScreen.x) || 0
    if (!isFinite(y)) y = Number(fallbackScreen && fallbackScreen.y) || 0
    return Qt.point(x, y)
  }

  function monitorLogicalSize(monitor, fallbackScreen) {
    var ipc = monitor ? monitor.lastIpcObject || monitor : ({})
    var scale = Number(ipc.scale)
    var width = Number(ipc.width)
    var height = Number(ipc.height)
    if (isFinite(scale) && scale > 0) {
      width /= scale
      height /= scale
    }
    if (!isFinite(width) || width <= 0)
      width = Number(fallbackScreen && fallbackScreen.width) || 0
    if (!isFinite(height) || height <= 0)
      height = Number(fallbackScreen && fallbackScreen.height) || 0
    return Qt.size(width, height)
  }

  function workspaceMonitorVirtualRect(item, offsetX, offsetY) {
    if (!item) return Qt.rect(0, 0, 0, 0)
    return Qt.rect(sceneOrigin.x + Number(item.x || 0) + Number(offsetX || 0),
      sceneOrigin.y + Number(item.y || 0) + Number(offsetY || 0),
      item.width, item.height)
  }

  function workspaceMonitorClipRect(rect, bounds) {
    if (!rect || !bounds) return Qt.rect(0, 0, 0, 0)
    var left = Math.max(rect.x, bounds.x)
    var top = Math.max(rect.y, bounds.y)
    var right = Math.min(rect.x + rect.width, bounds.x + bounds.width)
    var bottom = Math.min(rect.y + rect.height, bounds.y + bounds.height)
    return Qt.rect(left, top, Math.max(0, right - left),
      Math.max(0, bottom - top))
  }

  function workspaceMonitorVisibleRect(item, offsetX, offsetY) {
    return workspaceMonitorClipRect(
      workspaceMonitorVirtualRect(item, offsetX, offsetY), monitorRect)
  }

  // The coordinator dwelled on one of this dock's multiwindow icons. Re-resolve
  // the anchor against the current keyed presentation before opening: a
  // retained removal slot, a re-grouped card or a stale key must never receive
  // the popup, and the ordinary 220 ms hover delay is not applied again.
  function requestExternalPreview(owner, key, anchor) {
    if (owner !== root || !anchor || !root.showPreviews) return false
    var presentationId = String(anchor.presentationId || "")
    if (!presentationId || String(key || "") !== "preview:" + presentationId)
      return false
    var target = PreviewModel.visiblePreviewTarget(root.renderedItems,
      presentationId, anchor.identityToplevel || null)
    if (!target || String(target.presentationId || "") !== presentationId
        || (target.identityToplevel || null) !== (anchor.identityToplevel || null))
      return false
    return windowPreview.requestDragPreview(anchor, anchor.desktopId,
      anchor.runningToplevels, anchor.entry)
  }

  function cardForWorkspace(identity) {
    var wanted = String(identity || "")
    if (!wanted || !workspaceCards) return null
    for (var i = 0; i < workspaceCards.count; ++i) {
      var wrap = workspaceCards.itemAt(i)
      if (wrap && wrap.present && String(wrap.workspaceIdentity) === wanted)
        return wrap.dropCard
    }
    return null
  }

  function workspaceMonitorViewportRect() {
    if (!dockShown || visible === false) return Qt.rect(0, 0, 0, 0)
    if (!groupedLayout || groupedLayout.visible === false || !interactionArea)
      return Qt.rect(0, 0, 0, 0)
    var inset = Number(groupedLayout.navigationWidth) || 0
    var origin = groupedLayout.mapToItem(interactionArea, inset, 0)
    var width = Number(groupedLayout.viewportWidth)
    if (!isFinite(width) || width <= 0)
      width = Math.max(0, Number(groupedLayout.width) - inset * 2)
    return workspaceMonitorClipRect(Qt.rect(
      sceneOrigin.x + interactionArea.x + origin.x,
      sceneOrigin.y + interactionArea.y + origin.y,
      width, groupedLayout.height), monitorRect)
  }

  function workspaceMonitorSectionHits() {
    var hits = []
    if (!dockShown || visible === false || !workspaceCards || !interactionArea) return hits
    try {
      var view = workspaceMonitorViewportRect()
      for (var i = 0; i < workspaceCards.count; ++i) {
        var wrap = workspaceCards.itemAt(i)
        if (!wrap || !wrap.present) continue
        var identity = String(wrap.sectionMonitorIdentity || "")
        if (!identity) continue
        var origin = wrap.mapToItem(interactionArea, 0, 0)
        var rect = workspaceMonitorClipRect(Qt.rect(
          sceneOrigin.x + interactionArea.x + origin.x,
          sceneOrigin.y + interactionArea.y + origin.y,
          wrap.width, wrap.height), view)
        if (rect.width <= 0 || rect.height <= 0) continue
        var last = hits.length ? hits[hits.length - 1] : null
        if (last && last.identity === identity) {
          var left = Math.min(last.rect.x, rect.x)
          var top = Math.min(last.rect.y, rect.y)
          var right = Math.max(last.rect.x + last.rect.width, rect.x + rect.width)
          var bottom = Math.max(last.rect.y + last.rect.height, rect.y + rect.height)
          last.rect = Qt.rect(left, top, right - left, bottom - top)
        } else {
          hits.push({ identity: identity, rect: rect })
        }
      }
    } catch (error) {
      return []
    }
    return hits
  }

  function monitorDropSectionRect() {
    var identity = String(workspaceMonitorDropIdentity || "")
    var empty = Qt.rect(0, 0, 0, 0)
    if (!identity || !workspaceCards || !dockLayout) return empty
    try {
      var found = false
      var hits = empty
      for (var i = 0; i < workspaceCards.count; ++i) {
        var wrap = workspaceCards.itemAt(i)
        if (!wrap || !wrap.present) continue
        if (String(wrap.sectionMonitorIdentity || "") !== identity) continue
        var origin = wrap.mapToItem(dockLayout, 0, 0)
        var rect = Qt.rect(origin.x, origin.y, wrap.width, wrap.height)
        if (groupedLayout && groupedLayout.visible !== false) {
          var inset = Number(groupedLayout.navigationWidth) || 0
          var viewOrigin = groupedLayout.mapToItem(dockLayout, inset, 0)
          var width = Number(groupedLayout.viewportWidth)
          if (!isFinite(width) || width <= 0)
            width = Math.max(0, Number(groupedLayout.width) - inset * 2)
          rect = workspaceMonitorClipRect(rect, Qt.rect(
            viewOrigin.x, viewOrigin.y, width, groupedLayout.height))
        }
        if (rect.width <= 0 || rect.height <= 0) continue
        if (!found) {
          hits = rect
          found = true
          continue
        }
        var left = Math.min(hits.x, rect.x)
        var top = Math.min(hits.y, rect.y)
        var right = Math.max(hits.x + hits.width, rect.x + rect.width)
        var bottom = Math.max(hits.y + hits.height, rect.y + rect.height)
        hits = Qt.rect(left, top, right - left, bottom - top)
      }
      return found ? hits : empty
    } catch (error) {
      return empty
    }
  }

  property int dragSource: -1
  property int dragTarget: -1
  property int openMenuCount: 0
  property bool autoHideRevealed: false
  property bool dragRevealed: false
  property bool workspaceMonitorDropHighlighted: false
  readonly property string workspaceMonitorDropIdentity: {
    var drag = workspaceMonitorDrag
    if (!drag || !drag.active || drag.hoveredTarget !== root) return ""
    return String(drag.hoveredMonitor || "")
  }
  property int badgeStateRevision: 0
  readonly property bool workspaceDragActive: workspaceDrag.active
  readonly property DockWorkspaceDrag workspaceDragController: workspaceDrag
  property bool workspacePresentationDirty: false
  property bool revealAfterWorkspaceDrag: false
  property bool dragFullscreenModeActive: false
  property var dragWorkspaceFullscreenOwners: ({})

  // The profile applies only when every window in the item reports the same
  // one; mixed-profile groups keep the plain application icon. Item toplevels
  // are generic Wayland handles, so resolve Hyprland addresses through the
  // paired HyprlandToplevel (same pairing itemWorkspaceId already uses).
  function hyprAddressFor(toplevel) {
    var handle = DockWindowModel.handleForToplevel(toplevel, root.hyprToplevels)
    if (!handle) return ""
    var ipc = handle.lastIpcObject || ({})
    return DockModel.normalizeWindowAddress(handle.address || ipc.address)
  }

  function profileKeyFor(item) {
    var service = root.browserProfileService
    if (!service || !service.available) return ""
    var toplevels = item && item.toplevels ? item.toplevels : []
    var key = ""
    for (var i = 0; i < toplevels.length; ++i) {
      var address = hyprAddressFor(toplevels[i])
      if (!address) return ""
      var windowKey = service.profileKeyForAddress(address)
      if (!windowKey) return ""
      if (key === "") key = windowKey
      else if (key !== windowKey) return ""
    }
    return key
  }

  function addressesForItem(item) {
    var addresses = []
    var toplevels = item && item.toplevels ? item.toplevels : []
    for (var i = 0; i < toplevels.length; ++i) {
      var address = hyprAddressFor(toplevels[i])
      if (address && addresses.indexOf(address) < 0) addresses.push(address)
    }
    return addresses
  }

  function browserActivitiesFor(item) {
    var service = root.browserProfileService
    var serviceRevision = service ? Number(service.revision || 0) : 0
    if (!service || !service.available
        || typeof service.activityRowsForAddresses !== "function") return []
    return service.activityRowsForAddresses(root.addressesForItem(item))
  }

  function activateBrowserActivity(activity, members) {
    var service = root.browserProfileService
    if (!service || !service.available
        || typeof service.allActivityRows !== "function"
        || service.activationInFlight === true) return false
    var targetId = String(activity && activity.targetId || "")
    var address = String(activity && activity.windowAddress || "")
    var rows = service.allActivityRows()
    var verified = rows.some(function(row) {
      return String(row.targetId || "") === targetId
        && String(row.windowAddress || "").toLowerCase() === address.toLowerCase()
    })
    if (!verified) return false
    var member = PreviewModel.memberForAddress(
      members, address, root.hyprAddressFor)
    if (!member) return false
    if (!root.windowActions.activateToplevel(
        member, windowPreview.originOnly, windowPreview.activationMonitor))
      return false
    if (!service.activateTarget(targetId)) return false
    windowPreview.dismissImmediately()
    return true
  }

  readonly property int iconSize: DockModel.normalizeSetting(
    "iconSize", settings.iconSize)
  readonly property real magnification: DockModel.normalizeSetting(
    "magnification", settings.magnification)
  readonly property real magnificationRadius: DockModel.normalizeSetting(
    "magnificationRadius", settings.magnificationRadius)
  readonly property bool hoverGlowEnabled: DockModel.normalizeSetting(
    "hoverGlowEnabled", settings.hoverGlowEnabled)
  readonly property real hoverGlowOpacity: DockModel.normalizeSetting(
    "hoverGlowOpacity", settings.hoverGlowOpacity)
  readonly property real hoverGlowRadius: DockModel.normalizeSetting(
    "hoverGlowRadius", settings.hoverGlowRadius)
  readonly property bool showPreviews: DockModel.normalizeSetting(
    "showPreviews", settings.showPreviews)
  readonly property int edgeMargin: settings.margin === undefined ? 10 : settings.margin
  // Live bindings to Omarchy's Color singleton keep symbolic overrides in sync
  // with theme changes, independently of how the preferences were configured.
  readonly property var themeColorTokens: ({
    "background": Color.background,
    "foreground": Color.foreground,
    "accent": Color.accent,
    "muted": Color.muted,
    "urgent": Color.urgent,
    "bar.background": Color.bar.background,
    "bar.text": Color.bar.text,
    "bar.active": Color.bar.active,
    "popups.background": Color.popups.background,
    "popups.text": Color.popups.text,
    "popups.border": Color.popups.border,
    "tooltip.background": Color.tooltip.background,
    "tooltip.text": Color.tooltip.text,
    "tooltip.border": Color.tooltip.border,
    "menu.background": Color.menu.background,
    "menu.text": Color.menu.text,
    "menu.border": Color.menu.border,
    "menu.selected-background": Color.menu.selectedBackground,
    "menu.selected-text": Color.menu.selectedText,
    "menu.selected-border": Color.menu.selectedBorder,
    "notifications.background": Color.notifications.background,
    "notifications.text": Color.notifications.text,
    "notifications.border": Color.notifications.border,
    "notifications.countdown": Color.notifications.countdown
  })
  readonly property bool workspaceBadgeBackgroundColorEnabled:
    DockModel.normalizeSetting(
      "workspaceBadgeBackgroundColorEnabled",
      settings.workspaceBadgeBackgroundColorEnabled)
  readonly property string workspaceBadgeBackgroundColorOverride:
    DockModel.normalizeSetting(
      "workspaceBadgeBackgroundColor",
      settings.workspaceBadgeBackgroundColor)
  readonly property color effectiveWorkspaceBadgeBackgroundColor:
    DockModel.effectiveColor(
      workspaceBadgeBackgroundColorEnabled,
      workspaceBadgeBackgroundColorOverride,
      Color.accent,
      themeColorTokens)
  readonly property bool workspaceBadgeTextColorEnabled:
    DockModel.normalizeSetting(
      "workspaceBadgeTextColorEnabled",
      settings.workspaceBadgeTextColorEnabled)
  readonly property string workspaceBadgeTextColorOverride:
    DockModel.normalizeSetting(
      "workspaceBadgeTextColor",
      settings.workspaceBadgeTextColor)
  readonly property color effectiveWorkspaceBadgeTextColor:
    DockModel.effectiveColor(
      workspaceBadgeTextColorEnabled,
      workspaceBadgeTextColorOverride,
      "#ffffff",
      themeColorTokens)
  readonly property bool backgroundColorEnabled: DockModel.normalizeSetting(
    "backgroundColorEnabled", settings.backgroundColorEnabled)
  readonly property string backgroundColorOverride: DockModel.normalizeSetting(
    "backgroundColor", settings.backgroundColor)
  readonly property color dockBackgroundBaseColor: DockModel.effectiveColor(
    backgroundColorEnabled, backgroundColorOverride, Color.menu.background,
    themeColorTokens)
  readonly property real backgroundOpacity: DockModel.normalizeSetting(
    "backgroundOpacity", settings.backgroundOpacity)
  readonly property color dockBackgroundColor: Qt.rgba(
    dockBackgroundBaseColor.r,
    dockBackgroundBaseColor.g,
    dockBackgroundBaseColor.b,
    DockModel.surfaceOpacity(dockBackgroundBaseColor.a, backgroundOpacity))
  readonly property bool borderColorEnabled: DockModel.normalizeSetting(
    "borderColorEnabled", settings.borderColorEnabled)
  readonly property string borderColorOverride: DockModel.normalizeSetting(
    "borderColor", settings.borderColor)
  readonly property bool borderWidthEnabled: DockModel.normalizeSetting(
    "borderWidthEnabled", settings.borderWidthEnabled)
  readonly property var themeDockBorderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property real themeBorderWidth: Math.max(
    Border.top(themeDockBorderSpec), Border.right(themeDockBorderSpec),
    Border.bottom(themeDockBorderSpec), Border.left(themeDockBorderSpec))
  readonly property real borderWidth: DockModel.effectiveBorderWidth(
    borderWidthEnabled, settings.borderWidth, themeBorderWidth)
  readonly property color dockBorderColor: DockModel.effectiveColor(
    borderColorEnabled, borderColorOverride, Color.menu.border,
    themeColorTokens)
  readonly property var dockBorderSpec: {
    var spec = {
      color: themeDockBorderSpec.color,
      widths: themeDockBorderSpec.widths,
      gradient: themeDockBorderSpec.gradient
    }
    if (root.borderColorEnabled && root.borderColorOverride !== "") {
      spec.color = root.dockBorderColor
      spec.gradient = { colors: [], angle: 0, enabled: false }
    }
    if (root.borderWidthEnabled)
      spec.widths = Border.flat(spec.color, root.borderWidth).widths
    return spec
  }
  readonly property bool autoHide: DockModel.normalizeSetting(
    "autoHide", settings.autoHide)
  readonly property bool reserveSpace: DockModel.shouldReserveSpace(
    DockModel.normalizeSetting("reserveSpace", settings.reserveSpace),
    autoHide)
  readonly property var applicationActions: DockModel.normalizeApplicationActionConfig({
    clickAction: settings.clickAction,
    middleClickAction: settings.middleClickAction,
    scrollAction: settings.scrollAction
  })
  readonly property string controlCommand: DockModel.normalizeSetting(
    "controlCommand", settings.controlCommand)
  readonly property string position: DockModel.normalizeSetting(
    "position", settings.position)
  readonly property bool vertical: position === "left" || position === "right"
  readonly property bool fullLength: DockModel.normalizeSetting(
    "fullLength", settings.fullLength)
  readonly property bool sortByWorkspace: DockModel.normalizeSetting(
    "sortByWorkspace", settings.sortByWorkspace)
  readonly property string workspaceMonitorScope: DockModel.normalizeSetting(
    "workspaceMonitorScope", settings.workspaceMonitorScope)
  readonly property var workspaceMonitorOrder: DockModel.normalizeSetting(
    "workspaceMonitorOrder", settings.workspaceMonitorOrder)
  readonly property var workspaceGroups: WorkspaceGroupModel.normalizeWorkspaceGroups(
    settings.workspaceGroups || [])
  readonly property var windowIconOverrides: DockIconModel.normalizeWindowRules(
    settings.windowIconOverrides || [])
  readonly property string windowScope: DockWindowModel.normalizeWindowScope(
    settings.windowScope)
  readonly property bool showUrgentOutsideScope:
    DockWindowModel.normalizeShowUrgentOutsideScope(
      settings.showUrgentOutsideScope)
  readonly property bool attentionBadgesEnabled:
    typeof settings.attentionBadgesEnabled === "boolean"
      ? settings.attentionBadgesEnabled : true
  readonly property bool urgentWindowAnimationEnabled:
    typeof settings.urgentWindowAnimationEnabled === "boolean"
      ? settings.urgentWindowAnimationEnabled : true
  readonly property bool dockHerdrIndicators: DockModel.normalizeSetting(
    "dockHerdrIndicators", settings.dockHerdrIndicators)
  readonly property bool dockT3Indicators: DockModel.normalizeSetting(
    "dockT3Indicators", settings.dockT3Indicators)
  readonly property bool dockClaudeIndicators: DockModel.normalizeSetting(
    "dockClaudeIndicators", settings.dockClaudeIndicators)
  readonly property bool anyAgentIndicators: dockHerdrIndicators || dockT3Indicators
    || dockClaudeIndicators
  readonly property bool interfaceAnimationsEnabled: DockModel.normalizeSetting(
    "interfaceAnimationsEnabled", settings.interfaceAnimationsEnabled)
  // Background mode gesture state. The host reports a rejected or still-pending
  // mode write back through modeGestureFeedback, keyed to this dock's output;
  // the rest drives the sidebar destination silhouette this dock would switch to.
  property string modeGestureFeedback: ""
  // Presentation mode this dock's output actually renders, injected by its
  // screen owner in a mixed layout; falls back to the global default when the
  // dock is instantiated without an owner (isolated tests).
  property string presentationMode: DockModel.normalizeSetting(
    "presentationMode", settings.presentationMode)
  // Press-time presentation token for this dock's output, injected by its
  // screen owner and captured by the drag surface when the pointer goes down.
  property var modeGestureToken: null
  readonly property string sidebarPreviewEdge: DockModel.normalizeSetting(
    "sidebarEdge", settings.sidebarEdge)
  readonly property bool sidebarPreviewCollapsed: DockModel.sidebarCollapsedForScreen(
    DockModel.normalizeSetting("sidebarCollapsedByMonitor",
      settings.sidebarCollapsedByMonitor),
    DockModel.normalizeSetting("sidebarCollapsed", settings.sidebarCollapsed),
    screen && screen.name)
  readonly property real sidebarPreviewBand: SidebarModel.screenGeometry(
    screen, settings.sidebarExpandedWidth, sidebarPreviewCollapsed).width
  readonly property bool modeDragArmed: positionDragSurface.gestureActive
    && positionDragSurface.armed
  readonly property string modeDragDestinationEdge: modeDragArmed
    ? positionDragSurface.destinationEdge : ""
  readonly property var pinned: settings.pinned || []
  readonly property var hiddenApplications: DockModel.normalizeSetting(
    "hiddenApplications", settings.hiddenApplications)
  readonly property var applications: DesktopEntries.applications.values || []
  readonly property var toplevels: ToplevelManager.toplevels.values || []
  readonly property var hyprToplevels: Hyprland.toplevels
    ? Hyprland.toplevels.values || [] : []
  readonly property var hyprWorkspaces: Hyprland.workspaces
    ? Hyprland.workspaces.values || [] : []
  readonly property var hyprMonitors: Hyprland.monitors
    ? Hyprland.monitors.values || [] : []
  readonly property bool showMonitorPrefixes: hyprMonitors.length > 1
  readonly property var dockHyprMonitor: {
    var revision = scopeRevision
    return DockWindowModel.monitorForScreen(screen, hyprMonitors)
  }
  readonly property string monitorIdentity:
    DockWindowModel.canonicalMonitorIdentity(dockHyprMonitor, hyprMonitors)
  readonly property point monitorOrigin:
    monitorLogicalOrigin(dockHyprMonitor, screen)
  readonly property size monitorSize:
    monitorLogicalSize(dockHyprMonitor, screen)
  readonly property point sceneOrigin: Qt.point(
    monitorOrigin.x + (vertical && position === "right"
      ? Math.max(0, monitorSize.width - width) : 0),
    monitorOrigin.y + (!vertical && position === "bottom"
      ? Math.max(0, monitorSize.height - height) : 0))
  readonly property rect monitorRect: Qt.rect(
    monitorOrigin.x, monitorOrigin.y, monitorSize.width, monitorSize.height)
  readonly property rect revealRect: workspaceMonitorVirtualRect(revealStrip)
  readonly property rect dropRect: dockShown
    ? workspaceMonitorVisibleRect(dockBackground,
      dockAutoHideOffset.x, dockAutoHideOffset.y)
    : Qt.rect(0, 0, 0, 0)
  readonly property bool workspaceMonitorDragAvailable:
    grouped && !vertical && monitorIdentity !== "" && visible
  readonly property Item workspaceDragMapItem: interactionArea
  readonly property bool workspaceMonitorDragActive:
    workspaceMonitorDrag !== null && workspaceMonitorDrag.active
  readonly property bool workspaceMonitorDragSourceActive:
    workspaceMonitorDragActive && workspaceMonitorDrag.sourceDock === root
  readonly property color workspaceMonitorDragAccent: Color.accent
  readonly property color workspaceMonitorDragBackground: Color.menu.background
  readonly property color workspaceMonitorDragForeground: Color.menu.text
  readonly property string workspaceMonitorDragFontFamily: Style.font.family
  readonly property int workspaceMonitorDragFontSize: Style.font.bodySmall
  readonly property string focusedScopeWorkspace: {
    var revision = scopeRevision
    return DockWindowModel.focusedWorkspaceIdentity(
      hyprMonitors, Hyprland.focusedWorkspace)
  }
  readonly property var windowScopeContext: {
    var revision = scopeRevision
    return DockWindowModel.windowScopeContext(
      windowScope, focusedScopeWorkspace, dockHyprMonitor,
      showUrgentOutsideScope)
  }
  readonly property var filteredToplevels: {
    var revision = scopeRevision
    return DockWindowModel.filterToplevelsByScope(
      toplevels, hyprToplevels,
      windowActions ? windowActions.minimizedOriginsSnapshot : ({}),
      windowScopeContext)
  }
  readonly property int focusedWorkspaceId: {
    var revision = scopeRevision + workspaceCountsRevision
    return DockModel.focusedWorkspaceIdFromMonitors(
      hyprMonitors, Hyprland.focusedWorkspace)
  }
  readonly property var activeToplevel: ToplevelManager.activeToplevel
  readonly property var fullscreenOwnerToplevel: DockModel.fullscreenOwner(
    toplevels, hyprToplevels, focusedWorkspaceId, activeToplevel,
    scopeRevision)
  readonly property bool fullscreenModeActive: workspaceDragActive
    ? dragFullscreenModeActive : fullscreenOwnerToplevel !== null
  property var visibleItems: []
  readonly property bool groupedRequested: !vertical
    && DockModel.normalizeSetting("workspaceLayout", settings.workspaceLayout) === "grouped"
  property var workspacePresentation: ({
    primaryWorkspaceIdentity: "", monitorGroups: [], groups: [],
    globalLaunchers: [], fallbackItems: [], renderedItems: []
  })
  readonly property var workspaceDisplayPresentation: {
    var drag = workspaceMonitorDrag
    var target = drag && (drag.active || drag.awaitingConfirmation)
      ? String(drag.projectionMonitor || "") : ""
    if (!groupedRequested || !target || !drag) return workspacePresentation
    return WorkspaceModel.projectMonitorDrag(workspacePresentation, {
      workspaceIdentity: String(drag.sourceWorkspace || ""),
      sourceMonitor: String(drag.sourceMonitor || ""),
      targetMonitor: target,
      label: String(drag.sourceLabel || ""),
      count: Number(drag.sourceCount) || 0
    }, monitorIdentity)
  }
  readonly property bool grouped: groupedRequested
  readonly property var minimizedToplevels: {
    var revision = scopeRevision
    if (!windowActions || windowActions.minimizedOriginsSnapshot === null)
      return []
    return toplevels.filter(function(toplevel) {
      return windowActions.isMinimized(toplevel)
    })
  }
  readonly property var liveWorkspaceFullscreenOwners: {
    var revision = scopeRevision
    if (!grouped) return ({})
    return DockModel.workspaceFullscreenOwners(
      workspacePresentation.groups, hyprToplevels, activeToplevel,
      minimizedToplevels)
  }
  readonly property var workspaceFullscreenOwners:
    workspaceDragActive ? dragWorkspaceFullscreenOwners : liveWorkspaceFullscreenOwners
  readonly property bool groupedFullscreenModeActive:
    Object.keys(workspaceFullscreenOwners).length > 0
  readonly property var renderedItems: grouped ? workspacePresentation.renderedItems : visibleItems
  readonly property string activeCardIdentity:
    grouped ? String(workspacePresentation.primaryWorkspaceIdentity || "") : ""
  onActiveCardIdentityChanged: Qt.callLater(root.revealActiveWorkspace)

  readonly property var visibleWorkspaceIds: {
    var revision = scopeRevision + workspaceCountsRevision
    return DockModel.visibleWorkspaceIds(
      hyprWorkspaces, focusedWorkspaceId, hyprToplevels,
      workspaceWindowCounts, workspaceCountsReady)
  }
  readonly property int itemSize: iconSize + (grouped ? 14 : 22)
  // Visible gap between sidebar pinned icons: (cell - iconSize) + pinGap.
  readonly property int pinnedIconGap: Style.space(16)
  readonly property int reservedSize: iconSize + (grouped ? 32 : 44) + edgeMargin
  readonly property int mainPadding: grouped ? 8 : 16
  readonly property int revealThickness: 3
  readonly property int crossExtent: vertical
    ? Math.ceil(iconSize * magnification + 80) + edgeMargin
    : Math.ceil(iconSize * magnification + 64) + edgeMargin
  readonly property int appMainExtent: grouped ? Math.ceil(groupedLayout.desiredWidth) : visibleItems.length * itemSize
  readonly property int workspaceMainExtent: grouped ? 0
    : (vertical ? workspaceStrip.height : workspaceStrip.width) + (showTrash ? 0 : 12)
  readonly property int trashMainExtent: TrashModel.sectionMainExtent(
    showTrash, itemSize, 12)
  readonly property int trailingMainExtent: TrashModel.trailingMainExtent(
    showTrash, itemSize, 12, workspaceMainExtent)
  readonly property int compactMainExtent: mainPadding * 2 + itemSize
    + appMainExtent + trailingMainExtent
  // Keep magnification space transparent, without shrinking the logical viewport.
  // Trim only the magnification allowance so the trailing inset matches the
  // leading mainPadding before the control item.
  readonly property int groupedSurfaceTrim: groupedLayout.contentPadding
  readonly property int groupedSurfaceGutter: Math.max(0, groupedLayout.contentPadding - 4)
  readonly property bool compactGroupedSurface: grouped && !vertical && !fullLength && !showTrash
    && (!screen || Math.max(compactMainExtent,
      compactMainExtent - groupedSurfaceTrim + groupedSurfaceGutter * 2) <= screen.width)
  readonly property int compactPanelExtent: compactGroupedSurface
    ? compactMainExtent - groupedSurfaceTrim + groupedSurfaceGutter * 2 : compactMainExtent
  // Host-owned shared external content-drag coordinator. Hover only holds this
  // surface open; every activation stays in the shared window/sidebar owners.
  readonly property var externalDragNavigation: root.host
    ? root.host.externalDragNavigation || null : null
  readonly property bool externalDragHeld: root.externalDragNavigation
    ? root.externalDragNavigation.heldFor(root) : false
  readonly property bool keepAutoHideOpen: windowPointer.hovered
    || appPicker.visible || openMenuCount > 0
    || dragSource >= 0 || windowPreview.interactionActive || workspaceDragActive
    || workspaceMonitorDragSourceActive || positionDragSurface.pressed || dragRevealed
    || root.externalDragHeld === true
  readonly property bool dockShown: !autoHide || autoHideRevealed || dragRevealed
  readonly property real pointerPosition: !pointer.hovered
    ? -10000
    : vertical
      ? pointer.point.position.y
      : pointer.point.position.x

  function refreshVisibleItems() {
    if (root.workspaceDragActive) {
      root.workspacePresentationDirty = true
      return
    }
    var desktop = DesktopModel.build({
      mode: groupedRequested ? "classic-grouped" : "classic-flat",
      settings: {
        pinned: pinned,
        hiddenApplications: hiddenApplications,
        workspaceGroups: workspaceGroups,
        workspaceMonitorScope: workspaceMonitorScope,
        workspaceMonitorOrder: workspaceMonitorOrder,
        sortByWorkspace: sortByWorkspace
      },
      applications: applications,
      toplevels: toplevels,
      windowRuleMatches: toplevels.map(function(toplevel) {
        return DockIconModel.matchWindowRule(windowIconOverrides,
          toplevel ? toplevel.appId : "", toplevel ? toplevel.title : "")
      }),
      hyprToplevels: hyprToplevels,
      hyprWorkspaces: hyprWorkspaces,
      hyprMonitors: hyprMonitors,
      minimizedOrigins: windowActions ? windowActions.minimizedOriginsSnapshot : ({}),
      focusedWorkspace: focusedScopeWorkspace,
      dockMonitor: dockHyprMonitor,
      filteredToplevels: filteredToplevels
    })
    if (groupedRequested) {
      var nextPresentation = desktop.workspacePresentation
      if (badgeTracker && screen)
        badgeTracker.syncWorkspaceScopes(screen.name,
          nextPresentation.groups.reduce(function(items, group) {
            return items.concat(group.items)
          }, []).concat(nextPresentation.globalLaunchers, nextPresentation.fallbackItems))
      if (!WorkspaceModel.presentationsEqual(workspacePresentation, nextPresentation)) {
        windowPreview.dismissImmediately()
        workspacePresentation = nextPresentation
      }
    }
    var nextItems = desktop.visibleItems
    if (!DockModel.visibleItemsEqual(visibleItems, nextItems)) {
      windowPreview.dismissImmediately()
      visibleItems = nextItems
    }
    if (root.revealAfterWorkspaceDrag) {
      root.revealAfterWorkspaceDrag = false
      Qt.callLater(root.revealActiveWorkspace)
    }
    if (workspaceMonitorDrag)
      workspaceMonitorDrag.reconcileCompositorOwnership()
  }

  function scheduleVisibleItemsRefresh() {
    if (root.workspaceDragActive) {
      root.workspacePresentationDirty = true
      workspaceDrag.updatePointer(workspaceDrag.pointerScene)
      return
    }
    visibleItemsRefreshTimer.restart()
  }

  function prepareWorkspacePresentation() {
    root.dragFullscreenModeActive = root.fullscreenModeActive
    root.dragWorkspaceFullscreenOwners = root.liveWorkspaceFullscreenOwners
    root.workspacePresentationDirty = true
    visibleItemsRefreshTimer.stop()
    windowPreview.dismissImmediately()
  }

  function finishWorkspacePresentation() {
    root.workspacePresentationDirty = false
    root.revealAfterWorkspaceDrag = true
    visibleItemsRefreshTimer.restart()
  }

  function openAppPicker(anchor) {
    appPicker.anchorItem = anchor || controlItem
    appPicker.open()
  }

  function focusWorkspaceOnDockMonitor(workspace) {
    var monitor = DockWindowModel.monitorIdentity(root.dockHyprMonitor)
    root.windowActions.dispatchRequests(
      root.windowActions.workspaceOnMonitorRequests(workspace, monitor))
  }

  function cancelWorkspaceGesture(reason) {
    if (workspaceDrag) workspaceDrag.cancel(reason)
    if (workspaceMonitorDrag && (workspaceMonitorDrag.active
        || workspaceMonitorDrag.awaitingConfirmation)
        && (workspaceMonitorDrag.sourceDock === root
          || workspaceMonitorDrag.hoveredTarget === root || dragRevealed))
      workspaceMonitorDrag.cancel(reason)
  }

  function workspaceDropTargetAt(scenePoint) {
    if (!grouped || !windowActions || !groupedLayout.containsScenePoint(scenePoint)) return ""
    for (var i = 0; i < workspaceCards.count; ++i) {
      var slot = workspaceCards.itemAt(i)
      var card = slot ? slot.dropCard : null
      if (!slot || !slot.present || !card || !card.visible) continue
      var point = card.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (point.x < 0 || point.x >= card.width || point.y < 0 || point.y >= card.height) continue
      var destination = windowActions.resolveWorkspaceDropTarget(slot.workspaceIdentity)
      if (!destination) return ""
      if (workspaceMonitorScope === "current-monitor") {
        var monitor = DockWindowModel.canonicalMonitorIdentity(dockHyprMonitor, hyprMonitors)
        if (!monitor || destination.monitor !== monitor) return ""
      }
      return destination.identity
    }
    return ""
  }


  function newWorkspaceMonitorForCard(workspaceIdentity, present) {
    if (present !== true || !windowActions) return ""
    var wanted = String(workspaceIdentity || "")
    if (!wanted) return ""
    var groups = workspaceDisplayPresentation.groups || []
    var sourceIndex = -1
    var owner = ""
    for (var i = 0; i < groups.length; ++i) {
      var group = groups[i]
      if (!group || String(group.identity || "") !== wanted) continue
      sourceIndex = i
      owner = String(group.monitorIdentity || monitorIdentity || "")
      break
    }
    if (sourceIndex < 0 || !owner) return ""
    var canonical = windowActions.canonicalMonitorIdentity(owner)
    if (!canonical) return ""
    for (var nextIndex = sourceIndex + 1; nextIndex < groups.length; ++nextIndex) {
      var next = groups[nextIndex]
      if (!next || next._monitorDragPlaceholder === true) continue
      var nextOwner = String(next.monitorIdentity || monitorIdentity || "")
      if (windowActions.canonicalMonitorIdentity(nextOwner) === canonical)
        return ""
    }
    return canonical
  }

  function newWorkspaceDropMonitorAt(scenePoint) {
    if (!grouped || !workspaceDragActive || !windowActions
        || !groupedLayout.containsScenePoint(scenePoint)) return ""
    for (var i = 0; i < workspaceCards.count; ++i) {
      var wrapper = workspaceCards.itemAt(i)
      var target = wrapper ? wrapper.newWorkspaceDropTarget : null
      if (!wrapper || !wrapper.present || !target || !target.visible) continue
      var point = target.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (point.x < 0 || point.x >= target.width
          || point.y < 0 || point.y >= target.height) continue
      return windowActions.canonicalMonitorIdentity(target.monitorIdentity)
    }
    return ""
  }

  function primaryBadgeOwnerFor(index) {
    return BadgeModel.isPrimaryVisibleItem(renderedItems, index)
  }

  function attentionBadgeFor(item, index) {
    var badgeRevision = badgeStateRevision
    if (!attentionBadgesEnabled || !badgeTracker || !item) return "none"
    var owner = primaryBadgeOwnerFor(index)
    var browserRows = browserActivitiesFor(item)
    var scope = grouped || !owner
      ? ({ localUrgent: item.localUrgent === true, primaryOwner: owner })
      : null
    return badgeTracker.badgeFor(item.desktopId, scope, browserRows)
  }

  function emptyHerdrSummary() {
    return {
      count: 0, indicatorStatus: "", counters: [], rows: [],
      herdrWindowCount: 0, blockedTransitionRevision: 0,
      blockedAddresses: []
    }
  }

  function sourceIndicatorsEnabled(toplevel) {
    var bridge = root.herdrWindowAgents
    var windowKey = bridge && typeof bridge.windowKeyFor === "function"
      ? bridge.windowKeyFor(toplevel) : ""
    var byWindowKey = bridge && bridge.herdrAssociations
      && bridge.herdrAssociations.byWindowKey
      ? bridge.herdrAssociations.byWindowKey : ({})
    var serverId = windowKey ? byWindowKey[windowKey] : ""
    var servers = bridge && bridge.snapshot && Array.isArray(bridge.snapshot.servers)
      ? bridge.snapshot.servers : []
    for (var i = 0; i < servers.length; ++i) {
      var server = servers[i]
      if (!server || String(server.id || "") !== String(serverId || "")) continue
      var source = HerdrModel.serverSource(server)
      if (source === "t3") return root.dockT3Indicators
      if (source === "claude") return root.dockClaudeIndicators
      return root.dockHerdrIndicators
    }
    return root.dockHerdrIndicators
  }

  function herdrSummaryFor(item) {
    if (!root.anyAgentIndicators || !root.herdrWindowAgents || !item)
      return root.emptyHerdrSummary()
    var revision = root.herdrWindowAgents.indicatorRevision
    return root.herdrWindowAgents.summaryForToplevels((item.toplevels || []).filter(root.sourceIndicatorsEnabled))
  }

  function herdrServerLabel(serverId) {
    var servers = root.herdrWindowAgents && root.herdrWindowAgents.snapshot
      && Array.isArray(root.herdrWindowAgents.snapshot.servers)
      ? root.herdrWindowAgents.snapshot.servers : []
    for (var i = 0; i < servers.length; ++i) {
      var server = servers[i]
      if (server && String(server.id || "") === String(serverId || ""))
        return HerdrModel.serverSource(server) !== "herdr"
          ? HerdrModel.serverProduct(server)
          : HerdrModel.serverDisplayLabel(server)
    }
    return "Herdr"
  }

  function herdrServerForPreview(agents) {
    var first = Array.isArray(agents) && agents.length ? agents[0] : null
    var serverId = first && String(first.serverId || "")
    if (!serverId || !root.herdrWindowAgents || !root.herdrWindowAgents.snapshot) return null
    var servers = root.herdrWindowAgents.snapshot.servers
    if (!Array.isArray(servers)) return null
    for (var i = 0; i < servers.length; ++i) {
      if (servers[i] && String(servers[i].id || "") === serverId) return servers[i]
    }
    return null
  }

  function herdrPreviewProductFor(agents) {
    var server = root.herdrServerForPreview(agents)
    return server ? HerdrModel.serverProduct(server) : "Herdr"
  }

  function herdrPreviewFocusHintFor(agents) {
    var server = root.herdrServerForPreview(agents)
    return server ? HerdrModel.focusHint(server) : "Click a row to focus its pane."
  }

  function herdrPreviewAgentsFor(item) {
    if (!root.anyAgentIndicators || !root.herdrWindowAgents || !item) return []
    var revision = root.herdrWindowAgents.indicatorRevision
    var rows = []
    ;((item.toplevels || []).filter(root.sourceIndicatorsEnabled)).forEach(function(toplevel) {
      var summary = root.herdrWindowAgents.summaryForToplevels([toplevel])
      ;(summary.rows || []).forEach(function(agent) {
        rows.push(Object.assign({}, agent, {
          toplevel: toplevel,
          serverLabel: root.herdrServerLabel(agent.serverId)
        }))
      })
    })
    return HerdrModel.sortAgentsForDisplay(rows)
  }

  function herdrPreviewLabelFor(agents) {
    var labels = []
    ;(agents || []).forEach(function(agent) {
      var label = String(agent && agent.serverLabel || "").trim()
      if (label && label !== "Herdr" && label !== "T3 Code"
          && label !== "Claude" && labels.indexOf(label) < 0)
        labels.push(label)
    })
    return labels.join(" · ")
  }

  function allItemWindowsHerdrAssociated(item) {
    if (!root.anyAgentIndicators || !root.herdrWindowAgents
        || !root.herdrWindowAgents.snapshotReady || !item) return false
    var toplevels = item.toplevels || []
    if (!toplevels.length) return false
    return toplevels.every(function(toplevel) {
      var windowKey = root.herdrWindowAgents.windowKeyFor(toplevel)
      var serverId = root.herdrWindowAgents.herdrAssociations.byWindowKey[windowKey]
      return !!serverId && root.herdrWindowAgents.liveServerById(serverId) !== null
    })
  }

  function herdrReplacesAttentionFor(item, summary, attentionBadge) {
    if (!item || !summary || summary.indicatorStatus !== "blocked"
        || String(attentionBadge || "") !== "urgent") return false
    var blocked = summary.blockedAddresses || []
    if (!blocked.length) return false
    var urgent = Array.isArray(item.urgentAddresses)
      ? item.urgentAddresses.map(function(address) {
          return String(address || "").toLowerCase()
        }).filter(function(address) { return address !== "" })
      : root.badgeTracker && typeof root.badgeTracker.urgentAddressesFor === "function"
        ? root.badgeTracker.urgentAddressesFor(item.desktopId,
            BadgeModel.entryForDesktopId(item.desktopId, root.applications)) : []
    return urgent.length > 0 && urgent.every(function(address) {
      return blocked.indexOf(String(address || "").toLowerCase()) >= 0
    })
  }

  function revealActiveWorkspace() {
    if (!grouped || root.workspaceDragActive || !root.activeCardIdentity) return
    for (var i = 0; i < workspaceCards.count; ++i) {
      var card = workspaceCards.itemAt(i)
      if (card && card.present && card.workspaceIdentity === root.activeCardIdentity) {
        groupedLayout.ensureVisible(card.dropCard, card.headerWidth)
        break
      }
    }
  }

  function reorderOffset(index) {
    if (dragSource < 0 || dragTarget < 0) return 0
    if (dragSource < dragTarget && index > dragSource && index <= dragTarget)
      return -itemSize
    if (dragSource > dragTarget && index >= dragTarget && index < dragSource)
      return itemSize
    return 0
  }

  function visiblePinnedTargetIndex(position) {
    var candidateIndex = Math.floor(position / itemSize)
    var nearestIndex = -1
    var nearestDistance = Infinity

    for (var i = 0; i < visibleItems.length; ++i) {
      if (!visibleItems[i] || !visibleItems[i].pinned) continue

      var distance = Math.abs(i - candidateIndex)
      if (distance < nearestDistance
          || (distance === nearestDistance && i > nearestIndex)) {
        nearestIndex = i
        nearestDistance = distance
      }
    }

    return nearestIndex
  }

  function updateDragTarget(position) {
    dragTarget = visiblePinnedTargetIndex(position)
  }

  function finishDrag() {
    var from = dragSource
    var to = dragTarget
    var sourceItem = from >= 0 && from < visibleItems.length
      ? visibleItems[from] : null
    var targetItem = to >= 0 && to < visibleItems.length
      ? visibleItems[to] : null
    dragSource = -1
    dragTarget = -1
    if (sourceItem && targetItem && sourceItem.pinned && targetItem.pinned
        && from !== to) {
      reorderRequested(String(sourceItem.desktopId),
        String(targetItem.desktopId))
    }
  }

  function updateAutoHideState() {
    if (!autoHide) {
      hideTimer.stop()
      autoHideRevealed = false
    } else if (keepAutoHideOpen) {
      hideTimer.stop()
      autoHideRevealed = true
    } else if (autoHideRevealed) {
      hideTimer.restart()
    }
  }

  onAutoHideChanged: updateAutoHideState()
  onKeepAutoHideOpenChanged: updateAutoHideState()
  onOpenMenuCountChanged: if (openMenuCount > 0) windowPreview.dismissImmediately()
  onDragSourceChanged: if (dragSource >= 0) windowPreview.dismissImmediately()
  onShowPreviewsChanged: if (!showPreviews) windowPreview.dismissImmediately()
  onSettingsChanged: { root.cancelWorkspaceGesture("settings changed"); root.scheduleVisibleItemsRefresh() }
  onPositionChanged: root.cancelWorkspaceGesture("dock edge changed")
  onScreenChanged: root.cancelWorkspaceGesture("screen changed")
  onWidthChanged: root.cancelWorkspaceGesture("surface resized")
  onHeightChanged: root.cancelWorkspaceGesture("surface resized")
  onVisibleChanged: if (!visible) root.cancelWorkspaceGesture("surface hidden")
  onDockShownChanged: if (!dockShown && workspaceMonitorDrag && workspaceMonitorDrag.active && workspaceMonitorDrag.hoveredTarget === root) workspaceMonitorDrag.cancel("destination hidden")
  onPinnedChanged: root.scheduleVisibleItemsRefresh()
  onWorkspaceMonitorScopeChanged: root.scheduleVisibleItemsRefresh()
  onWorkspaceMonitorOrderChanged: root.scheduleVisibleItemsRefresh()
  onFocusedScopeWorkspaceChanged: root.scheduleVisibleItemsRefresh()
  onSortByWorkspaceChanged: root.scheduleVisibleItemsRefresh()
  onGroupedChanged: {
    root.cancelWorkspaceGesture("layout changed")
    windowPreview.dismissImmediately()
    dragSource = -1
    dragTarget = -1
    if (!grouped && badgeTracker && screen) badgeTracker.syncWorkspaceScopes(screen.name, [])
    if (grouped) Qt.callLater(root.revealActiveWorkspace)
  }
  onDockHyprMonitorChanged: {
    root.cancelWorkspaceGesture("monitor mapping changed")
    root.scheduleVisibleItemsRefresh()
  }
  onHyprMonitorsChanged: {
    root.cancelWorkspaceGesture("monitor inventory changed")
    root.scheduleVisibleItemsRefresh()
  }
  onHyprWorkspacesChanged: root.scheduleVisibleItemsRefresh()
  Component.onDestruction: {
    root.cancelWorkspaceGesture("surface destroyed")
    if (root.externalDragNavigation)
      root.externalDragNavigation.cancelOwner(root)
    if (workspaceMonitorDrag) workspaceMonitorDrag.unregisterDock(root)
    if (badgeTracker && screen) badgeTracker.syncWorkspaceScopes(screen.name, [])
  }
  onWorkspaceCountsRevisionChanged: root.scheduleVisibleItemsRefresh()
  onWorkspaceGroupsChanged: {
    if (windowPreview) windowPreview.dismissImmediately()
    root.scheduleVisibleItemsRefresh()
  }
  onHiddenApplicationsChanged: root.scheduleVisibleItemsRefresh()
  onScopeRevisionChanged: {
    if (windowPreview) windowPreview.dismissImmediately()
    root.scheduleVisibleItemsRefresh()
  }

  Component.onCompleted: {
    workspaceMonitorDrag.registerDock(root)
    root.scheduleVisibleItemsRefresh()
  }

  Connections {
    target: root.windowActions
    function onMinimizedOriginsSnapshotChanged() { root.scheduleVisibleItemsRefresh() }
  }

  Connections {
    target: root.badgeTracker

    function onRevisionChanged() {
      root.badgeStateRevision++
      root.scheduleVisibleItemsRefresh()
    }
  }

  Timer {
    id: visibleItemsRefreshTimer

    interval: 0
    repeat: false
    onTriggered: root.refreshVisibleItems()
  }

  Timer {
    id: visibleItemsRawEventTimer

    interval: 80
    repeat: false
    onTriggered: root.scheduleVisibleItemsRefresh()
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      var name = event ? event.name : ""
      if (["windowtitle", "windowtitlev2"].indexOf(String(name)) >= 0)
        visibleItemsRawEventTimer.restart()
    }
  }

  Connections {
    target: DesktopEntries.applications
    ignoreUnknownSignals: true

    function onValuesChanged() {
      root.scheduleVisibleItemsRefresh()
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    ignoreUnknownSignals: true

    function onValuesChanged() {
      root.scheduleVisibleItemsRefresh()
    }
  }

  Connections {
    target: Hyprland.toplevels

    function onValuesChanged() {
      root.scheduleVisibleItemsRefresh()
    }
  }

  anchors {
    top: position === "top" || (vertical && fullLength)
    bottom: position === "bottom" || (vertical && fullLength)
    left: position === "left" || (!vertical && fullLength)
    right: position === "right" || (!vertical && fullLength)
  }
  implicitWidth: vertical
    ? crossExtent
    : fullLength ? 0 : grouped && screen ? screen.width : compactPanelExtent
  implicitHeight: vertical
    ? fullLength ? 0 : compactMainExtent
    : crossExtent
  color: "transparent"
  exclusionMode: reserveSpace ? ExclusionMode.Normal : ExclusionMode.Ignore
  WlrLayershell.exclusiveZone: reserveSpace ? reservedSize : 0
  WlrLayershell.namespace: "smartdock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  mask: Region {
    item: root.dockShown ? interactionArea : revealStrip
  }

  DockWorkspaceDrag {
    id: workspaceDrag
    anchors.fill: parent
    z: 100
    enabled: false
    visible: active
    windowActions: root.windowActions
    targetAtScenePoint: root.workspaceDropTargetAt
    newWorkspaceTargetAtScenePoint: root.newWorkspaceDropMonitorAt
    iconSize: root.iconSize
    accent: Color.accent
    background: Color.background
    foreground: Color.background
    fontFamily: Style.font.family
    fontSize: Style.font.bodySmall
    artworkDelegate: Component {
      DockAppIcon {
        desktopId: workspaceDrag.sourceItem ? workspaceDrag.sourceItem.desktopId : ""
        desktopIcon: workspaceDrag.sourceItem && workspaceDrag.sourceItem.entry
          ? workspaceDrag.sourceItem.entry.icon || "" : ""
        iconOverrides: root.iconOverrides
        windowOverrideSource: workspaceDrag.sourceItem
          ? String(workspaceDrag.sourceItem.windowOverrideSource || "") : ""
        reloadRevision: root.iconReloadRevision
      }
    }
    onAboutToBegin: root.prepareWorkspacePresentation()
    onEnded: root.finishWorkspacePresentation()
  }

  Item {
    id: workspaceMonitorDragProxy
    visible: root.workspaceMonitorDragActive
      && root.workspaceMonitorDrag.pointerDock === root
      && root.workspaceMonitorDrag.ghostUrl !== ""
    enabled: false
    z: 101
    readonly property point pointerLocal: Qt.point(
      root.workspaceMonitorDrag.pointerVirtual.x - root.sceneOrigin.x,
      root.workspaceMonitorDrag.pointerVirtual.y - root.sceneOrigin.y)
    width: Math.max(1, root.workspaceMonitorDrag.ghostSize.width)
    height: Math.max(1, root.workspaceMonitorDrag.ghostSize.height)
    x: pointerLocal.x - root.workspaceMonitorDrag.grabOffset.x
    y: pointerLocal.y - root.workspaceMonitorDrag.grabOffset.y

    Image {
      anchors.fill: parent
      source: root.workspaceMonitorDrag.ghostUrl
      fillMode: Image.PreserveAspectFit
      asynchronous: false
    }
  }

  Timer {
    id: hideTimer

    interval: 800
    onTriggered: if (root.autoHide && !root.keepAutoHideOpen)
      root.autoHideRevealed = false
  }

  Item {
    id: interactionArea

    // Keep the grouped native surface stable while cards resize inside it.
    // The compact input region leaves the transparent sides click-through.
    width: root.grouped && !root.fullLength
      ? Math.min(parent.width, root.compactPanelExtent) : parent.width
    height: parent.height
    x: (parent.width - width) / 2

    // Whole-dock visibility hold for a content drag. It is passive: it only
    // keeps the surface reachable while the pointer is on any dock pixel, and
    // it never cancels the more specific icon/header target it encloses.
    DockExternalDragArea {
      id: dockSurfaceDrag

      anchors.fill: parent
      navigation: root.externalDragNavigation
      owner: root
      navigationEnabled: !!root.externalDragNavigation
      targetDescriptor: ({
        key: "reveal:surface:" + String(root.screen && root.screen.name || ""),
        kind: "reveal",
        passive: true
      })
    }
  }

  Item {
    id: revealStrip

    x: root.vertical ? (root.position === "right" ? parent.width - width : 0)
      : interactionArea.x
    y: root.position === "bottom" ? parent.height - height : 0
    width: root.vertical ? root.revealThickness : interactionArea.width
    height: root.vertical ? parent.height : root.revealThickness

    // The existing hidden-dock hit strip is the reveal trigger. It only holds
    // visibility: entering it never arms or cancels an activation.
    DockExternalDragArea {
      id: revealStripDrag

      anchors.fill: parent
      navigation: root.externalDragNavigation
      owner: root
      navigationEnabled: !!root.externalDragNavigation
      targetDescriptor: ({
        key: "reveal:strip:" + String(root.screen && root.screen.name || ""),
        kind: "reveal",
        passive: true
      })
    }
  }

  Connections {
    target: root.externalDragNavigation
    ignoreUnknownSignals: true
    function onPreviewRequested(owner, key, anchor) {
      root.requestExternalPreview(owner, key, anchor)
    }
  }

  BorderSurface {
    id: dockBackground

    x: root.vertical
      ? root.position === "left" ? root.edgeMargin : parent.width - width - root.edgeMargin
      : interactionArea.x + (root.compactGroupedSurface ? root.groupedSurfaceGutter : 0)
    y: root.vertical
      ? 0
      : root.position === "top" ? root.edgeMargin : parent.height - height - root.edgeMargin
    width: root.vertical ? root.iconSize + 44
      : interactionArea.width - (root.compactGroupedSurface ? root.groupedSurfaceGutter * 2 : 0)
    height: root.vertical ? parent.height : root.iconSize + (root.grouped ? 32 : 44)
    radius: Math.max(18, Style.cornerRadius)
    color: root.dockBackgroundColor
    borderSpec: root.dockBorderSpec
    transform: Translate {
      id: dockAutoHideOffset
      x: !root.autoHide || root.dockShown
        ? 0
        : root.position === "left"
          ? -(dockBackground.width + root.edgeMargin)
          : root.position === "right" ? dockBackground.width + root.edgeMargin : 0
      y: !root.autoHide || root.dockShown
        ? 0
        : root.position === "top"
          ? -(dockBackground.height + root.edgeMargin)
          : root.position === "bottom" ? dockBackground.height + root.edgeMargin : 0

      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    Rectangle {
      x: dockBackground.radius
      y: Math.max(1, Border.top(root.dockBorderSpec))
      width: Math.max(0, parent.width - x * 2)
      height: 1
      visible: !root.borderColorEnabled && !root.borderWidthEnabled
      color: Qt.rgba(root.dockBorderColor.r, root.dockBorderColor.g,
        root.dockBorderColor.b, root.dockBorderColor.a * root.dockBackgroundColor.a * 0.12)
    }

    DockPositionDragSurface {
      id: positionDragSurface

      anchors.fill: parent
      dockPosition: root.position
      requestedPosition: root.settings.position
      switchThreshold: 48
      presentationMode: root.presentationMode
      gestureToken: root.modeGestureToken
      sidebarEdge: root.sidebarPreviewEdge
      animationsEnabled: root.interfaceAnimationsEnabled
      interactionAllowed: root.dockShown
        && root.dragSource < 0
        && !root.workspaceDragActive
        && !root.workspaceMonitorDragSourceActive
        && root.openMenuCount === 0
        && !windowPreview.interactionActive
        && !appPicker.visible
      onPositionRequested: (position, expectedPosition, gestureToken) =>
        root.positionRequested(position, expectedPosition, gestureToken)
    }

    Item {
      id: dockLayout

      width: parent.width + (root.compactGroupedSurface ? root.groupedSurfaceTrim : 0)
      height: parent.height

      readonly property real leadingEnd: root.mainPadding + root.itemSize
      readonly property real trailingStart: (root.vertical ? height : width)
        - root.mainPadding - root.trailingMainExtent
      readonly property real trashOffset: root.showTrash
        ? (root.vertical ? appTrashSeparator.height : appTrashSeparator.width)
          + root.trashMainExtent : 0
      readonly property real centeredAppStart: ((root.vertical ? height : width)
        - root.appMainExtent) / 2
      readonly property real appStart: root.fullLength
        ? Math.max(leadingEnd, Math.min(centeredAppStart,
            Math.max(leadingEnd, trailingStart - root.appMainExtent)))
        : leadingEnd

      Rectangle {
        id: monitorDropSectionGlow
        readonly property rect section: {
          var identity = root.workspaceMonitorDropIdentity
          return identity ? root.monitorDropSectionRect() : Qt.rect(0, 0, 0, 0)
        }
        visible: section.width > 0 && section.height > 0
        enabled: false
        z: 80
        x: section.x
        y: section.y
        width: section.width
        height: section.height
        radius: Math.max(12, Style.cornerRadius - 4)
        color: Util.alpha(Color.accent, 0.12)
        border.color: Color.accent
        border.width: 2
      }

      DockControlItem {
        id: controlItem

        enabled: !root.workspaceDragActive
        x: root.vertical ? (parent.width - width) / 2 : root.mainPadding
        y: root.vertical ? root.mainPadding : (parent.height - height) / 2
        controlCommand: root.controlCommand
        windowActions: root.windowActions
        slotSize: root.itemSize
        iconSize: root.iconSize
        magnification: root.workspaceDragActive ? 1 : root.magnification
        magnificationRadius: root.magnificationRadius
        hoverGlowEnabled: root.hoverGlowEnabled
        hoverGlowOpacity: root.hoverGlowOpacity
        hoverGlowRadius: root.hoverGlowRadius
        pointerPosition: root.pointerPosition
        autoHide: root.autoHide
        position: root.position
        vertical: root.vertical
        interfaceAnimationsEnabled: root.interfaceAnimationsEnabled
        modeGestureToken: root.modeGestureToken
        onAddApplicationRequested: root.openAppPicker(controlItem)
        onSettingsRequested: anchor => root.settingsRequested(anchor)
        Component.onCompleted: if (root.host) root.host.registerSettingsAnchor(controlItem, root.screen ? root.screen.name : "", "classic")
        Component.onDestruction: if (root.host) root.host.unregisterSettingsAnchor(controlItem)
        onAutoHideToggled: enabled => root.autoHideRequested(enabled)
        onSwitchToSidebarRequested: token =>
          root.menuModeSwitchRequested(token)
        onContextMenuVisibilityChanged: visible => {
          root.openMenuCount = Math.max(0, root.openMenuCount + (visible ? 1 : -1))
        }
      }

      Grid {
        id: appGrid
        visible: !root.grouped

        x: root.vertical ? (parent.width - width) / 2 : parent.appStart
        y: root.vertical ? parent.appStart : (parent.height - height) / 2
        columns: root.vertical ? 1 : Math.max(1, root.visibleItems.length)
        rows: root.vertical ? Math.max(1, root.visibleItems.length) : 1

        Repeater {
          model: root.grouped ? [] : root.visibleItems

          AppIcon {}
        }
      }

      DockWorkspaceLayout {
        id: groupedLayout
        visible: root.grouped
        x: dockLayout.appStart
        width: Math.max(0, Math.min(desiredWidth, dockLayout.trailingStart - x))
        height: root.crossExtent - root.edgeMargin
        y: root.position === "top" ? 0 : dockLayout.height - height
        rowY: root.position === "top" ? (dockLayout.height - root.itemSize - 10) / 2
          : height - (dockLayout.height + root.itemSize + 10) / 2
        contentPadding: Math.ceil(root.iconSize * (root.magnification
          * DockModel.fullscreenIconPresentation(
            root.groupedFullscreenModeActive,
            root.groupedFullscreenModeActive, false).scale - 1) / 2) + 1
        foreground: Color.menu.text
        background: Color.menu.background
        accent: Color.accent
        animationsEnabled: root.interfaceAnimationsEnabled
        windowDragActive: root.workspaceDragActive
        monitorDragActive: root.workspaceMonitorDragActive
        dragScenePosition: root.workspaceDragActive ? workspaceDrag.pointerScene
          : root.workspaceMonitorDragActive ? Qt.point(
              root.workspaceMonitorDrag.pointerVirtual.x - root.sceneOrigin.x,
              root.workspaceMonitorDrag.pointerVirtual.y - root.sceneOrigin.y)
          : Qt.point(0, 0)
        onViewportChanged: {
          windowPreview.refreshAnchorGeometry()
        }
        onViewportMovementFinished: {
          if (root.workspaceMonitorDrag && root.workspaceMonitorDrag.active) {
            root.workspaceMonitorDrag.refreshTargetGeometry(root)
            root.workspaceMonitorDrag.updatePointer(root.workspaceMonitorDrag.pointerScene)
          }
          if (root.workspaceDragActive) workspaceDrag.updatePointer(workspaceDrag.pointerScene)
        }
        DockPresentationModel {
          id: workspacePresentationModel
          sourceItems: root.groupedRequested ? root.workspaceDisplayPresentation.groups : []
          keyProperty: "identity"
          animationsEnabled: root.interfaceAnimationsEnabled
        }
        Row {
          spacing: Math.max(0, root.pinnedIconGap - (root.itemSize - root.iconSize))
          Repeater {
          model: root.groupedRequested ? root.workspacePresentation.globalLaunchers : []
          AppIcon {
            y: 2
            fullscreenModeActive: false
            fullscreenEmphasized: false
          }
          }
        }
        Repeater {
          id: workspaceCards
          model: workspacePresentationModel.model

          Item {
            id: workspaceCardWrapper
            required property var modelData
            required property int index
            readonly property string workspaceIdentity: modelData.item.identity
            readonly property bool present: modelData.present
            readonly property Item dropCard: workspaceCard
            readonly property bool active: workspaceCard.active
            readonly property real headerWidth: workspaceCard.headerWidth
            readonly property var monitorSection: WorkspaceModel.monitorGroupForWorkspace(
              root.workspaceDisplayPresentation.monitorGroups, workspaceIdentity, present)
            readonly property string sectionMonitorIdentity: String(
              (modelData.item && modelData.item.monitorIdentity)
              || (monitorSection && monitorSection.identity) || "")
            readonly property bool hasMonitorPrefix: root.showMonitorPrefixes
              && monitorSection !== null
            readonly property var cardMonitorSection: monitorSection !== null
              ? monitorSection : WorkspaceModel.monitorGroupForMonitor(
                root.workspaceDisplayPresentation.monitorGroups, sectionMonitorIdentity)
            readonly property int monitorSectionIndex: WorkspaceModel.monitorGroupIndexForMonitor(
              root.workspaceDisplayPresentation.monitorGroups, String(
                (cardMonitorSection && cardMonitorSection.identity)
                || sectionMonitorIdentity || ""))
            readonly property bool isFirstMonitorSection: monitorSectionIndex === 0
            readonly property bool cardMonitorFocused: {
              if (!root.showMonitorPrefixes) return true
              if (cardMonitorSection) return cardMonitorSection.focused === true
              return false
            }
            readonly property real prefixGap: hasMonitorPrefix
              ? Style.spacing.controlGap : 0
            readonly property string newWorkspaceMonitorIdentity:
              root.newWorkspaceMonitorForCard(workspaceIdentity, present)
            readonly property bool hasNewWorkspaceTarget: root.workspaceDragActive
              && newWorkspaceMonitorIdentity !== ""
            readonly property real newWorkspaceGap: hasNewWorkspaceTarget
              ? Style.spacing.controlGap : 0
            readonly property Item newWorkspaceDropTarget: newWorkspaceTarget
            width: monitorPrefix.width + prefixGap + workspaceCardSlot.width
              + newWorkspaceGap + newWorkspaceTarget.width
            height: root.itemSize + 10

            Row {
              id: monitorPrefix
              visible: workspaceCardWrapper.hasMonitorPrefix
              width: visible ? implicitWidth : 0
              height: parent.height
              spacing: 0

              DockSeparator {
                y: (monitorPrefix.height - height) / 2
                visible: workspaceCardWrapper.isFirstMonitorSection
                vertical: false
                slotSize: root.itemSize
                iconSize: root.iconSize
              }

              // Center the separator: its left side gets the last pinned
              // icon's inset plus the grouped row's 8px spacing; the glyph's
              // own side bearing supplies about half of that spacing here.
              // Later monitor sections get a plain gap instead of a line.
              Item {
                width: workspaceCardWrapper.isFirstMonitorSection
                  ? Math.round((root.itemSize - root.iconSize) / 2) + Style.spacing.sm
                  : Style.spacing.controlGap * 2
                height: 1
              }

              DockMonitorLabel {
                label: workspaceCardWrapper.monitorSection
                  ? String(workspaceCardWrapper.monitorSection.label || "") : ""
                description: workspaceCardWrapper.monitorSection
                  ? String(workspaceCardWrapper.monitorSection.description || "") : ""
                connector: workspaceCardWrapper.monitorSection
                  ? String(workspaceCardWrapper.monitorSection.connector || "") : ""
                focused: workspaceCardWrapper.monitorSection
                  ? workspaceCardWrapper.monitorSection.focused === true : false
                monitorNumber: workspaceCardWrapper.monitorSectionIndex + 1
                position: root.position
                slotSize: root.itemSize
              }
            }

            DockAnimatedSlot {
              id: workspaceCardSlot
              property var modelData: workspaceCardWrapper.modelData
              property int index: workspaceCardWrapper.index
              x: monitorPrefix.width + workspaceCardWrapper.prefixGap
              present: modelData.present && modelData.item._monitorDragOccupied !== false
              animateEntrance: modelData.animateEntrance
              animationsEnabled: root.interfaceAnimationsEnabled
              exitRevision: modelData.exitRevision
              naturalWidth: modelData.item._monitorDragPlaceholder
                ? Math.max(1, root.workspaceMonitorDrag.ghostSize.width)
                : workspaceCard.width
              naturalHeight: modelData.item._monitorDragPlaceholder
                ? Math.max(1, root.workspaceMonitorDrag.ghostSize.height)
                : workspaceCard.height
              trailingGap: 0
              onExitFinished: revision => workspacePresentationModel.completeRemoval(
                modelData.token, revision)

              DockWorkspaceGroup {
                id: workspaceCard
                visible: !workspaceCardSlot.modelData.item._monitorDragPlaceholder
                animationsEnabled: root.interfaceAnimationsEnabled
                modelData: workspaceCardSlot.modelData.item
                property var modelData
                label: modelData.label
                workspaceIdentity: modelData.identity
                workspaceOwnerMonitor: String(modelData.monitorIdentity || "")
                navigation: root.externalDragNavigation
                navigationOwner: root
                workspaceMonitorDrag: root.workspaceMonitorDrag
                workspaceMonitorDragDock: root
                switchable: !modelData._monitorDragPlaceholder
                showFullLabel: modelData.showFullLabel === true
                count: modelData.count
                urgent: modelData.urgent === true && root.attentionBadgesEnabled
                windowDragActive: root.workspaceDragActive
                monitorFocused: workspaceCardWrapper.cardMonitorFocused
                dropHighlighted: root.workspaceDragActive && workspaceDrag.hoveredIdentity === modelData.identity
                position: root.position
                viewport: groupedLayout
                active: modelData.active
                slotSize: root.itemSize
                applicationModel: modelData._monitorDragPlaceholder ? null : appPresentationModel.model
                applicationDelegate: Component {
                  DockAnimatedSlot {
                    id: appSlot
                    required property var modelData
                    required property int index
                    present: modelData.present
                    animateEntrance: modelData.animateEntrance
                    animationsEnabled: root.interfaceAnimationsEnabled
                    exitRevision: modelData.exitRevision
                    naturalWidth: root.itemSize
                    naturalHeight: root.itemSize + 6
                    trailingGap: index < appPresentationModel.entries.length - 1 ? 6 : 0
                    onExitFinished: revision => appPresentationModel.completeRemoval(
                      modelData.token, revision)
                    AppIcon {
                      modelData: appSlot.modelData.item
                      index: appSlot.index
                      workspaceActivationTarget: workspaceCard.modelData.activationTarget
                      presentationActive: appSlot.modelData.present
                        && workspaceCardSlot.modelData.present
                      fullscreenModeActive:
                        root.workspaceFullscreenOwners[workspaceCard.modelData.identity] !== undefined
                      fullscreenEmphasized: {
                        var owner =
                          root.workspaceFullscreenOwners[workspaceCard.modelData.identity]
                        return owner !== undefined
                          && modelData.toplevels.indexOf(owner) >= 0
                      }
                    }
                  }
                }
                onActivated: pullToMonitor => {
                  var target = modelData.activationTarget
                  if (pullToMonitor === true)
                    root.focusWorkspaceOnDockMonitor(target)
                  else
                    root.windowActions.focusWorkspaceInPlace(target)
                }
              }

              Rectangle {
                visible: workspaceCardSlot.modelData.item._monitorDragPlaceholder === true
                width: workspaceCardSlot.naturalWidth
                height: workspaceCardSlot.naturalHeight
                radius: Math.max(12, Style.cornerRadius - 4)
                color: Util.alpha(Color.foreground, 0.06)
                border.width: 1
                border.color: Util.alpha(Color.foreground, 0.18)
                enabled: false
              }

              DockPresentationModel {
                id: appPresentationModel
                sourceItems: workspaceCard.modelData.items
                keyProperty: "presentationId"
                animationsEnabled: root.interfaceAnimationsEnabled
              }
            }

            DockNewWorkspaceDropTarget {
              id: newWorkspaceTarget
              visible: workspaceCardWrapper.hasNewWorkspaceTarget
              x: workspaceCardSlot.x + workspaceCardSlot.width
                + workspaceCardWrapper.newWorkspaceGap
              monitorIdentity: workspaceCardWrapper.newWorkspaceMonitorIdentity
              slotSize: root.itemSize
              highlighted: workspaceDrag.hoveredNewWorkspaceMonitor === monitorIdentity
              animationsEnabled: root.interfaceAnimationsEnabled
            }
          }
        }
        DockWorkspaceGroup {
          visible: root.groupedRequested && root.workspacePresentation.fallbackItems.length > 0
          label: "Other windows"
          position: root.position
          viewport: groupedLayout
          navigation: root.externalDragNavigation
          navigationOwner: root
          windowDragActive: root.workspaceDragActive
          count: root.workspacePresentation.fallbackItems.reduce(function(total, item) {
            return total + item.toplevels.length
          }, 0)
          active: false
          switchable: false
          slotSize: root.itemSize
          Repeater {
            model: root.groupedRequested ? root.workspacePresentation.fallbackItems : []
            AppIcon {
              fullscreenModeActive: false
              fullscreenEmphasized: false
            }
          }
        }
      }

      DockSeparator {
        id: appTrashSeparator

        x: root.vertical ? (parent.width - width) / 2 : parent.trailingStart
        y: root.vertical ? parent.trailingStart : (parent.height - height) / 2
        vertical: root.vertical
        slotSize: root.itemSize
        iconSize: root.iconSize
        visible: root.showTrash
      }

      DockTrashItem {
        id: trashItem

        x: root.vertical
          ? (parent.width - width) / 2
          : parent.trailingStart + appTrashSeparator.width
        y: root.vertical
          ? parent.trailingStart + appTrashSeparator.height
          : (parent.height - height) / 2
        visible: root.showTrash
        enabled: root.showTrash && !root.workspaceDragActive
        trashItemCount: root.trashItemCount
        trashStateKnown: root.trashStateKnown
        slotSize: root.itemSize
        iconSize: root.iconSize
        magnification: root.workspaceDragActive ? 1 : root.magnification
        magnificationRadius: root.magnificationRadius
        hoverGlowEnabled: root.hoverGlowEnabled
        hoverGlowOpacity: root.hoverGlowOpacity
        hoverGlowRadius: root.hoverGlowRadius
        pointerPosition: root.pointerPosition
        position: root.position
        interfaceAnimationsEnabled: root.interfaceAnimationsEnabled
        vertical: root.vertical
        onOpenRequested: root.openTrashRequested()
        onEmptyRequested: root.emptyTrashRequested()
        onContextMenuVisibilityChanged: visible => {
          root.openMenuCount = Math.max(0, root.openMenuCount + (visible ? 1 : -1))
        }
      }

      DockSeparator {
        id: trashWorkspaceSeparator

        x: root.vertical
          ? (parent.width - width) / 2
          : parent.trailingStart + (root.showTrash ? appTrashSeparator.width + trashItem.width : 0)
        y: root.vertical
          ? parent.trailingStart + (root.showTrash ? appTrashSeparator.height + trashItem.height : 0)
          : (parent.height - height) / 2
        visible: !root.grouped
        vertical: root.vertical
        slotSize: root.itemSize
        iconSize: root.iconSize
      }

      DockWorkspaceStrip {
        id: workspaceStrip
        visible: !root.grouped

        x: root.vertical
          ? (parent.width - width) / 2
          : parent.trailingStart + parent.trashOffset + (root.showTrash ? 0 : 12)
        y: root.vertical
          ? parent.trailingStart + parent.trashOffset + (root.showTrash ? 0 : 12)
          : (parent.height - height) / 2
        workspaceIds: root.visibleWorkspaceIds
        workspaces: root.hyprWorkspaces
        hyprToplevels: root.hyprToplevels
        workspaceWindowCounts: root.workspaceWindowCounts
        workspaceCountsReady: root.workspaceCountsReady
        workspaceStateRevision: root.workspaceStateRevision + root.workspaceCountsRevision
        focusedWorkspaceId: root.focusedWorkspaceId
        vertical: root.vertical
        slotSize: root.itemSize
        iconSize: root.iconSize
        position: root.position
        animationsEnabled: root.interfaceAnimationsEnabled
        navigation: root.externalDragNavigation
        navigationOwner: root
        onWorkspaceRequested: (workspaceId, pullToMonitor) => {
          if (pullToMonitor === true)
            root.focusWorkspaceOnDockMonitor(workspaceId)
          else
            root.windowActions.focusWorkspaceInPlace(workspaceId)
        }
      }
    }

    HoverHandler {
      id: pointer
      parent: root.vertical ? dockBackground : dockLayout
    }
  }

  component AppIcon: DockItem {
    id: appItem
    required property var modelData
    required property int index
    originOnly: modelData.presentationId !== undefined
    scopeRevision: root.scopeRevision
    presentationId: modelData.presentationId || modelData.desktopId
    identityToplevel: modelData.identityToplevel || null
    workspaceDrag: root.workspaceDragController
    workspaceDragEnabled: root.grouped && appItem.originOnly
    activationMonitor: DockWindowModel.monitorIdentity(root.dockHyprMonitor)

    desktopId: modelData.desktopId
    navigation: root.externalDragNavigation
    navigationOwner: root
    localWorkspaceIdentity: String(modelData.localWorkspaceIdentity || "")
    iconOverrides: root.iconOverrides
    windowOverrideSource: String(modelData.windowOverrideSource || "")
    iconReloadRevision: root.iconReloadRevision
    browserProfileService: root.browserProfileService
    browserProfileKey: root.profileKeyFor(modelData)
    browserProfileBadgesEnabled: root.browserProfileBadgesEnabled
    previewActivities: root.browserActivitiesFor(modelData)
    readonly property var dockHerdrPreviewAgents:
      root.herdrPreviewAgentsFor(modelData)
    previewAgents: dockHerdrPreviewAgents
    previewHerdrOnly: dockHerdrPreviewAgents.length > 0
      && root.allItemWindowsHerdrAssociated(modelData)
    previewHerdrLabel: root.herdrPreviewLabelFor(dockHerdrPreviewAgents)
    previewHerdrProduct: root.herdrPreviewProductFor(dockHerdrPreviewAgents)
    previewHerdrFocusHint: root.herdrPreviewFocusHintFor(dockHerdrPreviewAgents)
    previewHerdrCounters: dockHerdrSummary.counters || []
    pinnedItem: modelData.pinned
    runningToplevels: modelData.toplevels
    focused: root.activeToplevel !== null
      && modelData.toplevels.indexOf(root.activeToplevel) >= 0
    windowActions: root.windowActions
    herdrAgentActions: root.herdrAgentActions
    hyprToplevels: root.hyprToplevels
    badgeTracker: root.badgeTracker
    readonly property var dockHerdrSummary: root.herdrSummaryFor(modelData)
    readonly property int renderedIndex: {
      if (!originOnly) return index
      var items = root.renderedItems
      return items.indexOf(PreviewModel.visiblePreviewTarget(
        items, presentationId, identityToplevel))
    }
    localUrgent: modelData.localUrgent === true
    sticky: modelData.sticky === true
    attentionScopeKey: originOnly && root.badgeTracker && root.screen
      ? root.badgeTracker.workspaceScopeKey(root.screen.name, modelData.presentationId) : ""
    attentionBadge: root.attentionBadgeFor(modelData, renderedIndex)
    herdrSummary: dockHerdrSummary
    herdrWindowCount: Number(dockHerdrSummary.herdrWindowCount || 0)
    herdrReplacesAttention: root.herdrReplacesAttentionFor(
      modelData, dockHerdrSummary, attentionBadge)
    attentionBadgesEnabled: root.attentionBadgesEnabled
    urgentWindowAnimationEnabled: root.urgentWindowAnimationEnabled
    interfaceAnimationsEnabled: root.interfaceAnimationsEnabled
    presentationActive: true
    primaryBadgeOwner: root.primaryBadgeOwnerFor(renderedIndex)
    presentationVisible: !originOnly || groupedLayout.containsItem(appItem)
    Connections {
      target: groupedLayout
      function onViewportChanged() {
        if (groupedLayout.viewportWidth <= 0) return
        appItem.presentationVisible = !appItem.originOnly || groupedLayout.containsItem(appItem)
        if (!appItem.presentationVisible) appItem.dismissPopups()
        else appItem.refreshPopupGeometry()
      }
    }
    dockShown: root.dockShown
    fullscreenModeActive: root.fullscreenModeActive
    fullscreenEmphasized:
      modelData.toplevels.indexOf(root.fullscreenOwnerToplevel) >= 0
    itemIndex: index
    slotSize: root.itemSize
    iconSize: root.iconSize
    magnification: root.magnification
    magnificationRadius: root.magnificationRadius
    hoverGlowEnabled: root.hoverGlowEnabled
    hoverGlowOpacity: root.hoverGlowOpacity
    hoverGlowRadius: root.hoverGlowRadius
    pointerPosition: !pointer.hovered || !parent ? -10000 : root.vertical
      ? parent.mapFromItem(dockBackground, pointer.point.position.x, pointer.point.position.y).y
      : parent.mapFromItem(dockLayout, pointer.point.position.x, pointer.point.position.y).x
    applicationActions: root.applicationActions
    showPreviews: root.showPreviews
    workspaceBadgeBackgroundColor: root.effectiveWorkspaceBadgeBackgroundColor
    workspaceBadgeTextColor: root.effectiveWorkspaceBadgeTextColor
    autoHide: root.autoHide
    position: root.position
    vertical: root.vertical
    previewActive: windowPreview.anchorItem === appItem
      && windowPreview.interactionActive
    reorderOffset: originOnly ? 0 : root.reorderOffset(index)
    onDragStarted: itemIndex => {
      root.dragSource = itemIndex
      root.dragTarget = itemIndex
    }
    onDragMoved: mainPosition => root.updateDragTarget(mainPosition)
    onDragFinished: root.finishDrag()
    onRemoveRequested: desktopId => root.unpinRequested(desktopId)
    onHideRequested: desktopId => root.hideRequested(desktopId)
    onPreviewRequested: (anchorItem, desktopId, toplevels, applicationEntry) => {
      if (root.workspaceDragActive) return
      windowPreview.requestPreview(
        anchorItem, desktopId, toplevels, applicationEntry)
    }
    onPreviewReleased: anchorItem => windowPreview.releasePreview(anchorItem)
    onPreviewDismissRequested: windowPreview.dismissImmediately()
    onContextMenuVisibilityChanged: visible => {
      root.openMenuCount = Math.max(0,
        root.openMenuCount + (visible ? 1 : -1))
    }
  }

  DockWindowPreview {
    id: windowPreview

    windowActions: root.windowActions
    navigation: root.externalDragNavigation
    navigationOwner: root
    herdrAgentActions: root.herdrAgentActions
    activationMonitor: DockWindowModel.monitorIdentity(root.dockHyprMonitor)
    position: root.position
    visibleItems: root.renderedItems
    clipItem: root.grouped ? groupedLayout : null
    iconOverrides: root.iconOverrides
    iconReloadRevision: root.iconReloadRevision
    mutedServices: root.browserActivityMutedServices
    onActivityRequested: activity => root.activateBrowserActivity(
      activity, windowPreview.members)
    onActivityMuteToggled: serviceId => root.browserActivityMuteToggled(serviceId)
  }

  DockAppPicker {
    id: appPicker

    anchorItem: controlItem
    position: root.position
    pinned: root.pinned
    iconOverrides: root.iconOverrides
    iconReloadRevision: root.iconReloadRevision
    onApplicationSelected: desktopId => root.pinRequested(desktopId)
  }

  // Destination silhouette for this renderer's only mode destination: the
  // configured sidebar edge on this dock's own monitor. Inert, non-reserving
  // and never focusable.
  DockModeDragPreview {
    requestedVisible: root.modeDragArmed
    edge: root.modeDragDestinationEdge
    bandExtent: root.sidebarPreviewBand
    edgeInset: 0
    animationsEnabled: root.interfaceAnimationsEnabled
    screen: root.screen
  }

  // Rejected or persistence-pending mode write from this dock's own background
  // gesture, shown with the same non-interactive pill the sidebar gesture uses.
  DockModeDragFeedback {
    text: root.modeGestureFeedback
    animationsEnabled: root.interfaceAnimationsEnabled
    anchors.horizontalCenter: dockBackground.horizontalCenter
    anchors.bottom: dockBackground.top
    anchors.bottomMargin: Style.space(8)
  }

  HoverHandler {
    id: windowPointer
    parent: interactionArea
  }
}
