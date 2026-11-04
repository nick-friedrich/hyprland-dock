import QtQuick
import qs.Commons

Item {
  id: root

  required property string label
  property bool showFullLabel: false
  readonly property string displayLabel: root.showFullLabel || /^[0-9]+$/.test(root.label)
    ? root.label : "*"
  required property int count
  required property bool active
  required property int slotSize
  property bool switchable: true
  property bool urgent: false
  property bool dropHighlighted: false
  property bool monitorFocused: true
  property bool windowDragActive: false
  property var workspaceMonitorDrag: null
  property var workspaceMonitorDragDock: null
  property string workspaceIdentity: ""
  property string workspaceOwnerMonitor: ""
  property bool workspaceMonitorGestureOwned: false
  property bool workspaceMonitorGestureStarted: false
  readonly property bool workspaceMonitorDragActive:
    workspaceMonitorDrag && workspaceMonitorDrag.active
  readonly property bool workspaceMonitorDragSource: workspaceMonitorDrag
    && (workspaceMonitorDrag.active || workspaceMonitorDrag.awaitingConfirmation)
    && workspaceMonitorDrag.sourceDock === workspaceMonitorDragDock
    && workspaceMonitorDrag.sourceWorkspace === workspaceIdentity
  readonly property bool headerInputSuppressed: windowDragActive
    || workspaceMonitorDragActive || workspaceMonitorGestureOwned
  property string position: "bottom"
  property bool presentationVisible: true
  property bool animationsEnabled: true
  // External content-drag hover: the card header is a workspace-only target.
  // The owning card identity is authoritative; the icons inside keep their own
  // window/preview targets.
  property var navigation: null
  property QtObject navigationOwner: null
  readonly property bool externalEligible: !!root.navigation && root.switchable
    && root.presentationVisible && root.workspaceIdentity !== ""
    && !root.headerInputSuppressed
  readonly property var externalTarget: root.externalDragTarget()

  function externalDragTarget() {
    if (!root.externalEligible) return null
    return {key: "workspace:" + root.workspaceIdentity, kind: "workspace",
      workspaceIdentity: root.workspaceIdentity, anchor: root, priority: 0}
  }
  property var applicationModel: null
  property Component applicationDelegate: null
  property DockWorkspaceLayout viewport: null
  Connections {
    target: root.viewport
    function onViewportChanged() {
      if (root.viewport && root.viewport.viewportWidth <= 0) return
      root.presentationVisible = !root.viewport || root.viewport.containsItem(header)
      headerTooltip.scheduleReanchor()
    }
  }
  readonly property real headerWidth: header.width
  default property alias items: appRow.data
  signal activated(bool pullToMonitor)

  function cancelWorkspaceMonitorDrag(reason) {
    if (root.workspaceMonitorGestureStarted && root.workspaceMonitorDrag
        && root.workspaceMonitorDrag.sourceDock === root.workspaceMonitorDragDock) {
      root.workspaceMonitorGestureStarted = false
      root.workspaceMonitorDrag.cancel(reason)
    }
  }

  function workspaceMonitorGrabChanged(transition, point) {
    if (!root.workspaceMonitorGestureStarted || !root.workspaceMonitorDrag
        || root.workspaceMonitorDrag.sourceDock !== root.workspaceMonitorDragDock) return
    if (transition === PointerDevice.UngrabExclusive) {
      root.workspaceMonitorGestureStarted = false
      root.workspaceMonitorDrag.finish(point.scenePosition)
    } else if (transition === PointerDevice.CancelGrabExclusive
        || transition === PointerDevice.CancelGrabPassive) {
      cancelWorkspaceMonitorDrag("grab cancelled")
    }
  }

  function updateWorkspaceMonitorGesture(scenePoint, pressPoint) {
    if (!root.workspaceMonitorDrag || root.workspaceMonitorGestureOwned) {
      if (root.workspaceMonitorGestureStarted
          && root.workspaceMonitorDrag
          && root.workspaceMonitorDrag.sourceDock === root.workspaceMonitorDragDock)
        root.workspaceMonitorDrag.updatePointer(scenePoint)
      return
    }
    var dx = scenePoint.x - pressPoint.x
    var dy = scenePoint.y - pressPoint.y
    if (Math.sqrt(dx * dx + dy * dy) < Application.styleHints.startDragDistance)
      return
    root.workspaceMonitorGestureOwned = true
    root.workspaceMonitorGestureStarted = root.workspaceMonitorDrag.begin(
      root.workspaceMonitorDragDock, root.workspaceIdentity, root.label, root.count,
      root.workspaceOwnerMonitor, scenePoint)
    if (root.workspaceMonitorGestureStarted)
      header.forceActiveFocus(Qt.MouseFocusReason)
  }

  onWorkspaceMonitorDragDockChanged: cancelWorkspaceMonitorDrag("dock changed")
  onWindowDragActiveChanged: if (windowDragActive)
    cancelWorkspaceMonitorDrag("window drag started")
  onParentChanged: cancelWorkspaceMonitorDrag("source reparented")
  Component.onDestruction: cancelWorkspaceMonitorDrag("source destroyed")

  readonly property real appOccupancy: Math.min(1, appRow.width / Math.max(1, slotSize))
  width: header.width + appRow.width + Style.space(4) * appOccupancy
  height: slotSize + 10
  opacity: workspaceMonitorDragSource && workspaceMonitorDrag
    && workspaceMonitorDrag.captureReady ? 0.55 : 1
  HoverHandler { id: workspaceHover }

  Rectangle {
    id: surface
    y: 4
    width: parent.width
    height: parent.height - 8
    radius: Math.max(12, Style.cornerRadius - 4)
    color: root.dropHighlighted ? Util.alpha(Color.accent, 0.24)
      : root.active && root.monitorFocused ? Util.alpha(Color.accent, workspaceHover.hovered ? 0.13 : 0.10)
      : root.active ? Util.alpha(Color.foreground, workspaceHover.hovered ? 0.11 : 0.08)
      : Util.alpha(Color.foreground, workspaceHover.hovered ? 0.08 : 0.045)
    border.width: (root.dropHighlighted || root.urgent || (root.active && root.monitorFocused)) ? 1 : 0
    border.color: root.dropHighlighted ? Color.accent
      : root.urgent ? Color.urgent
      : (root.active && root.monitorFocused) ? Util.alpha(Color.accent, 0.50) : "transparent"
    Behavior on color {
      enabled: root.animationsEnabled
      ColorAnimation { duration: 160 }
    }
    Behavior on border.color {
      enabled: root.animationsEnabled
      ColorAnimation { duration: 160 }
    }
  }

  Rectangle {
    id: header
    color: "transparent"
    radius: Math.max(10, surface.radius - 2)
    x: 1
    y: 1
    // Label sits at the pill's leading inset; the trailing gap plus the
    // first icon's slot inset gives the same space before the icon.
    // Empty pills get equal padding; it narrows as the first icon arrives.
    readonly property real leadingPadding: Style.space(9)
    readonly property real trailingPadding: leadingPadding
      + (Style.space(2) - leadingPadding) * root.appOccupancy
    width: Math.min(80, Math.max(Math.round(root.slotSize * 0.6),
      title.implicitWidth + leadingPadding + trailingPadding))
    height: parent.height - 2
    Accessible.role: Accessible.Button
    Accessible.name: root.label + ", " + root.count + " windows" + (root.urgent ? ", urgent" : "")
    Accessible.onPressAction: if (root.switchable && !root.headerInputSuppressed) root.activated(false)

    DockExternalDragArea {
      id: headerDragArea

      anchors.fill: parent
      navigation: root.navigation
      owner: root.navigationOwner
      targetDescriptor: root.externalTarget
      navigationEnabled: root.externalEligible
    }
    activeFocusOnTab: root.switchable && !root.headerInputSuppressed
    Keys.onReturnPressed: if (root.switchable && !root.headerInputSuppressed) root.activated(false)
    Keys.onSpacePressed: if (root.switchable && !root.headerInputSuppressed) root.activated(false)
    Keys.onEscapePressed: event => {
      if (!root.workspaceMonitorDragActive) return
      root.cancelWorkspaceMonitorDrag("escape")
      event.accepted = true
    }
    Text {
      id: title
      x: header.leadingPadding
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width - header.leadingPadding - header.trailingPadding)
      elide: Text.ElideRight
      text: root.displayLabel
      horizontalAlignment: Text.AlignHCenter
      color: root.active && root.monitorFocused ? Color.accent
        : root.active ? Util.alpha(Color.accent, 0.6) : Color.foreground
      Behavior on color {
        enabled: root.animationsEnabled
        ColorAnimation { duration: 160 }
      }
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }
    TapHandler {
      enabled: root.switchable && !root.headerInputSuppressed
      acceptedModifiers: Qt.NoModifier
      onPressedChanged: if (pressed)
        header.forceActiveFocus(Qt.MouseFocusReason)
      onTapped: {
        if (!root.headerInputSuppressed) root.activated(false)
        header.focus = false
      }
    }
    TapHandler {
      enabled: root.switchable && !root.headerInputSuppressed
      acceptedModifiers: Qt.ControlModifier
      onPressedChanged: if (pressed)
        header.forceActiveFocus(Qt.MouseFocusReason)
      onTapped: {
        if (!root.headerInputSuppressed) root.activated(true)
        header.focus = false
      }
    }
    HoverHandler {
      id: headerHover
      cursorShape: root.workspaceMonitorDragSource ? Qt.ClosedHandCursor
        : root.switchable ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
    DockToolTip {
      id: headerTooltip
      anchorItem: header
      position: root.position
      requestedVisible: headerHover.hovered && root.presentationVisible
        && !root.headerInputSuppressed
      text: root.label + " — " + root.count + " windows" + (root.urgent ? " — urgent" : "")
      fontFamily: Style.font.family
      fontSize: Style.font.body
    }
    DragHandler {
      id: workspaceMonitorDragHandler
      enabled: root.workspaceMonitorDrag && root.workspaceMonitorDragDock
        && (active || root.workspaceMonitorGestureOwned
          || (root.switchable && root.workspaceIdentity !== ""
            && root.presentationVisible))
        && !root.windowDragActive
      target: null
      acceptedButtons: Qt.LeftButton
      dragThreshold: 0
      xAxis.enabled: true
      yAxis.enabled: true
      grabPermissions: PointerHandler.CanTakeOverFromItems
        | PointerHandler.CanTakeOverFromHandlersOfDifferentType
      cursorShape: Qt.ClosedHandCursor
      onActiveChanged: {
        if (active) {
          workspaceMonitorReleaseCleanup.stop()
          root.workspaceMonitorGestureStarted = false
          root.updateWorkspaceMonitorGesture(
            centroid.scenePosition, centroid.scenePressPosition)
        } else {
          workspaceMonitorReleaseCleanup.restart()
          header.focus = false
        }
      }
      onActiveTranslationChanged: if (active)
        root.updateWorkspaceMonitorGesture(
          centroid.scenePosition, centroid.scenePressPosition)
      onGrabChanged: (transition, point) => {
        if (transition === PointerDevice.GrabPassive
            || transition === PointerDevice.GrabExclusive)
          header.forceActiveFocus(Qt.MouseFocusReason)
        root.workspaceMonitorGrabChanged(transition, point)
      }
      onCanceled: root.cancelWorkspaceMonitorDrag("grab stolen")
      onEnabledChanged: if (!enabled)
        root.cancelWorkspaceMonitorDrag("handler disabled")
    }
    Timer {
      id: workspaceMonitorReleaseCleanup
      interval: 0
      repeat: false
      onTriggered: {
        if (root.workspaceMonitorGestureStarted && root.workspaceMonitorDrag
            && root.workspaceMonitorDrag.active)
          root.cancelWorkspaceMonitorDrag("grab ended without release")
        root.workspaceMonitorGestureStarted = false
        root.workspaceMonitorGestureOwned = false
      }
    }
  }

  Row {
    id: appRow
    x: header.width + Style.space(2)
    anchors.verticalCenter: parent.verticalCenter
    spacing: 0

    Repeater {
      model: root.applicationModel
      delegate: root.applicationDelegate
    }
  }
}
