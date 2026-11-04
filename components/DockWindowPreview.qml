pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockBrowserActivityModel.js" as ActivityModel
import "DockHerdrModel.js" as HerdrModel
import "DockWindowPreviewModel.js" as PreviewModel

PopupWindow {
  id: root

  required property var windowActions
  required property string position
  required property var visibleItems
  property var herdrAgentActions: null
  property var iconOverrides: ({})
  property int iconReloadRevision: 0
  property string activationMonitor: ""
  property bool previewCaptureEnabled: true
  property var previewArtwork: ({})
  property var mutedServices: []
  // External content-drag session: the host coordinator and the dock surface
  // that owns this popup's visibility hold. A drag-opened preview is not
  // dismissed by ordinary pointer-exit logic; its own membership and the
  // coordinator's handoff govern it.
  property var navigation: null
  property QtObject navigationOwner: null
  // True while any surface owned by the dock (dock body, reveal strip or this
  // popup) still holds the external drag. The dock uses the same owner hold for
  // auto-hide; the popup adds its own membership on top of it.
  readonly property bool externalDockHeld: root.navigation && root.navigationOwner
    ? root.navigation.heldFor(root.navigationOwner) : false

  property Item anchorItem: null
  property DockWorkspaceLayout clipItem: null
  property string presentationId: ""
  property var identityToplevel: null
  property bool originOnly: false
  property string desktopId: ""
  property string windowOverrideSource: ""
  property var applicationEntry: null
  property var members: []
  property bool anchorHovered: false
  property bool dragSession: false
  property bool externalDragActive: false
  property bool externalDragGrace: false
  property int openDelayMs: 220
  property int closeGraceMs: 180

  readonly property bool pending: openTimer.running
  readonly property bool popupHovered: popupHover.hovered
  readonly property bool interactionActive: root.pending || root.visible
    || root.anchorHovered || root.popupHovered
  readonly property bool orientationHorizontal:
    PreviewModel.orientationHorizontal(root.position)
  readonly property bool hasActivity: root.activityRows.length > 0
  readonly property bool hasAgents: root.agentRows.length > 0
  property bool herdrOnly: false
  readonly property bool hasSupplementaryContent:
    root.hasActivity || (root.hasAgents && !root.herdrOnly)
  readonly property int tileWidth: root.hasSupplementaryContent
    ? Style.space(180) : 232
  readonly property int tileHeight: root.hasSupplementaryContent
    ? Style.space(142) : 176
  readonly property int tilePreviewHeight: root.hasSupplementaryContent
    ? Style.space(102) : 122
  readonly property int tileSpacing: Style.space(8)
  readonly property int popupPadding: root.herdrOnly
    ? Style.space(14) : Style.space(root.hasSupplementaryContent ? 16 : 8)
  readonly property int popupGap: Style.space(8)
  readonly property int activityWidth: Style.space(368)
  readonly property int headerHeight: Math.max(
    Style.space(52), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int activityRowHeight: Math.max(
    Style.space(62), Style.font.subtitle + Style.font.bodySmall + Style.space(16))
  readonly property int maxVisibleActivityRows: 6
  readonly property int sectionSpacing:
    Style.space(root.herdrOnly ? 12 : 8)
  readonly property int separatorHeight: Style.spacing.hairline
  readonly property int windowLabelHeight: Style.space(18)
  readonly property int agentHeaderHeight: Style.space(24)
  readonly property int agentRowHeight: Style.space(56)
  readonly property int agentRowSpacing: Style.space(2)
  readonly property int agentFooterHeight: Style.space(16)
  readonly property var activityPresentation: ActivityModel.presentation(
    root.anchorItem && Array.isArray(root.anchorItem["previewActivities"])
      ? root.anchorItem["previewActivities"] : [], root.mutedServices)
  readonly property var activityRows: activityPresentation.rows
  readonly property int activityTotal: activityPresentation.total
  property var agentRows: []
  property string herdrLabel: ""
  property string herdrProduct: "Herdr"
  property string herdrFocusHint: "Click a row to focus its pane."
  property var herdrCounters: []
  readonly property bool showWindowPreviews:
    root.members.length >= 2 && (!root.herdrOnly || root.dragSession)
  readonly property int activityContentHeight: root.activityRows.length > 0
    ? root.activityRows.length * root.activityRowHeight
      + Math.max(0, root.activityRows.length - 1) * root.separatorHeight : 0
  readonly property int naturalActivityListHeight: PreviewModel.activityViewportHeight(
    root.activityRows.length, root.activityRowHeight,
    root.separatorHeight, root.maxVisibleActivityRows)
  readonly property int agentListHeight: root.agentRows.length > 0
    ? root.agentRows.length * root.agentRowHeight
      + Math.max(0, root.agentRows.length - 1) * root.agentRowSpacing : 0
  readonly property int previewContentWidth: !root.showWindowPreviews ? 0
    : root.orientationHorizontal
      ? root.members.length * root.tileWidth
        + Math.max(0, root.members.length - 1) * root.tileSpacing
      : root.tileWidth
  readonly property int previewContentHeight: !root.showWindowPreviews ? 0
    : root.orientationHorizontal ? root.tileHeight
    : root.members.length * root.tileHeight
      + Math.max(0, root.members.length - 1) * root.tileSpacing
  readonly property int maxVisiblePreviewTiles: 2
  readonly property int previewFlowWidth: !root.showWindowPreviews ? 0
    : root.hasSupplementaryContent && root.orientationHorizontal ? root.activityWidth
    : root.orientationHorizontal ? root.previewContentWidth
    : root.tileWidth
  readonly property int previewFlowHeight: !root.showWindowPreviews ? 0
    : root.orientationHorizontal ? root.tileHeight
    : root.hasSupplementaryContent
      ? Math.min(root.members.length, root.maxVisiblePreviewTiles)
        * root.tileHeight
        + Math.max(0, Math.min(root.members.length, root.maxVisiblePreviewTiles) - 1)
          * root.tileSpacing
    : root.previewContentHeight
  readonly property int contentWidth: root.herdrOnly
    ? (root.showWindowPreviews
      ? Math.max(Style.space(432), root.previewFlowWidth) : Style.space(432))
    : root.hasSupplementaryContent
      ? Math.max(root.activityWidth, root.previewFlowWidth)
      : root.previewFlowWidth
  readonly property int previewSectionHeight: root.showWindowPreviews
    ? root.sectionSpacing + root.separatorHeight
      + root.sectionSpacing + root.windowLabelHeight
      + root.sectionSpacing + root.previewFlowHeight : 0
  // The window section is ordinary supplementary chrome for content previews,
  // and is added around the agent list when a drag session must expose exact
  // tiles that agent-only presentation would otherwise suppress.
  readonly property bool previewSectionChrome: root.showWindowPreviews
    && (root.hasSupplementaryContent || root.herdrOnly)
  readonly property int supplementaryContentHeight:
    (root.hasSupplementaryContent ? root.headerHeight : 0)
    + (root.hasActivity ? root.sectionSpacing + root.naturalActivityListHeight : 0)
    + (root.hasAgents ? root.sectionSpacing + root.agentHeaderHeight
      + root.sectionSpacing + root.agentListHeight : 0)
    + (root.herdrOnly ? root.sectionSpacing + root.agentFooterHeight : 0)
  readonly property int naturalContentHeight: root.herdrOnly && !root.showWindowPreviews
    ? root.agentHeaderHeight + root.sectionSpacing + root.agentListHeight
      + root.sectionSpacing + root.agentFooterHeight
    : root.hasSupplementaryContent || (root.herdrOnly && root.showWindowPreviews)
      ? root.supplementaryContentHeight + root.previewSectionHeight
      : root.previewFlowHeight
  readonly property int desiredWidth: root.popupPadding * 2 + root.contentWidth
  readonly property int desiredHeight: root.popupPadding * 2
    + root.naturalContentHeight
  readonly property var anchorWindow: root.anchorItem
    ? root.anchorItem.QsWindow.window : null
  readonly property var anchorScreen: root.anchorWindow
    ? root.anchorWindow.screen : null
  readonly property var previewViewport: PreviewModel.previewViewport(
    root.anchorScreen ? root.anchorScreen.width : root.desiredWidth,
    root.anchorScreen ? root.anchorScreen.height : root.desiredHeight,
    root.desiredWidth, root.desiredHeight, root.popupPadding)
  // Prefer the natural activity list; let the outer Flickable own short-screen
  // overflow instead of starving rows to fit unbounded preview tiles.
  readonly property int activityListHeight: root.hasActivity
    ? root.naturalActivityListHeight : 0
  readonly property int contentHeight: root.naturalContentHeight

  signal activityRequested(var activity)
  signal activityMuteToggled(string serviceId)

  DockHerdrStatusColors { id: statusColors }

  function captureAgentTarget(agent) {
    return root.herdrAgentActions && agent && agent.toplevel
      ? root.herdrAgentActions.captureAgentTarget(agent.toplevel, agent) : null
  }

  function activateAgentTarget(target) {
    if (!target || !root.herdrAgentActions) return false
    var activated = root.herdrAgentActions.activateHerdrTarget(target)
    if (activated) root.dismissImmediately()
    return activated
  }

  function serviceArtwork(serviceId) {
    if (serviceId === "gmail")
      return Qt.resolvedUrl("../assets/services/gmail.svg")
    if (serviceId === "whatsapp")
      return Qt.resolvedUrl("../assets/services/whatsapp.svg")
    return ""
  }

  function liveMembers(values) {
    var live = ToplevelManager.toplevels
      ? ToplevelManager.toplevels.values || [] : []
    return PreviewModel.livePreviewMembers(values, live)
  }

  function visibleTarget() {
    return PreviewModel.visiblePreviewTarget(
      root.visibleItems, root.presentationId, root.identityToplevel)
  }

  function clearSession() {
    root.presentationId = ""
    root.identityToplevel = null
    root.originOnly = false
    root.desktopId = ""
    root.windowOverrideSource = ""
    root.applicationEntry = null
    root.members = []
    root.agentRows = []
    root.herdrOnly = false
    root.herdrLabel = ""
    root.herdrProduct = "Herdr"
    root.herdrFocusHint = "Click a row to focus its pane."
    root.herdrCounters = []
    root.anchorHovered = false
    root.dragSession = false
    root.externalDragActive = false
    root.externalDragGrace = false
    root.anchorItem = null
  }

  function dismissImmediately() {
    openTimer.stop()
    closeTimer.stop()
    root.visible = false
    root.clearSession()
  }

  function refreshAnchorGeometry() {
    if (!root.anchorItem) return
    if (!root.anchorItem.visible || (root.clipItem && !root.clipItem.containsItem(root.anchorItem))) {
      root.dismissImmediately()
      return
    }
    if (root.visible) Qt.callLater(root.reanchor)
  }

  function reanchor() {
    if (!root.anchorItem || !root.anchor.window) return
    if (root.clipItem && !root.clipItem.containsItem(root.anchorItem)) {
      root.dismissImmediately()
      return
    }

    var offset = PreviewModel.previewAnchorOffset(
      root.position, root.anchorItem.width, root.anchorItem.height,
      root.implicitWidth, root.implicitHeight, root.popupGap)
    var point = root.anchor.window.contentItem.mapFromItem(
      root.anchorItem, offset.x, offset.y)
    root.anchor.rect.x = Math.round(point.x)
    root.anchor.rect.y = Math.round(point.y)
  }

  function requestPreview(anchorItem, desktopId, toplevels, applicationEntry,
                          openImmediately) {
    var requested = root.liveMembers(toplevels)
    var requestedActivities = ActivityModel.presentation(
      anchorItem && Array.isArray(anchorItem["previewActivities"])
        ? anchorItem["previewActivities"] : [], root.mutedServices).rows
    var requestedAgents = anchorItem && Array.isArray(anchorItem["previewAgents"])
      ? anchorItem["previewAgents"] : []
    if (!anchorItem
        || !PreviewModel.hasPreviewContent(
          requested.length, requestedActivities.length, requestedAgents.length)
        || (root.clipItem && !root.clipItem.containsItem(anchorItem))) {
      if (root.anchorItem === anchorItem) root.dismissImmediately()
      return false
    }

    var switching = root.visible && root.anchorItem
      && root.anchorItem !== anchorItem
    closeTimer.stop()
    root.anchorItem = anchorItem
    root.desktopId = String(desktopId || "")
    root.windowOverrideSource = String(anchorItem.windowOverrideSource || "")
    root.presentationId = String(anchorItem.presentationId || root.desktopId)
    root.identityToplevel = anchorItem.identityToplevel || null
    root.originOnly = anchorItem.originOnly === true
    root.applicationEntry = applicationEntry || null
    root.members = requested
    root.agentRows = requestedAgents
    root.herdrOnly = requestedAgents.length > 0
      && anchorItem["previewHerdrOnly"] === true
    root.herdrLabel = String(anchorItem["previewHerdrLabel"] || "")
    root.herdrProduct = String(anchorItem["previewHerdrProduct"] || "Herdr")
    root.herdrFocusHint = String(anchorItem["previewHerdrFocusHint"] || "Click a row to focus its pane.")
    root.herdrCounters = Array.isArray(anchorItem["previewHerdrCounters"])
      ? anchorItem["previewHerdrCounters"] : []
    root.anchorHovered = true

    if (root.visible || switching || openImmediately === true) {
      openTimer.stop()
      root.visible = true
      Qt.callLater(root.reanchor)
    } else {
      openTimer.restart()
    }
    return true
  }

  // Opened by the shared coordinator after its dwell already elapsed: no second
  // hover delay. Tiles stay exposed for this session even when agent-only
  // presentation would otherwise suppress them, and dismissal follows drag
  // membership plus the coordinator handoff instead of pointer-exit heuristics.
  function requestDragPreview(anchorItem, desktopId, toplevels, applicationEntry) {
    root.dragSession = true
    var opened = root.requestPreview(anchorItem, desktopId, toplevels,
      applicationEntry, true)
    if (!opened) {
      root.dragSession = false
      return false
    }
    root.externalDragGrace = false
    handoffTimer.stop()
    return true
  }

  // The popup keeps its own membership state (content drag or handoff grace).
  // It never treats a content drag as an ordinary pointer exit.
  function noteExternalDragMembership(active) {
    if (active) {
      root.externalDragActive = true
      root.externalDragGrace = false
      handoffTimer.stop()
      closeTimer.stop()
      return
    }
    if (!root.externalDragActive || root.externalDragGrace) return
    root.externalDragGrace = true
    handoffTimer.restart()
  }

  function scheduleExternalDismissal() {
    if (!root.visible || !root.anchorItem) return
    if (root.externalDragActive || root.popupHovered || root.anchorHovered) return
    if (root.externalDockHeld) return
    closeTimer.restart()
  }

  function releasePreview(anchorItem) {
    if (anchorItem && root.anchorItem !== anchorItem) return
    root.anchorHovered = false
    if (root.dragSession || root.externalDragActive) return
    if (!root.visible) {
      root.dismissImmediately()
      return
    }
    if (!root.popupHovered) closeTimer.restart()
  }

  function refreshFromVisibleItems() {
    if (!root.anchorItem || !root.desktopId) return
    if (!root.anchorItem.visible || (root.clipItem && !root.clipItem.containsItem(root.anchorItem))) {
      root.dismissImmediately(); return
    }
    var target = root.visibleTarget()
    if (!target) {
      root.dismissImmediately()
      return
    }
    var refreshed = root.liveMembers(target.toplevels)
    if (!PreviewModel.hasPreviewContent(
        refreshed.length, root.activityRows.length, root.agentRows.length)) {
      root.dismissImmediately()
      return
    }
    root.members = refreshed
    root.windowOverrideSource = String(target.windowOverrideSource || "")
    if (root.visible) Qt.callLater(root.reanchor)
  }

  function activateToplevel(toplevel, pullToMonitorWorkspace) {
    if (!root.windowActions) return false
    var focused = pullToMonitorWorkspace === true
      ? root.windowActions.pullToplevelToMonitorWorkspace(
        toplevel, root.originOnly, root.activationMonitor)
      : root.windowActions.activateToplevel(toplevel, root.originOnly, "")
    if (!focused) return false
    root.dismissImmediately()
    return true
  }

  function closeToplevel(toplevel) {
    return root.windowActions
      ? root.windowActions.closeToplevel(toplevel) : false
  }

  function refreshSupplementaryContent() {
    // Called after bindings and requestPreview's session assignments settle.
    // Never dismiss from inside the activity binding that clearing the anchor
    // would invalidate, and always validate the current (not queued) session.
    if (!root.anchorItem || (!root.visible && !root.pending)) return
    if (!PreviewModel.hasPreviewContent(
        root.members.length, root.activityRows.length, root.agentRows.length)) {
      root.dismissImmediately()
    } else if (root.visible) {
      root.reanchor()
    }
  }

  function refreshAgentContent() {
    if (!root.anchorItem) return
    root.agentRows = Array.isArray(root.anchorItem["previewAgents"])
      ? root.anchorItem["previewAgents"] : []
    root.herdrOnly = root.agentRows.length > 0
      && root.anchorItem["previewHerdrOnly"] === true
    root.herdrLabel = String(root.anchorItem["previewHerdrLabel"] || "")
    root.herdrProduct = String(root.anchorItem["previewHerdrProduct"] || "Herdr")
    root.herdrFocusHint = String(root.anchorItem["previewHerdrFocusHint"] || "Click a row to focus its pane.")
    root.herdrCounters = Array.isArray(root.anchorItem["previewHerdrCounters"])
      ? root.anchorItem["previewHerdrCounters"] : []
    Qt.callLater(root.refreshSupplementaryContent)
  }

  implicitWidth: root.previewViewport.width
  implicitHeight: root.previewViewport.height
  color: "transparent"
  grabFocus: false

  anchor {
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1
    onAnchoring: root.reanchor()
  }

  Timer {
    id: openTimer
    interval: root.openDelayMs
    repeat: false
    onTriggered: {
      root.refreshFromVisibleItems()
      if (!root.anchorHovered || !root.anchorItem
          || !PreviewModel.hasPreviewContent(
            root.members.length, root.activityRows.length, root.agentRows.length))
        return
      root.visible = true
      Qt.callLater(root.reanchor)
    }
  }

  Timer {
    id: closeTimer
    interval: root.closeGraceMs
    repeat: false
    onTriggered: {
      if (!root.anchorHovered && !root.popupHovered
          && !root.externalDragActive && !root.externalDockHeld)
        root.dismissImmediately()
    }
  }

  // Coordinator-class handoff grace: a content drag that leaves this popup for
  // the dock (or the reverse) keeps the popup reachable, and a drag that leaves
  // both surfaces lets the ordinary close grace run once the handoff expires.
  Timer {
    id: handoffTimer
    interval: root.navigation && Number(root.navigation.handoffMs) > 0
      ? Number(root.navigation.handoffMs) : 200
    repeat: false
    onTriggered: {
      root.externalDragGrace = false
      root.externalDragActive = false
      root.scheduleExternalDismissal()
    }
  }

  BorderSurface {
    anchors.fill: parent
    radius: root.hasSupplementaryContent || root.herdrOnly
      ? Math.max(Style.cornerRadius, Style.space(10)) : Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec(
      "menu", "border",
      root.hasSupplementaryContent || root.herdrOnly
        ? Util.alpha(Color.menu.border, 0.38) : Color.menu.border,
      root.hasSupplementaryContent || root.herdrOnly
        ? Style.spacing.hairline : Math.max(1, Style.space(2)))

    HoverHandler {
      id: popupHover
      onHoveredChanged: {
        if (hovered) closeTimer.stop()
        else if (!root.anchorHovered && !root.dragSession && root.visible)
          closeTimer.restart()
      }
    }

    // Whole-popup membership: a content drag on any part of the preview keeps
    // the dock (same owner) reachable and never reads the payload.
    DockExternalDragArea {
      id: previewSurfaceDrag

      anchors.fill: parent
      navigation: root.navigation
      owner: root.navigationOwner
      navigationEnabled: !!root.navigation
      targetDescriptor: ({key: "reveal:preview", kind: "reveal", passive: true})
    }

    Flickable {
      id: viewport
      x: root.popupPadding
      y: root.popupPadding
      width: parent.width - root.popupPadding * 2
      height: parent.height - root.popupPadding * 2
      clip: true
      contentWidth: contentFlow.width
      contentHeight: contentFlow.height
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentWidth > width || contentHeight > height

      WheelHandler {
        target: null
        onWheel: event => {
          event.accepted = false
          var delta = Math.abs(event.angleDelta.y) >= Math.abs(event.angleDelta.x)
            ? event.angleDelta.y : event.angleDelta.x
          if (delta === 0) return
          if (viewport.contentHeight > viewport.height) {
            var maxY = viewport.contentHeight - viewport.height
            viewport.contentY = Math.max(
              0, Math.min(maxY, viewport.contentY - delta))
            event.accepted = true
          } else if (viewport.contentWidth > viewport.width) {
            var maxX = viewport.contentWidth - viewport.width
            viewport.contentX = Math.max(
              0, Math.min(maxX, viewport.contentX - delta))
            event.accepted = true
          }
        }
      }

      Column {
        id: contentFlow
        width: root.hasSupplementaryContent || root.herdrOnly
          ? viewport.width : root.contentWidth
        height: root.contentHeight
        spacing: root.sectionSpacing

        Item {
          visible: root.hasSupplementaryContent
          width: contentFlow.width
          height: root.headerHeight

          DockAppIcon {
            id: headerIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            height: width
            desktopId: root.desktopId
            desktopIcon: root.applicationEntry && root.applicationEntry.icon
              ? root.applicationEntry.icon : ""
            iconOverrides: root.iconOverrides
            windowOverrideSource: root.windowOverrideSource
            reloadRevision: root.iconReloadRevision
          }

          Text {
            anchors.left: headerIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: totalSummary.left
            anchors.rightMargin: Style.space(8)
            anchors.baseline: totalCount.baseline
            text: root.activityRows.length > 0 ? "Chrome"
              : root.applicationEntry && root.applicationEntry.name
              ? String(root.applicationEntry.name) : "Chrome"
            textFormat: Text.PlainText
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title + 1
            font.weight: Font.Bold
            elide: Text.ElideRight
          }

          Text {
            id: totalCount
            anchors.right: parent.right
            anchors.rightMargin: Style.space(58)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.activityRows.length > 0
            text: String(root.activityTotal)
            textFormat: Text.PlainText
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold
          }

          Text {
            id: totalSummary
            anchors.left: totalCount.right
            anchors.leftMargin: Style.space(6)
            anchors.baseline: totalCount.baseline
            visible: root.activityRows.length > 0
            text: "unread"
            textFormat: Text.PlainText
            color: Util.alpha(Color.menu.text, 0.62)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: root.separatorHeight
            color: Util.alpha(Color.menu.text, 0.12)
          }
        }

        Flickable {
          id: activityList
          visible: root.activityRows.length > 0
          width: contentFlow.width
          height: root.activityListHeight
          contentWidth: width
          contentHeight: root.activityContentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          WheelHandler {
            target: null
            onWheel: event => {
              event.accepted = false
              if (activityList.contentHeight <= activityList.height)
                return
              var delta = event.angleDelta.y
              if (delta === 0) return
              var maxY = activityList.contentHeight - activityList.height
              activityList.contentY = Math.max(
                0, Math.min(maxY, activityList.contentY - delta))
              event.accepted = true
            }
          }

          Repeater {
            model: root.activityRows

            BorderSurface {
              id: activityRow
              required property var modelData
              required property int index
              readonly property bool muted: modelData.muted === true
              readonly property real contentOpacity: muted ? 0.45 : 1

              width: activityList.width
              height: root.activityRowHeight
              y: index * (root.activityRowHeight + root.separatorHeight)
              radius: Style.space(6)
              color: activityHover.hovered
                ? Style.hoverFill : "transparent"
              borderSpec: activityHover.hovered
                ? Border.surfaceSpec(
                  "menu", "selected-border", Color.menu.selectedBorder, 0)
                : Border.none()

              Accessible.role: Accessible.Button
              Accessible.name: ActivityModel.accessibleName(modelData)
                + (muted ? ", muted" : "")
              Accessible.onPressAction: root.activityRequested(modelData)

              HoverHandler {
                id: activityHover
                cursorShape: Qt.PointingHandCursor
              }

              TapHandler {
                id: activityRowTap
                acceptedButtons: Qt.LeftButton
                enabled: !muteTap.pressed
                onTapped: root.activityRequested(activityRow.modelData)
              }

              Item {
                id: serviceIcon
                anchors.left: parent.left
                anchors.leftMargin: activityRow.borderLeft + Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(38)
                height: width
                opacity: activityRow.contentOpacity

                Image {
                  id: serviceArtwork
                  anchors.fill: parent
                  source: root.serviceArtwork(
                    String(activityRow.modelData.serviceId || ""))
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                }

                Text {
                  anchors.centerIn: parent
                  visible: serviceArtwork.status !== Image.Ready
                  text: String(activityRow.modelData.label || "?")
                    .trim().charAt(0).toUpperCase()
                  textFormat: Text.PlainText
                  color: activityHover.hovered
                    ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.title
                  font.weight: Font.DemiBold
                }
              }

              Column {
                anchors.left: serviceIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: countPill.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                opacity: activityRow.contentOpacity

                Text {
                  width: parent.width
                  text: String(activityRow.modelData.label || "")
                  textFormat: Text.PlainText
                  color: activityHover.hovered
                    ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.subtitle + 1
                  font.weight: Font.DemiBold
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: String(activityRow.modelData.profileKey || "")
                    || String(activityRow.modelData.domain || "")
                  textFormat: Text.PlainText
                  color: Util.alpha(Color.menu.text, 0.62)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Rectangle {
                id: countPill
                anchors.right: muteControl.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Style.space(32),
                  countLabel.implicitWidth + Style.space(12))
                height: Style.space(26)
                radius: Style.space(7)
                opacity: activityRow.contentOpacity
                color: Util.alpha(Color.accent, 0.12)
                border.width: Style.spacing.hairline
                border.color: Util.alpha(Color.accent, 0.28)

                Text {
                  id: countLabel
                  anchors.centerIn: parent
                  text: String(activityRow.modelData.count)
                  textFormat: Text.PlainText
                  color: Color.accent
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.DemiBold
                }
              }

              Item {
                id: muteControl
                anchors.right: activityChevron.left
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                height: width
                z: 2
                opacity: activityRow.muted || activityHover.hovered
                  || muteHover.hovered ? 1 : 0

                Accessible.role: Accessible.Button
                Accessible.name: activityRow.muted
                  ? "Show " + String(activityRow.modelData.label || "service")
                    + " in totals"
                  : "Hide " + String(activityRow.modelData.label || "service")
                    + " from totals"
                Accessible.onPressAction: root.activityMuteToggled(
                  String(activityRow.modelData.serviceId || ""))

                HoverHandler {
                  id: muteHover
                  enabled: muteControl.opacity > 0
                  cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                  id: muteTap
                  enabled: muteControl.opacity > 0
                  acceptedButtons: Qt.LeftButton
                  gesturePolicy: TapHandler.WithinBounds
                  onTapped: root.activityMuteToggled(
                    String(activityRow.modelData.serviceId || ""))
                }

                DockLucideIcon {
                  anchors.centerIn: parent
                  width: Style.space(16)
                  height: width
                  iconName: activityRow.muted ? "eye-off" : "eye"
                  tint: muteHover.hovered || activityHover.hovered
                    ? Color.menu.selectedText
                    : Util.alpha(Color.menu.text, 0.7)
                }
              }

              DockLucideIcon {
                id: activityChevron
                anchors.right: parent.right
                anchors.rightMargin: activityRow.borderRight + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                height: width
                opacity: activityRow.contentOpacity
                iconName: "chevron-right"
                tint: activityHover.hovered
                  ? Color.menu.selectedText : Util.alpha(Color.menu.text, 0.55)
              }

              Rectangle {
                anchors.top: parent.bottom
                width: parent.width
                height: root.separatorHeight
                visible: activityRow.index < root.activityRows.length - 1
                color: Util.alpha(Color.menu.text, 0.12)
              }
            }
          }
        }

        Item {
          id: herdrHeader
          objectName: "preview-herdr-header"
          visible: root.hasAgents
          width: contentFlow.width
          height: root.agentHeaderHeight

          DockLucideIcon {
            id: herdrHeaderGlyph
            anchors.left: parent.left
            anchors.leftMargin: root.herdrOnly ? Style.space(4) : Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(18)
            height: width
            iconName: "terminal"
            tint: Color.accent
          }

          Text {
            anchors.left: herdrHeaderGlyph.right
            anchors.leftMargin: Style.space(10)
            anchors.right: herdrCountersRow.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.herdrLabel ? root.herdrProduct + " · " + root.herdrLabel : root.herdrProduct
            textFormat: Text.PlainText
            color: Color.menu.text
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            font.weight: Font.Bold
            elide: Text.ElideRight
          }

          Row {
            id: herdrCountersRow
            objectName: "preview-herdr-counters"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Repeater {
              model: root.herdrCounters

              Row {
                required property var modelData
                spacing: Style.space(4)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: statusColors.color(parent.modelData.status)
                  border.width: statusColors.hollow(parent.modelData.status)
                    ? Style.spacing.hairline : 0
                  border.color: Color.menu.text
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(parent.modelData.count || 0)
                  textFormat: Text.PlainText
                  color: Util.alpha(Color.menu.text, 0.72)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }

        Item {
          id: agentList
          objectName: "preview-herdr-agent-list"
          visible: root.hasAgents
          width: contentFlow.width
          height: root.agentListHeight

          Repeater {
            model: root.agentRows

            BorderSurface {
              id: agentRow
              objectName: "preview-herdr-agent-row"
              required property var modelData
              required property int index
              readonly property bool actionable:
                modelData.focusAgentSupported === true
                  && root.herdrAgentActions !== null
              readonly property bool raised: actionable
                && (agentHover.hovered || agentRow.activeFocus)
              property var capturedTarget: null

              width: agentList.width
              height: root.agentRowHeight
              y: index * (root.agentRowHeight + root.agentRowSpacing)
              radius: Style.space(10)
              color: agentRow.activeFocus
                ? Style.focusFillFor(Color.menu.text, Color.accent)
                : agentHover.hovered && actionable
                  ? Style.hoverFillFor(Color.menu.text, Color.accent)
                  : "transparent"
              borderSpec: agentRow.activeFocus
                ? Border.controlSpec("focus", Color.menu.text, Color.accent)
                : agentHover.hovered && actionable
                  ? Border.controlSpec("hover-cursor", Color.menu.text, Color.accent)
                  : Border.none()
              activeFocusOnTab: actionable
              opacity: actionable ? 1 : 0.68

              Accessible.role: actionable
                ? Accessible.Button : Accessible.StaticText
              Accessible.name: HerdrModel.displayAgentTitle(modelData)
                + ", " + HerdrModel.displayAgentTabSecondary(modelData)
                + ", " + HerdrModel.statusLabel(modelData.status)
              Accessible.description: actionable
                ? (String(modelData.serverId || "").indexOf("claude:") === 0
                  ? "Open this Claude session"
                  : (root.herdrProduct === "T3 Code" ? "Open this T3 thread" : "Focus this Herdr agent pane"))
                : (String(modelData.serverId || "").indexOf("claude:") === 0
                  ? "Claude session" : "Remote Herdr agent")
              Accessible.onPressAction: if (actionable)
                root.activateAgentTarget(capturedTarget)

              Keys.onReturnPressed: if (actionable)
                root.activateAgentTarget(capturedTarget)
              Keys.onEnterPressed: if (actionable)
                root.activateAgentTarget(capturedTarget)

              DockHerdrStatusColors { id: rowStatusColors }

              Item {
                id: rowStatus
                anchors.left: parent.left
                anchors.leftMargin: agentRow.contentLeftInset + Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: width

                DockHerdrStatusMark {
                  anchors.fill: parent
                  status: agentRow.modelData.status
                  size: parent.width
                  ringColor: Color.menu.background
                }

                Rectangle {
                  anchors.centerIn: parent
                  visible: {
                    var status = HerdrModel.normalizeStatus(agentRow.modelData.status)
                    return status === "idle" || status === "unknown"
                  }
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: rowStatusColors.hollow(agentRow.modelData.status)
                    ? "transparent" : rowStatusColors.color(agentRow.modelData.status)
                  border.width: Style.spacing.hairline
                  border.color: rowStatusColors.color(agentRow.modelData.status)
                }
              }

              Column {
                anchors.left: rowStatus.right
                anchors.leftMargin: Style.space(12)
                anchors.right: rowTrailing.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: HerdrModel.displayAgentTitle(agentRow.modelData)
                  textFormat: Text.PlainText
                  color: Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: HerdrModel.displayAgentTabSecondary(agentRow.modelData)
                  textFormat: Text.PlainText
                  color: Util.alpha(Color.menu.text, 0.58)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Rectangle {
                id: rowTrailing
                anchors.right: parent.right
                anchors.rightMargin: agentRow.contentRightInset + Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: agentRow.raised
                  ? focusChipText.implicitWidth + Style.space(16)
                  : statusText.implicitWidth
                height: agentRow.raised ? Style.space(24) : statusText.implicitHeight
                radius: Style.space(6)
                color: agentRow.raised
                  ? Style.normalFillFor(Color.menu.text, Color.accent)
                  : "transparent"

                Text {
                  id: focusChipText
                  anchors.centerIn: parent
                  visible: agentRow.raised
                  text: "↵ Focus"
                  textFormat: Text.PlainText
                  color: Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: statusText
                  anchors.centerIn: parent
                  visible: !agentRow.raised
                  text: HerdrModel.statusLabel(agentRow.modelData.status)
                  textFormat: Text.PlainText
                  color: rowStatusColors.color(agentRow.modelData.status)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              HoverHandler {
                id: agentHover
                cursorShape: agentRow.actionable
                  ? Qt.PointingHandCursor : Qt.ArrowCursor
              }

              TapHandler {
                enabled: agentRow.actionable
                acceptedButtons: Qt.LeftButton
                onPressedChanged: if (pressed)
                  agentRow.capturedTarget = root.captureAgentTarget(
                    agentRow.modelData)
                onTapped: root.activateAgentTarget(agentRow.capturedTarget)
              }

              Component.onCompleted: capturedTarget = root.captureAgentTarget(modelData)
              onModelDataChanged: capturedTarget = root.captureAgentTarget(modelData)
            }
          }
        }

        Text {
          objectName: "preview-herdr-footer"
          visible: root.herdrOnly
          width: contentFlow.width
          height: root.agentFooterHeight
          leftPadding: Style.space(4)
          text: root.herdrFocusHint
          textFormat: Text.PlainText
          color: Util.alpha(Color.menu.text, 0.58)
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          verticalAlignment: Text.AlignVCenter
        }

        Item {
          visible: root.previewSectionChrome
          width: contentFlow.width
          height: root.separatorHeight

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(Color.menu.text, 0.18)
          }
        }

        Item {
          visible: root.previewSectionChrome
          width: contentFlow.width
          height: root.windowLabelHeight

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: PreviewModel.windowSectionLabel(root.members.length)
            textFormat: Text.PlainText
            color: Util.alpha(Color.menu.text, 0.58)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
            font.letterSpacing: Style.space(1)
          }
        }

        Item {
          id: tileFlow
          visible: root.showWindowPreviews
          width: root.hasSupplementaryContent || root.herdrOnly
            ? contentFlow.width : root.previewFlowWidth
          height: root.previewFlowHeight
          clip: root.hasSupplementaryContent || root.herdrOnly

          Flickable {
            id: previewList
            anchors.fill: parent
            contentWidth: root.orientationHorizontal
              ? root.previewContentWidth : root.tileWidth
            contentHeight: root.previewContentHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: root.orientationHorizontal
              ? Flickable.HorizontalFlick : Flickable.VerticalFlick
            interactive: contentWidth > width || contentHeight > height

            WheelHandler {
              enabled: previewList.contentWidth > previewList.width
                || previewList.contentHeight > previewList.height
              target: null
              onWheel: event => {
                var delta = Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y)
                  ? event.angleDelta.x : event.angleDelta.y
                if (root.orientationHorizontal
                    && previewList.contentWidth > previewList.width) {
                  var maxX = previewList.contentWidth - previewList.width
                  previewList.contentX = Math.max(
                    0, Math.min(maxX, previewList.contentX - delta))
                  event.accepted = true
                } else if (!root.orientationHorizontal
                           && previewList.contentHeight > previewList.height) {
                  var maxY = previewList.contentHeight - previewList.height
                  previewList.contentY = Math.max(
                    0, Math.min(maxY, previewList.contentY - delta))
                  event.accepted = true
                }
              }
            }

            Repeater {
              model: root.showWindowPreviews ? root.members : []

              DockWindowPreviewTile {
                required property var modelData
                required property int index
                toplevel: modelData
                windowActions: root.windowActions
                applicationEntry: root.applicationEntry
                desktopId: root.desktopId
                iconOverrides: root.iconOverrides
                windowOverrideSource: root.windowOverrideSource
                iconReloadRevision: root.iconReloadRevision
                captureEnabled: root.visible && root.previewCaptureEnabled
                compactActivityLayout: root.hasSupplementaryContent
                fallbackArtwork: root.previewArtwork[modelData.title] || ""
                previewWidth: root.tileWidth
                previewHeight: root.tilePreviewHeight
                navigation: root.navigation
                navigationOwner: root.navigationOwner
                width: root.tileWidth
                height: root.tileHeight
                x: root.orientationHorizontal
                  ? index * (root.tileWidth + root.tileSpacing) : 0
                y: root.orientationHorizontal
                  ? 0 : index * (root.tileHeight + root.tileSpacing)
                onActivateRequested: (toplevel, pullToMonitorWorkspace) =>
                  root.activateToplevel(toplevel, pullToMonitorWorkspace)
                onCloseRequested: toplevel => root.closeToplevel(toplevel)
              }
            }
          }
        }
      }
    }
  }

  onVisibleItemsChanged: root.refreshFromVisibleItems()
  onClipItemChanged: root.refreshAnchorGeometry()
  onPositionChanged: if (root.visible) Qt.callLater(root.reanchor)
  onMembersChanged: if (root.visible
      && PreviewModel.hasPreviewContent(
        root.members.length, root.activityRows.length, root.agentRows.length))
    Qt.callLater(root.reanchor)
  onActivityRowsChanged: {
    Qt.callLater(root.refreshSupplementaryContent)
  }
  onAnchorItemChanged: {
    if (!root.anchorItem && root.desktopId !== "")
      root.dismissImmediately()
  }

  Connections {
    target: previewSurfaceDrag
    function onContainsDragChanged() {
      root.noteExternalDragMembership(previewSurfaceDrag.containsDrag)
    }
  }

  Connections {
    target: root.navigation
    ignoreUnknownSignals: true
    function onHoldRevisionChanged() { root.scheduleExternalDismissal() }
    function onSessionActiveChanged() {
      if (root.navigation && root.navigation.sessionActive) return
      root.externalDragActive = false
      root.externalDragGrace = false
      handoffTimer.stop()
      root.scheduleExternalDismissal()
    }
  }

  Connections {
    id: anchorConnections
    target: root.anchorItem
    ignoreUnknownSignals: true
    function onDestroyed(object) {
      if (!root.anchorItem || root.anchorItem === object)
        root.dismissImmediately()
    }
    function onXChanged() { root.refreshAnchorGeometry() }
    function onYChanged() { root.refreshAnchorGeometry() }
    function onWidthChanged() { root.refreshAnchorGeometry() }
    function onHeightChanged() { root.refreshAnchorGeometry() }
    function onVisibleChanged() { if (root.anchorItem && !root.anchorItem.visible) root.dismissImmediately() }
    function onPreviewActivitiesChanged() {
      Qt.callLater(root.refreshSupplementaryContent)
    }
    function onPreviewAgentsChanged() {
      root.refreshAgentContent()
    }
    function onPreviewHerdrOnlyChanged() {
      root.refreshAgentContent()
    }
    function onPreviewHerdrLabelChanged() { root.refreshAgentContent() }
    function onPreviewHerdrProductChanged() { root.refreshAgentContent() }
    function onPreviewHerdrFocusHintChanged() { root.refreshAgentContent() }
    function onPreviewHerdrCountersChanged() { root.refreshAgentContent() }
  }

  Connections {
    target: root.anchorScreen
    function onDestroyed() { root.dismissImmediately() }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.refreshFromVisibleItems() }
  }

  Component.onDestruction: root.dismissImmediately()
}
