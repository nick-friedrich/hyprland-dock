pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import qs.Commons
import qs.Ui as Ui
import "DockSidebarModel.js" as SidebarModel
import "DockSidebarInteractionModel.js" as InteractionModel
import "DockIconModel.js" as DockIconModel
import "DockModel.js" as DockModel

FocusScope {
  id: root
  required property var controller
  property Item tabForwardTarget: null
  // Theme-reactive card fills from the owning panel (phase 4).
  property var appearance: null
  // Connector of the owning PanelWindow; rows stamp this for Ctrl/drag.
  property string panelConnector: ""
  // Owning PanelWindow used as the external-drag surface owner. PanelWindow is
  // not a Qt Quick Item, hence the generic object type.
  property var navigationOwner: null
  property bool panelCollapsed: false
  // Effective owning-panel visibility. Rail mode is separately excluded below.
  property bool presentationVisible: true
  // Phase 5 drives whole-workspace hover highlight; chrome already binds it.
  property string hoveredWorkspaceKey: ""
  readonly property var viewProjection: controller.projectionFor(panelCollapsed)
  readonly property var visibleRows: viewProjection.rows
  readonly property var sectionSpans: viewProjection.sectionSpans || []
  readonly property var listView: list
  // The ListView fills this viewport and accepts input over all of it, so it
  // owns every pixel except this region: the part of the viewport that belongs
  // to no delegate and no widget tail. It is only ever the tail below the
  // content, because the list clamps contentY to the origin while content is
  // shorter than the viewport, and it is empty whenever the content overflows —
  // then every pixel is occupied and there is no blank space to claim.
  readonly property var blankRegion: DockModel.sidebarBlankRegion(
    list.contentHeight, list.height, list.contentY, list.width)
  // Allocate from canonical projection metrics, never a virtualized estimate.
  readonly property real naturalContentHeight: {
    var total = 0
    for (var i = 0; i < root.visibleRows.length; ++i)
      total += root.rowMetricsFor(root.visibleRows[i]).height
    return total
  }
  readonly property int rowCount: visibleRows.length
  readonly property real rowHeight: Math.max(34, Math.ceil(metrics.height + Style.space(12)))
  readonly property real workspaceCardInset: Style.space(5)
  // Scrollbar thickness only; the list reserves no gutter. The bar sits
  // scrollBarOutset past the viewport edge, inside the symmetric outer inset.
  readonly property real scrollGutter: 6
  // Nudges the bar past the viewport's right edge toward the panel edge.
  // The left sidebar's right edge also owns the 8px resize handle, so keep
  // the bar inside that hit area; the collapsed rail has only a 6px outer inset.
  readonly property real scrollBarOutset: root.panelCollapsed ? 4 : (root.controller && root.controller.edge === "left" ? 4 : 10)
  readonly property real cardRadius: appearance && appearance.cardRadius !== undefined
    ? appearance.cardRadius : Math.min(3, Style.cornerRadius)
  readonly property color monitorFill: appearance ? appearance.monitorFill
    : Qt.tint(Color.background, Util.alpha(Color.foreground, 0.035))
  readonly property color workspaceFill: appearance ? appearance.workspaceFill
    : Qt.darker(Color.background, 1.04)
  readonly property color workspaceHoverFill: appearance ? appearance.workspaceHoverFill
    : Qt.tint(workspaceFill, Util.alpha(Color.foreground, 0.09))
  readonly property color monitorDropFill: Style.pressedFillFor(Color.accent, Color.accent)
  readonly property var workspaceRects: root.workspaceGroupRects()
  readonly property var workspacePlaceholder: {
    var session = root.controller.dragSession
    var target = root.controller.dragTarget
    if (!session || session.target.kind !== "workspace" || !target) return null
    return InteractionModel.workspacePlaceholderSlot(session.location.identity,
      target.key, root.sectionSpans, root.controller.rowsByKey)
  }
  readonly property real placeholderHeight: root.rowHeight + Style.space(6)
  activeFocusOnTab: true
  property var dragPoint: null
  property bool dropSurfaceReady: false
  property double dropSurfaceGeneration: 0
  property double queuedDropToken: 0
  property double presentedDropToken: 0
  property var gestureSnapshot: null
  property var dropPresentation: null
  property string dropFlashKey: ""
  property real dropFlashOpacity: 0
  property real postDropX: 0
  property real postDropY: 0
  readonly property bool dropAnimations: !root.controller.settings
    || root.controller.settings.interfaceAnimationsEnabled !== false
  signal contextRequested(var target, var anchorItem)
  signal dismissContextRequested()
  signal activationDispatched(var target, bool control, string connector, int modifiers, bool accepted)
  property bool restoring: false
  property bool pendingRestore: false
  property var previousKeys: []
  property real previousRowHeight: rowHeight
  property bool previousCollapsed: false
  // Mode whose list coordinates are valid for capture; updated after restore.
  // onPanelCollapsedChanged sees the new value, so this retains the outgoing mode.
  property bool scrollModeCollapsed: false
  property real previousContentHeight: 0
  property string previousHeightMap: ""
  // Bump when list geometry/model changes so offscreen span estimates refresh.
  property int sectionChromeRevision: 0
  FontMetrics { id: metrics; font.family: Style.font.family; font.pixelSize: Style.font.body }
  Timer {
    id: restoreTimer
    interval: 0
    repeat: false
    onTriggered: root.restoreAnchor()
  }

  function focusLastRow() {
    var key = InteractionModel.nextKey(root.visibleRows, "", "end")
    if (!key) return false
    root.controller.clearAlertControl()
    var row = root.controller.rowsByKey[key]
    if (row && root.controller.rowHasAlertControl(row)) root.controller.alertControlKey = key
    return root.focusRow(key)
  }
  function focusPaneBoundary(backwards) {
    if (backwards || !root.tabForwardTarget || !root.tabForwardTarget.visible) return false
    root.tabForwardTarget.forceActiveFocus(Qt.TabFocusReason)
    return true
  }

  function rowIntersectsViewport(rowY, rowHeightValue) {
    return root.presentationVisible && !root.panelCollapsed
      && InteractionModel.viewportIntersects(rowY, rowHeightValue, list.contentY, list.height)
  }

  function estimatedRowHeight(row) {
    var attention = root.controller.attentionForRow(row)
    var hasAlert = InteractionModel.sidebarRowHasNumericAlert(
      root.panelCollapsed, attention.countVisible)
    var base = InteractionModel.estimatedSidebarRowHeight(row, root.panelCollapsed,
      root.rowHeight, Style.space, hasAlert)
    if (root.windowFooterActive()
        && InteractionModel.isMonitorFinalKey(row.key, root.sectionSpans))
      return base + root.footerExtraHeight()
    return base + root.placeholderBefore(row.key) + root.placeholderAfter(row.key)
  }

  function rowMetricsFor(row) {
    var attention = root.controller.attentionForRow(row)
    var hasAlert = InteractionModel.sidebarRowHasNumericAlert(
      root.panelCollapsed, attention.countVisible)
    var metrics = InteractionModel.sidebarRowMetrics(row, root.panelCollapsed,
      root.rowHeight, Style.space, hasAlert)
    if (root.windowFooterActive()
        && InteractionModel.isMonitorFinalKey(row.key, root.sectionSpans)) {
      var extra = root.footerExtraHeight()
      metrics.gapAfter += extra
      metrics.height += extra
    }
    var before = root.placeholderBefore(row.key), after = root.placeholderAfter(row.key)
    metrics.contentY += before
    metrics.gapBefore += before
    metrics.gapAfter += after
    metrics.height += before + after
    return metrics
  }

  function placeholderBefore(key) {
    return root.workspacePlaceholder && root.workspacePlaceholder.beforeKey === key ? root.placeholderHeight : 0
  }

  function placeholderAfter(key) {
    return root.workspacePlaceholder && root.workspacePlaceholder.afterKey === key ? root.placeholderHeight : 0
  }

  function placeholderY() {
    var slot = root.workspacePlaceholder
    if (!slot) return 0
    var key = slot.beforeKey || slot.afterKey
    var index = root.indexForKey(key)
    if (index < 0) return 0
    var metrics = root.rowMetricsFor(root.visibleRows[index])
    return root.contentRowY(index) + (slot.beforeKey ? metrics.contentY : metrics.height) - root.placeholderHeight
  }

  function windowFooterActive() {
    var session = root.controller.dragSession
    return !!(root.controller.rowDragActive && session
      && session.target && session.target.kind === "window")
  }

  function footerTargetHeight() {
    return InteractionModel.newWorkspaceFooterTargetHeight(root.panelCollapsed)
  }

  function footerExtraHeight() {
    return InteractionModel.newWorkspaceFooterExtra(root.panelCollapsed, Style.space)
  }

  function isMonitorFinalKey(key) {
    return InteractionModel.isMonitorFinalKey(key, root.sectionSpans)
  }

  function footerKeyForRowKey(rowKey) {
    if (!InteractionModel.isMonitorFinalKey(rowKey, root.sectionSpans)) return ""
    var spans = root.sectionSpans
    for (var i = 0; i < spans.length; ++i) {
      var span = spans[i]
      if (!span || span.kind !== "monitor" || span.lastKey !== rowKey) continue
      var monitorRow = root.controller.rowsByKey[span.key]
      var identity = monitorRow ? String(monitorRow.monitorIdentity || "") : ""
      if (!identity) return ""
      return InteractionModel.newWorkspaceFooterKey(identity)
    }
    return ""
  }

  function refreshDragTarget() {
    if (!root.controller.rowDragActive || root.dragPoint === null) return
    root.controller.updateRowDrag(root.dropKey())
  }







  function heightMap() {
    var rows = root.visibleRows
    var parts = []
    for (var i = 0; i < rows.length; ++i) {
      var item = list.itemAtIndex(i)
      parts.push(item ? Math.round(item.height) : Math.round(root.estimatedRowHeight(rows[i])))
    }
    return parts.join(",")
  }

  function rowYAtIndex(index) {
    var item = list.itemAtIndex(index)
    if (item) return item.y
    var y = 0
    var rows = root.visibleRows
    for (var i = 0; i < index && i < rows.length; ++i)
      y += root.estimatedRowHeight(rows[i])
    return y
  }

  // Content-coordinate Y for section painters: prefer live item.y, else
  // originY + shared-metrics prefix (same alert-aware heights as the ListView).
  function contentRowY(index) {
    var _rev = root.sectionChromeRevision
    var item = list.itemAtIndex(index)
    if (item) return item.y
    var y = list.originY
    var rows = root.visibleRows
    for (var i = 0; i < index && i < rows.length; ++i)
      y += root.estimatedRowHeight(rows[i])
    return y
  }

  function indexForKey(key) {
    var rows = root.visibleRows
    for (var i = 0; i < rows.length; ++i) {
      if (rows[i].key === key) return i
    }
    return -1
  }

  // Phase-3 span Y contract for painters.
  function sectionSpanRect(span) {
    var _rev = root.sectionChromeRevision
    if (!span || !span.firstKey || !span.lastKey)
      return { y: 0, height: 0 }
    var firstIdx = root.indexForKey(span.firstKey)
    var lastIdx = root.indexForKey(span.lastKey)
    if (firstIdx < 0 || lastIdx < 0)
      return { y: 0, height: 0 }
    var rows = root.visibleRows
    var firstM = root.rowMetricsFor(rows[firstIdx])
    var lastM = root.rowMetricsFor(rows[lastIdx])
    var top = root.contentRowY(firstIdx) + firstM.contentY
    var bottom = span.kind === "workspace"
      ? root.contentRowY(lastIdx) + lastM.contentY + lastM.contentHeight + Style.space(5)
      : root.contentRowY(lastIdx) + lastM.contentY + lastM.contentHeight + lastM.gapAfter
    return { y: top, height: Math.max(0, bottom - top) }
  }

  function workspaceGroupRects() {
    var spans = root.sectionSpans, items = []
    for (var i = 0; i < spans.length; ++i) {
      var span = spans[i]
      if (!span || span.kind !== "workspace") continue
      var row = root.controller.rowsByKey[span.firstKey]
      if (!row) continue
      var geom = root.sectionSpanRect(span)
      items.push({key:span.key, monitorKey:row.monitorKey,
        workspaceIdentity:row.workspaceIdentity, y:geom.y, height:geom.height})
    }
    return InteractionModel.workspaceGroupRects(items, list.width,
      root.workspaceCardInset)
  }

  function workspacePaintRect(key) {
    var rects = root.workspaceRects
    for (var i = 0; i < rects.length; ++i) if (rects[i].key === key) return rects[i]
    return {x:0,y:0,width:0,height:0}
  }

  function bumpSectionChrome() {
    root.sectionChromeRevision += 1
  }

  function captureAnchor() {
    // Never write during restore or while list rows belong to a different mode.
    if (root.restoring || root.pendingRestore || !list.count) return
    if (root.scrollModeCollapsed !== root.panelCollapsed) return
    var index = list.indexAt(1, list.contentY + 1)
    if (index < 0) {
      var rows = root.visibleRows
      var y = 0
      index = 0
      for (var i = 0; i < rows.length; ++i) {
        var next = y + root.estimatedRowHeight(rows[i])
        if (list.contentY + 1 < next) { index = i; break }
        y = next
        index = i
      }
    }
    var row = root.visibleRows[index]
    var item = list.itemAtIndex(index)
    var keys = root.visibleRows.map(function(value) { return value.key })
    if (row) {
      root.controller.writeScrollState(root.panelConnector, root.panelCollapsed, {
        key: row.key,
        offset: list.contentY - (item ? item.y : root.rowYAtIndex(index))
      }, keys)
    }
    root.previousKeys = keys
    root.previousRowHeight = root.rowHeight
    root.previousCollapsed = root.panelCollapsed
    root.previousContentHeight = list.contentHeight
    root.previousHeightMap = root.heightMap()
  }

  function requestRestore() {
    // Avoid nested restore while forceLayout/contentY settle.
    if (root.restoring) return
    var keys = root.visibleRows.map(function(value) { return value.key })
    var map = root.heightMap()
    if (!InteractionModel.shouldRestoreScroll({
      keys: root.previousKeys, rowHeight: root.previousRowHeight,
      collapsed: root.previousCollapsed, contentHeight: root.previousContentHeight,
      heightMap: root.previousHeightMap
    }, {
      keys: keys, rowHeight: root.rowHeight, collapsed: root.panelCollapsed,
      contentHeight: list.contentHeight, heightMap: map
    })) {
      root.pendingRestore = false
      root.scrollModeCollapsed = root.panelCollapsed
      return
    }
    root.pendingRestore = true
    restoreTimer.restart()
  }

  function restoreAnchor() {
    root.restoring = true
    list.forceLayout()
    var rows = root.visibleRows
    var state = root.controller.readScrollState(root.panelConnector, root.panelCollapsed)
    var oldKeys = state.keys.length ? state.keys : root.previousKeys
    var anchor = SidebarModel.recoverAnchor(state.anchor, oldKeys, rows)
    var index = rows.findIndex(function(row) { return row.key === anchor.key })
    if (index >= 0) {
      list.positionViewAtIndex(index, ListView.Beginning)
      list.forceLayout()
      var item = list.itemAtIndex(index)
      var desired = (item ? item.y : root.rowYAtIndex(index)) + anchor.offset
      list.contentY = Math.min(Math.max(list.originY, desired),
        Math.max(list.originY, list.contentHeight - list.height + list.originY))
    } else list.contentY = list.originY
    var keys = rows.map(function(row) { return row.key })
    root.controller.writeScrollState(root.panelConnector, root.panelCollapsed, anchor, keys)
    root.previousKeys = keys
    root.previousRowHeight = root.rowHeight
    root.previousCollapsed = root.panelCollapsed
    root.previousContentHeight = list.contentHeight
    root.previousHeightMap = root.heightMap()
    root.scrollModeCollapsed = root.panelCollapsed
    root.pendingRestore = false
    root.restoring = false
    root.bumpSectionChrome()
  }

  function activate(target, control, connector, modifiers) {
    var accepted = root.controller.activateTarget(
      target, control, connector, Number(modifiers || 0))
    root.activationDispatched(target, control === true, connector, modifiers, accepted)
    return accepted
  }

  function focusRow(key, preferInlineWorkspaceBadge) {
    var rows = root.visibleRows
    var index = rows.findIndex(function(row) { return row.key === key })
    if (index < 0 || !InteractionModel.focusable(rows[index])) return false
    if (root.controller.alertControlKey && root.controller.alertControlKey !== key)
      root.controller.clearAlertControl()
    root.controller.rememberNavigationFocus()
    root.controller.focusedRowKey = key
    list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    var item = list.itemAtIndex(index)
    if (item) {
      if (preferInlineWorkspaceBadge === true
          && item.leadingWorkspaceBadgeVisible === true
          && typeof item.focusInlineWorkspaceBadge === "function")
        item.focusInlineWorkspaceBadge(Qt.TabFocusReason)
      else {
        // Keyboard navigation always shows focus, even on a row the pointer
        // focused earlier.
        if (item.pointerFocused === true) item.pointerFocused = false
        item.forceActiveFocus(Qt.TabFocusReason)
      }
    }
    return item !== null
  }

  function currentDelegate() {
    var index = root.visibleRows.findIndex(function(row) {
      return row.key === root.controller.focusedRowKey
    })
    return index >= 0 ? list.itemAtIndex(index) : null
  }

  function viewportHasKeyboardFocus() {
    var win = root.Window ? root.Window.window : null
    var focusItem = win ? win.activeFocusItem : null
    if (!focusItem) return !!root.activeFocus
    for (var item = focusItem; item; item = item.parent) {
      if (item === root) return true
    }
    return false
  }

  function syncFocusForProjection() {
    var hadFocus = root.viewportHasKeyboardFocus()
    var next = SidebarModel.remapFocusKey(root.controller.focusedRowKey, root.visibleRows,
      root.controller.rowsByKey)
    if (next !== root.controller.focusedRowKey)
      root.controller.focusedRowKey = next
    // Restore only when this viewport already owned keyboard focus (no steal).
    if (hadFocus && next)
      root.focusRow(next)
  }

  function cancelInputs(reason) {
    for (var i = 0; i < list.count; ++i) {
      var item = list.itemAtIndex(i)
      if (item && item.input) item.input.cancelGesture(reason)
    }
    root.controller.cancelRowDrag(reason)
    root.dragPoint = null
    root.hoveredWorkspaceKey = ""
  }

  function rowHits() {
    var hits = []
    var footerActive = root.windowFooterActive()
    var extra = footerActive ? root.footerExtraHeight() : 0
    for (var i = 0; i < list.count; ++i) {
      var item = list.itemAtIndex(i)
      if (!item || !item.visible) continue
      var point = root.mapFromItem(item, 0, 0)
      var height = item.height
      if (footerActive && extra > 0
          && InteractionModel.isMonitorFinalKey(item.rowKey, root.sectionSpans))
        height = Math.max(0, height - extra)
      hits.push({key:item.rowKey, kind:item.row.kind,
        workspaceIdentity:item.row.workspaceIdentity || "",
        monitorIdentity:item.row.monitorIdentity || "",
        x:point.x, y:point.y, width:item.width, height:height})
    }
    return hits
  }

  function footerHits() {
    var hits = []
    if (!root.windowFooterActive()) return hits
    var viewport = { x: 0, y: 0, width: root.width, height: root.height }
    var extra = root.footerExtraHeight()
    var target = root.footerTargetHeight()
    var separation = Style.space(5)
    for (var i = 0; i < list.count; ++i) {
      var item = list.itemAtIndex(i)
      if (!item || !item.visible) continue
      if (!InteractionModel.isMonitorFinalKey(item.rowKey, root.sectionSpans)) continue
      var footerKey = root.footerKeyForRowKey(item.rowKey)
      if (!footerKey) continue
      var monitorIdentity = InteractionModel.parseNewWorkspaceFooterKey(footerKey)
      if (!monitorIdentity) continue
      var origin = root.mapFromItem(item, 0, 0)
      var inset = root.workspaceCardInset
      var rect = {
        x: origin.x + inset,
        y: origin.y + Math.max(0, item.height - extra) + separation,
        width: Math.max(0, item.width - inset * 2),
        height: target
      }
      var clipped = InteractionModel.clipRect(rect, viewport)
      if (!clipped) continue
      hits.push({
        key: footerKey,
        kind: "new-workspace",
        monitorIdentity: monitorIdentity,
        x: clipped.x, y: clipped.y, width: clipped.width, height: clipped.height
      })
    }
    return hits
  }

  // Workspace drops use painted monitor-card spans (headers, rows, padding,
  // empty interior), clipped to this hierarchy viewport — not footer/header
  // or gaps between cards. Keys remain the monitor row keys.
  function monitorCardHits() {
    var viewport = { x: 0, y: 0, width: root.width, height: root.height }
    var hits = []
    var spans = root.sectionSpans
    for (var i = 0; i < spans.length; ++i) {
      var span = spans[i]
      if (!span || span.kind !== "monitor") continue
      var geom = root.sectionSpanRect(span)
      if (!(geom.height > 0)) continue
      var origin = root.mapFromItem(list.contentItem, 0, geom.y)
      var clipped = InteractionModel.clipRect({
        x: origin.x, y: origin.y, width: list.width, height: geom.height
      }, viewport)
      if (!clipped) continue
      var row = root.controller.rowsByKey[span.key]
      hits.push({
        key: span.key,
        kind: "monitor",
        monitorIdentity: row ? (row.monitorIdentity || "") : "",
        x: clipped.x, y: clipped.y, width: clipped.width, height: clipped.height
      })
    }
    return hits
  }

  function workspaceSpanHits() {
    var viewport = {x:0,y:0,width:root.width,height:root.height}, hits = []
    var rects = root.workspaceRects
    for (var i = 0; i < rects.length; ++i) {
      var rect = rects[i]
      var origin = root.mapFromItem(list.contentItem, rect.x, rect.y)
      var clipped = InteractionModel.clipRect({x:origin.x,y:origin.y,
        width:rect.width,height:rect.height}, viewport)
      if (clipped) hits.push(Object.assign({}, rect, clipped))
    }
    return hits
  }

  // Windows may hit only header/top or unclaimed bottom padding. Workspace
  // rows and their side gutters never inherit a whole-card monitor fallback.
  function monitorHeaderHits() {
    var viewport = {x:0,y:0,width:root.width,height:root.height}, hits = []
    for (var i = 0; i < root.sectionSpans.length; ++i) {
      var span = root.sectionSpans[i]
      if (!span || span.kind !== "monitor") continue
      var geom = root.sectionSpanRect(span)
      var row = root.controller.rowsByKey[span.key]
      var groups = root.workspaceRects.filter(function(rect) { return rect.monitorKey === span.key })
      var bottom = geom.y + geom.height - (root.windowFooterActive() ? root.footerExtraHeight() : 0)
      var regions = groups.length ? [
        {y:geom.y, height:Math.max(0, groups[0].y - geom.y)},
        {y:groups[groups.length-1].y + groups[groups.length-1].height,
          height:Math.max(0, bottom - groups[groups.length-1].y - groups[groups.length-1].height)}
      ] : [{y:geom.y, height:Math.max(0, bottom-geom.y)}]
      for (var j = 0; j < regions.length; ++j) {
        var origin = root.mapFromItem(list.contentItem, 0, regions[j].y)
        var clipped = InteractionModel.clipRect({x:origin.x,y:origin.y,
          width:list.width,height:regions[j].height}, viewport)
        if (clipped) hits.push(Object.assign({key:span.key,kind:"monitor",headerOnly:true,
          monitorIdentity:row ? row.monitorIdentity : ""}, clipped))
      }
    }
    return hits
  }

  function dropKey() {
    if (!root.controller.dragSession) return ""
    var sourceKind = root.controller.dragSession.target.kind
    var viewport = {x:0,y:0,width:root.width,height:root.height}
    if (sourceKind === "workspace")
      return InteractionModel.hitTarget(root.dragPoint, root.monitorCardHits(), viewport, sourceKind)
    return InteractionModel.hitWindowDrop(root.dragPoint, root.footerHits(),
      root.workspaceSpanHits(), root.monitorHeaderHits(), viewport,
      root.controller.dragTarget ? root.controller.dragTarget.key : "")
  }

  function renewDropSurface() {
    if (!root.dropSurfaceReady) return
    if (root.dropSurfaceGeneration) root.controller.releaseDropSurface(root.dropSurfaceGeneration)
    root.dropSurfaceGeneration = root.presentationVisible
      ? root.controller.registerDropSurface(root.panelConnector) : 0
    root.gestureSnapshot = null
    root.clearDropPresentation()
  }

  function snapshotDragPresentation() {
    var session = root.controller.dragSession
    if (!session || session.originSurfaceGeneration !== root.dropSurfaceGeneration || !root.dragPoint) return
    var row = dragGhost.sourceRow
    root.gestureSnapshot = {sourceKey:session.target.key, sourceKind:session.target.kind,
      x:dragGhost.x, y:dragGhost.y, title:ghostTitle.text,
      desktopId:row ? String(row.desktopId || "") : "",
      desktopIcon:row && row.item && row.item.entry ? String(row.item.entry.icon || "") : "",
      windowOverrideSource:dragGhost.sourceWindowRule ? String(dragGhost.sourceWindowRule.source || "") : ""}
  }

  function isOwnDrop(operation) {
    return !!operation && root.presentationVisible
      && operation.originSurfaceGeneration === root.dropSurfaceGeneration
      && operation.originConnector === root.panelConnector
      && root.controller.dropOriginIsCurrent(operation)
  }

  function clearDropPresentation() {
    dropFeedbackTimer.stop()
    dropFlashFade.stop()
    dropSnapX.stop()
    dropSnapY.stop()
    root.dropPresentation = null
    root.dropFlashKey = ""
    root.dropFlashOpacity = 0
    root.queuedDropToken = 0
  }

  // One captured callback per event/token. When restoration is busy, its
  // completion signals request the next check; never a callLater retry loop.
  function queueDropPresentation() {
    var operation = root.controller.dropOperation
    if (!root.isOwnDrop(operation)) { root.clearDropPresentation(); return }
    if (operation.state === "submitting" || root.queuedDropToken === operation.token) return
    var token = operation.token, generation = root.dropSurfaceGeneration
    root.queuedDropToken = token
    Qt.callLater(function() {
      if (root.dropSurfaceGeneration !== generation || root.queuedDropToken !== token) return
      root.queuedDropToken = 0
      root.presentDropOperation(token)
    })
  }

  function presentDropOperation(token) {
    var operation = root.controller.dropOperation
    if (!root.isOwnDrop(operation) || operation.token !== token) return
    if (!root.controller.dropEntityAlive(operation)) { root.controller.endDropOperation(token); return }
    if (operation.state === "confirmed") root.presentConfirmedDrop(token)
    else if (["pending", "rejected", "cancelled", "unconfirmed"].indexOf(operation.state) >= 0)
      root.showDropFeedback(operation)
  }

  function dropRowIndex(operation) {
    return root.visibleRows.findIndex(function(row) {
      return row.kind === "window" && row.toplevel === operation.toplevel
        && DockModel.normalizeWindowAddress(row.address) === operation.address
        && row.workspaceIdentity === operation.expectedWorkspace
    })
  }

  function dropWorkspaceSpan(operation, source) {
    var identity = source ? operation.sourceWorkspace : operation.expectedWorkspace
    var monitor = source ? operation.sourceMonitor : operation.expectedMonitor
    for (var i = 0; i < root.sectionSpans.length; ++i) {
      var span = root.sectionSpans[i]
      if (span.kind !== "workspace") continue
      var row = root.controller.rowsByKey[span.firstKey]
      if (row && row.workspaceIdentity === identity
          && root.controller.windowActions.canonicalMonitorIdentity(row.monitorIdentity) === monitor) return span
    }
    return null
  }

  function presentConfirmedDrop(token) {
    var operation = root.controller.dropOperation
    if (!root.isOwnDrop(operation) || operation.token !== token || operation.state !== "confirmed"
        || root.presentedDropToken === token) return
    if (root.pendingRestore || root.restoring || root.controller.projecting || root.controller.refreshPending) return
    list.forceLayout()
    if (root.pendingRestore || root.restoring) return
    if (!root.controller.dropLocationMatches(operation)) { root.controller.endDropOperation(token); return }
    var index = operation.sourceKind === "window" ? root.dropRowIndex(operation) : -1
    var key = index >= 0 ? root.visibleRows[index].key : ""
    if (index < 0) {
      var span = root.dropWorkspaceSpan(operation, false)
      if (!span) { root.controller.endDropOperation(token); return }
      var geom = root.sectionSpanRect(span)
      // Folded-window fallback may only flash its already visible owning group.
      if (operation.sourceKind === "window" &&
          (geom.y + geom.height <= list.contentY || geom.y >= list.contentY + list.height)) {
        root.controller.endDropOperation(token); return
      }
      index = root.indexForKey(span.firstKey)
      key = span.key
    }
    if (index < 0) { root.controller.endDropOperation(token); return }
    var item = list.itemAtIndex(index)
    if (!item || item.y < list.contentY || item.y + item.height > list.contentY + list.height)
      list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    if (root.pendingRestore || root.restoring || !root.isOwnDrop(operation)) return
    // Any already queued restore now reads the success anchor, not the old one.
    root.captureAnchor()
    root.showDropFlash(token, key)
  }

  function finishDropFeedback(token) {
    if (!root.dropPresentation || root.dropPresentation.token !== token) return
    root.clearDropPresentation()
    root.gestureSnapshot = null
    root.controller.endDropOperation(token)
  }

  function showDropFlash(token, key) {
    root.clearDropPresentation()
    root.presentedDropToken = token
    root.dropPresentation = {token:token, state:"confirmed"}
    root.dropFlashKey = key
    root.dropFlashOpacity = 1
    dropFlashFade.duration = root.dropAnimations ? 400 : 0
    dropFlashFade.start()
    dropFeedbackTimer.operationToken = token
    dropFeedbackTimer.interval = root.dropAnimations ? 400 : 1
    dropFeedbackTimer.restart()
  }

  function sourceDropRect(operation) {
    if (!root.controller.dropSourceIsCurrent(operation)) return null
    var index = operation.sourceKind === "window"
      ? root.visibleRows.findIndex(function(row) {
          return row.key === operation.sourceKey && row.toplevel === operation.toplevel
            && DockModel.normalizeWindowAddress(row.address) === operation.address
        }) : -1
    if (operation.sourceKind === "workspace") {
      var span = root.dropWorkspaceSpan(operation, true)
      if (span && span.key === operation.sourceKey) index = root.indexForKey(span.firstKey)
    }
    if (index < 0) return null
    var item = list.itemAtIndex(index)
    if (!item || item.y + item.height <= list.contentY || item.y >= list.contentY + list.height) return null
    var position = root.mapFromItem(list.contentItem, 0, item.y)
    return {x:position.x,y:position.y}
  }

  function showDropFeedback(operation) {
    if (root.dropPresentation && root.dropPresentation.token === operation.token
        && root.dropPresentation.state === operation.state) return
    if (!root.gestureSnapshot || root.gestureSnapshot.sourceKey !== operation.sourceKey) {
      if (operation.state !== "pending") root.controller.endDropOperation(operation.token)
      return
    }
    var source = null
    if (operation.state === "rejected" || operation.state === "cancelled") {
      source = root.sourceDropRect(operation)
      if (!source) { root.controller.endDropOperation(operation.token); return }
    }
    root.clearDropPresentation()
    root.dropPresentation = {token:operation.token, state:operation.state,
      snapshot:root.gestureSnapshot,
      text:operation.state === "pending" ? "Moving…"
        : operation.state === "unconfirmed" ? "Move not confirmed"
        : operation.state === "rejected" ? "Move not allowed" : ""}
    root.postDropX = root.gestureSnapshot.x
    root.postDropY = root.gestureSnapshot.y
    if (source) {
      dropSnapX.to = InteractionModel.dragProxyOffset(source.x, root.width, postDropPill.width)
      dropSnapY.to = InteractionModel.dragProxyOffset(source.y, root.height, postDropPill.height)
      dropSnapX.duration = dropSnapY.duration = root.dropAnimations ? 200 : 0
      dropSnapX.start(); dropSnapY.start()
    }
    if (operation.state !== "pending") {
      dropFeedbackTimer.operationToken = operation.token
      dropFeedbackTimer.interval = operation.state === "unconfirmed" ? 900 : (root.dropAnimations ? 200 : 1)
      dropFeedbackTimer.restart()
    }
  }

  function moveDrag(scenePoint) {
    root.dragPoint = root.mapFromItem(null, scenePoint.x, scenePoint.y)
    root.controller.updateRowDrag(root.dropKey())
    root.snapshotDragPresentation()
  }

  function finishDrag(scenePoint) {
    root.dragPoint = root.mapFromItem(null, scenePoint.x, scenePoint.y)
    var key = root.dropKey()
    root.snapshotDragPresentation()
    var result = root.controller.finishRowDrag(key)
    root.dragPoint = null
    return result
  }

  readonly property var keyboard: keyboardAdapter
  DockSidebarKeyboard { id: keyboardAdapter; viewport: root }
  Keys.forwardTo: [keyboardAdapter]
  function enterNavigation() {
    if (!root.activeFocus || root.controller.interactionBusy) return
    var item = root.currentDelegate()
    if (item && item.activeFocus) return
    root.focusRow(item ? root.controller.focusedRowKey
      : InteractionModel.nextKey(root.visibleRows, "", "home"))
  }

  // Defer until a pointer-selected child has updated the key. Mapping/hovering
  // never triggers this; re-entry via Tab restores a real visible focus target.
  onActiveFocusChanged: if (activeFocus) Qt.callLater(root.enterNavigation)
  onPanelCollapsedChanged: {
    root.renewDropSurface()
    root.hoveredWorkspaceKey = ""
    // Outgoing mode was already captured while scrollModeCollapsed matched.
    // visibleRows already flipped; never capture new coordinates into either key here.
    var incoming = root.controller.readScrollState(root.panelConnector, root.panelCollapsed)
    if (incoming.keys.length)
      root.previousKeys = incoming.keys
    root.pendingRestore = true
    restoreTimer.restart()
    root.syncFocusForProjection()
    root.bumpSectionChrome()
  }

  Timer {
    interval: 16
    repeat: true
    running: root.controller.rowDragActive && root.dragPoint !== null
    onTriggered: {
      var point = root.dragPoint
      var delta = point && point.x >= 0 && point.x < root.width
        ? InteractionModel.autoScrollStep(point.y, root.height) : 0
      if (!delta) return
      list.contentY = Math.max(list.originY, Math.min(
        Math.max(list.originY, list.contentHeight - list.height + list.originY), list.contentY + delta))
      list.forceLayout()
      if (root.controller.rowDragActive) root.controller.updateRowDrag(root.dropKey())
    }
  }

  ListView {
    id: list
    objectName: "sidebar-window-list"
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: parent.right
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    orientation: ListView.Vertical
    keyNavigationEnabled: false

    // ScriptModel reconciles supplied domain keys; index is geometry only.
    model: ScriptModel { objectProp: "key"; values: root.visibleRows }
    delegate: DockSidebarRow {
      required property var modelData
      readonly property string stableKey: modelData.key
      // Visual metadata differs between expanded and rail projections.
      row: modelData
      controller: root.controller
      viewport: root
      appearance: root.appearance
      panelConnector: root.panelConnector
      navigationOwner: root.navigationOwner
      collapsed: root.panelCollapsed
      rowHeight: root.rowHeight
      herdrAnimationEligible: root.rowIntersectsViewport(y, height)
      width: list.width
    }

    onMovementEnded: root.captureAnchor()
    onContentYChanged: {
      if (!root.pendingRestore) root.captureAnchor()
      root.bumpSectionChrome()
      root.refreshDragTarget()
    }
    onContentHeightChanged: {
      // Rail alert 36→58 (and similar) can grow a row above the viewport without
      // a controller refresh; restore from the mode's saved anchor. Arm pending
      // first so contentY drift cannot overwrite that state via captureAnchor.
      root.bumpSectionChrome()
      root.refreshDragTarget()
      if (root.restoring || root.pendingRestore) return
      root.pendingRestore = true
      root.requestRestore()
    }
    onCountChanged: { root.bumpSectionChrome(); root.refreshDragTarget() }
    onOriginYChanged: { root.bumpSectionChrome(); root.refreshDragTarget() }

    Controls.ScrollBar.horizontal: Controls.ScrollBar {
      policy: Controls.ScrollBar.AlwaysOff
    }
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      id: verticalScrollBar
      parent: root
      // Under pragma ComponentBehavior: Bound this inline attached component
      // evaluates anchor bindings without a valid parent/sibling context, so
      // Qt drops them ("Cannot anchor to an item that isn't a parent or
      // sibling") and the bar parks at x=0. Bind geometry explicitly instead.
      x: root.width - width + root.scrollBarOutset
      y: list.y
      width: root.scrollGutter
      height: list.height
      padding: 0
      policy: list.contentHeight > list.height
        ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
      contentItem: Rectangle {
        implicitWidth: root.scrollGutter
        implicitHeight: 40
        radius: width / 2
        color: Util.alpha(Color.foreground,
          verticalScrollBar.pressed ? 0.45
            : (verticalScrollBar.hovered ? 0.32 : 0.18))
      }
      background: Item {
        implicitWidth: root.scrollGutter
      }
    }

    // Section cards scroll with the list: parented to contentItem, below rows.
    // Monitor z < workspace z < delegates. No nested ListViews; no input.
    Item {
      id: sectionChromeHost
      parent: list.contentItem
      z: -2
      width: list.width
      height: Math.max(list.contentHeight, 1)
      // Direction A rail reuses the same sectionSpans + appearance cards.
      visible: true
      enabled: false

      Repeater {
        id: monitorChrome
        model: ScriptModel { objectProp: "key"; values: root.sectionSpans }
        delegate: Ui.BorderSurface {
          required property var modelData
          required property int index
          readonly property bool isMonitor: modelData && modelData.kind === "monitor"
          readonly property var geom: isMonitor ? root.sectionSpanRect(modelData) : { y: 0, height: 0 }
          readonly property bool dropTargetCard: isMonitor
            && root.controller.dragTarget
            && root.controller.dragTarget.key === modelData.key
          visible: isMonitor && geom.height > 0
          x: 0
          y: geom.y
          width: sectionChromeHost.width
          height: geom.height
          z: 0
          radius: root.cardRadius
          color: dropTargetCard ? root.monitorDropFill : root.monitorFill
          // Only an eligible drag adds a monitor outline; active monitor alone does not.
          borderSpec: dropTargetCard
            ? Border.surfaceSpec("popups", "border", Color.accent, Math.max(1, Style.normalBorderWidth))
            : Border.none()
        }
      }

      Ui.BorderSurface {
        id: workspaceDropPlaceholder
        visible: root.workspacePlaceholder !== null
        x: root.workspaceCardInset + Style.space(4)
        y: root.placeholderY()
        width: Math.max(0, list.width - 2 * x)
        height: root.placeholderHeight - Style.space(6)
        radius: root.cardRadius
        color: Style.normalFillFor(Color.accent, Color.accent)
        borderSpec: Border.none()
        z: 1
        Row {
          x: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          opacity: 0.4
          Text {
            text: root.workspacePlaceholder ? InteractionModel.workspaceBadgeLabel(root.workspacePlaceholder.identity) : ""
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Repeater {
            model: root.panelCollapsed ? [] : dragGhost.workspaceIcons
            DockAppIcon {
              required property var modelData
              width: 18; height: 18
              roundedArtwork: false
              desktopId: String(modelData.desktopId || "")
              desktopIcon: modelData.item && modelData.item.entry ? String(modelData.item.entry.icon || "") : ""
              iconOverrides: root.controller.settings.iconOverrides || ({})
            }
          }
        }
      }

      Repeater {
        id: workspaceChrome
        model: ScriptModel { objectProp: "key"; values: root.sectionSpans }
        delegate: Item {
          required property var modelData
          required property int index
          readonly property bool isWorkspace: modelData && modelData.kind === "workspace"
          readonly property var geom: isWorkspace ? root.workspacePaintRect(modelData.key) : { x:0, y:0, width:0, height:0 }
          readonly property bool dropTargetGroup: isWorkspace && root.windowFooterActive()
            && root.controller.dragTarget && (root.controller.dragTarget.key === modelData.key
              || root.controller.dragTarget.identity === geom.workspaceIdentity)
          visible: isWorkspace && geom.height > 0
          x: geom.x
          y: geom.y
          width: geom.width
          height: geom.height
          z: 1
          enabled: false

          // Fill only: even the final group can highlight, without an outline.
          Rectangle {
            anchors.fill: parent
            radius: root.cardRadius
            color: parent.dropTargetGroup ? root.monitorDropFill : "transparent"
          }
          Rectangle {
            anchors.fill: parent
            radius: root.cardRadius
            color: Util.alpha(Color.accent, 0.22 * root.dropFlashOpacity)
            visible: root.dropFlashKey === modelData.key
          }

          // Separate groups without a second card inside the monitor card.
          Rectangle {
            visible: !InteractionModel.isMonitorFinalKey(modelData.lastKey, root.sectionSpans)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Util.alpha(Color.foreground, 0.06)
          }
        }
      }
    }
  }
  Connections {
    target: root.controller
    function onAboutToRefresh() { root.captureAnchor(); root.pendingRestore = true }
    function onRefreshed() { root.requestRestore(); root.bumpSectionChrome(); root.queueDropPresentation() }
    function onDropOperationChanged() { root.queueDropPresentation() }
    function onSurfaceInvalidated() { root.cancelInputs("surface-invalidated"); root.renewDropSurface() }
    function onRowDragActiveChanged() { if (!root.controller.rowDragActive) root.dragPoint = null }
  }
  onPendingRestoreChanged: if (!root.pendingRestore) root.queueDropPresentation()
  onRestoringChanged: if (!root.restoring) root.queueDropPresentation()
  onPresentationVisibleChanged: root.renewDropSurface()
  onPanelConnectorChanged: root.renewDropSurface()
  onRowHeightChanged: {
    if (!root.previousKeys.length) return
    root.pendingRestore = true
    restoreTimer.restart()
    root.bumpSectionChrome()
  }
  onHeightChanged: root.requestRestore()
  onVisibleRowsChanged: root.bumpSectionChrome()
  Component.onCompleted: {
    root.dropSurfaceReady = true
    root.renewDropSurface()
    root.scrollModeCollapsed = root.panelCollapsed
    root.previousCollapsed = root.panelCollapsed
    root.pendingRestore = true
    restoreTimer.restart()
  }
  // One clipped, noninteractive pill inside the originating panel. It never
  // acquires a window, pointer grab, or action authority of its own.
  Item {
    anchors.fill: parent
    clip: true
    z: 100
    enabled: false
    visible: root.controller.rowDragActive && root.dragPoint !== null
    Ui.BorderSurface {
      id: dragGhost
      x: InteractionModel.dragProxyOffset(root.dragPoint ? root.dragPoint.x + 12 : 0,
        root.width, width)
      y: InteractionModel.dragProxyOffset(root.dragPoint ? root.dragPoint.y + 12 : 0,
        root.height, height)
      width: InteractionModel.dragGhostWidth(root.width, root.panelCollapsed)
      height: root.panelCollapsed ? width : Math.max(root.rowHeight,
        Style.space(12) + ghostTitle.height + (feedback.text ? ghostDetail.height + Style.space(4) : 0))
      color: Color.popups.background
      radius: root.cardRadius
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
      clip: true
      readonly property var sourceRow: root.controller.dragSession
        ? root.controller.rowsByKey[root.controller.dragSession.target.key] : null
      readonly property var feedback: {
        var session = root.controller.dragSession
        var target = root.controller.dragTarget
        var rejection = root.controller.dragRejection
        var state = target || rejection
        var monitor = state && state.monitor && root.controller.windowActions
          ? root.controller.windowActions.monitorNameForIdentity(state.monitor) : ""
        return InteractionModel.formatDragDestination(session ? session.target.kind : "",
          target, rejection, monitor)
      }
      readonly property color feedbackColor: feedback.tone === "urgent" ? Color.urgent
        : feedback.tone === "accent" ? Color.accent : Color.muted
      readonly property var sourceWindowRule: sourceRow && sourceRow.kind === "window" && sourceRow.toplevel
        ? DockIconModel.matchWindowRule(root.controller.windowIconOverrides || [],
            String(sourceRow.toplevel.appId || ""), String(sourceRow.toplevel.title || "")) : null
      readonly property var workspaceIcons: {
        if (!sourceRow || sourceRow.kind !== "workspace" || root.panelCollapsed) return []
        var ids = {}, icons = []
        var rows = root.visibleRows
        for (var i = 0; i < rows.length && icons.length < 3; ++i) {
          var row = rows[i]
          if (row.workspaceIdentity !== sourceRow.workspaceIdentity
              || ["window", "application"].indexOf(row.kind) < 0 || !row.desktopId || ids[row.desktopId]) continue
          ids[row.desktopId] = true
          icons.push(row)
        }
        return icons
      }
      DockAppIcon {
        id: ghostIcon
        visible: dragGhost.sourceRow && dragGhost.sourceRow.kind === "window"
        x: (root.panelCollapsed ? (dragGhost.width - width) / 2 : Style.space(6))
        y: root.panelCollapsed ? (dragGhost.height - height) / 2 : Style.space(6)
        width: Math.min(22, dragGhost.width); height: width
        roundedArtwork: false
        badgeRingColor: dragGhost.color
        desktopId: dragGhost.sourceRow ? String(dragGhost.sourceRow.desktopId || "") : ""
        desktopIcon: dragGhost.sourceRow && dragGhost.sourceRow.item && dragGhost.sourceRow.item.entry
          ? String(dragGhost.sourceRow.item.entry.icon || "") : ""
        iconOverrides: root.controller.settings.iconOverrides || ({})
        windowOverrideSource: dragGhost.sourceWindowRule ? String(dragGhost.sourceWindowRule.source || "") : ""
        reloadRevision: root.controller.host.iconReloadRevision || 0
      }
      Text {
        id: ghostTitle
        x: root.panelCollapsed ? 0 : (ghostIcon.visible ? ghostIcon.x + ghostIcon.width + Style.space(5) : Style.space(6))
        y: root.panelCollapsed ? (dragGhost.height - height) / 2 : Style.space(6)
        width: Math.max(0, dragGhost.width - x - (root.panelCollapsed ? 0 : Style.space(6))
          - workspaceArtwork.width)
        height: Math.max(22, implicitHeight)
        visible: !root.panelCollapsed || !ghostIcon.visible
        text: !dragGhost.sourceRow ? "" : dragGhost.sourceRow.kind === "workspace"
          ? InteractionModel.workspaceBadgeLabel(dragGhost.sourceRow.workspaceIdentity, dragGhost.sourceRow.label)
          : String(dragGhost.sourceRow.toplevel && dragGhost.sourceRow.toplevel.title || dragGhost.sourceRow.label || "")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: root.panelCollapsed ? Text.AlignHCenter : Text.AlignLeft
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Row {
        id: workspaceArtwork
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        y: Style.space(6)
        spacing: Style.space(3)
        visible: !root.panelCollapsed && dragGhost.workspaceIcons.length > 0
        Repeater {
          model: dragGhost.workspaceIcons
          DockAppIcon {
            required property var modelData
            width: 18; height: 18
            roundedArtwork: false
            desktopId: String(modelData.desktopId || "")
            desktopIcon: modelData.item && modelData.item.entry ? String(modelData.item.entry.icon || "") : ""
            iconOverrides: root.controller.settings.iconOverrides || ({})
          }
        }
      }
      Text {
        id: ghostDetail
        x: Style.space(6)
        y: ghostTitle.y + ghostTitle.height + Style.space(4)
        width: Math.max(0, dragGhost.width - 2 * x)
        visible: !root.panelCollapsed && dragGhost.feedback.text !== ""
        text: (dragGhost.feedback.blocked ? "⊘ " : "") + dragGhost.feedback.text
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: dragGhost.feedbackColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
  Timer {
    id: dropFeedbackTimer
    property double operationToken: 0
    repeat: false
    onTriggered: root.finishDropFeedback(operationToken)
  }
  NumberAnimation { id: dropFlashFade; target: root; property: "dropFlashOpacity"; from: 1; to: 0 }
  NumberAnimation { id: dropSnapX; target: root; property: "postDropX"; easing.type: Easing.OutCubic }
  NumberAnimation { id: dropSnapY; target: root; property: "postDropY"; easing.type: Easing.OutCubic }
  Item {
    anchors.fill: parent
    clip: true
    z: 100
    enabled: false
    visible: root.dropPresentation !== null && root.dropPresentation.state !== "confirmed"
      && !root.controller.rowDragActive
    Ui.BorderSurface {
      id: postDropPill
      x: root.postDropX; y: root.postDropY
      width: InteractionModel.dragGhostWidth(root.width, root.panelCollapsed)
      height: root.panelCollapsed ? width : Math.max(root.rowHeight, postDropTitle.implicitHeight + postDropDetail.implicitHeight + Style.space(18))
      radius: root.cardRadius
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
      clip: true
      readonly property var snapshot: root.dropPresentation && root.dropPresentation.snapshot || ({})
      DockAppIcon {
        id: postDropIcon
        visible: postDropPill.snapshot.sourceKind === "window"
        x: root.panelCollapsed ? (postDropPill.width - width) / 2 : Style.space(6)
        y: root.panelCollapsed ? (postDropPill.height - height) / 2 : Style.space(6)
        width: Math.min(22, postDropPill.width); height: width
        roundedArtwork: false
        desktopId: postDropPill.snapshot.desktopId || ""
        desktopIcon: postDropPill.snapshot.desktopIcon || ""
        windowOverrideSource: postDropPill.snapshot.windowOverrideSource || ""
        iconOverrides: root.controller.settings.iconOverrides || ({})
      }
      Text {
        id: postDropTitle
        x: root.panelCollapsed ? 0 : (postDropIcon.visible ? postDropIcon.x + postDropIcon.width + Style.space(4) : Style.space(6))
        y: root.panelCollapsed ? (postDropPill.height-height)/2 : Style.space(6)
        width: Math.max(0, postDropPill.width-x-Style.space(6))
        visible: !root.panelCollapsed || !postDropIcon.visible
        text: postDropPill.snapshot.title || ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Color.foreground
        font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
      }
      Text {
        id: postDropDetail
        x: Style.space(6); y: postDropTitle.y+postDropTitle.height+Style.space(4)
        width: Math.max(0, postDropPill.width-2*x)
        visible: !root.panelCollapsed
        text: root.dropPresentation ? root.dropPresentation.text || "" : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Color.muted
        font.family: Style.font.family; font.pixelSize: Style.font.caption
      }
    }
  }
  Component.onDestruction: {
    root.dropSurfaceReady = false
    root.controller.releaseDropSurface(root.dropSurfaceGeneration)
    root.clearDropPresentation()
    root.cancelInputs("viewport-destroyed")
    root.captureAnchor()
  }
}
