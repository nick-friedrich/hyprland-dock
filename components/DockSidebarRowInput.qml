import QtQuick

// Native Qt pointer handlers shared by wide/rail rows. Capture identities and
// the clicked connector before requesting focus. Unknown modifiers fail closed.
// The external content-drag adapter is a separate native region: it never
// simulates a press, remembers keyboard focus, or starts the internal row drag.
Item {
  id: root
  required property var controller
  required property string rowKey
  // Connector of the PanelWindow that owns this row (mirrored panels).
  property string panelConnector: ""
  // Workspace header: whole-card hover via viewport.hoveredWorkspaceKey + grab cursor.
  property bool workspaceHeader: false
  property bool dragEnabled: true
  property var viewport: null
  // Shared external-drag coordinator and the surface owner that holds it open.
  // Rows only supply identity; the controller owns every dispatch.
  property var navigation: root.controller
    ? root.controller.externalDragNavigation || null : null
  property var navigationOwner: null
  property bool navigationEnabled: true
  // Child-target priority: the inline workspace badge outranks its enclosing row
  // for the same visit, independent of drag-entry order.
  property int externalPriority: 0
  property var externalTarget: null
  readonly property var externalDragArea: externalArea
  readonly property bool externalEligible: enabled && !!root.navigation
    && root.navigationEnabled
    && !controller.rowDragActive && !controller.resizeActive
    && !controller.interactionBusy
  // Key last published to viewport; clear uses this even after kind/key change.
  property string lastPublishedWorkspaceKey: ""
  property var pressedTarget: null
  property string pressedConnector: ""
  property bool consumed: false
  property bool dragOwned: false
  readonly property bool inputEnabled: enabled
    && (!controller.interactionBusy || dragOwned)
  signal activated(var target, bool control, string connector, int modifiers)
  signal contextRequested(var target)
  signal focusRequested()
  signal dragMoved(var scenePoint)
  signal dragReleased(var scenePoint)

  // Capture once per stable row identity. The controller revalidates liveness,
  // location and provider state immediately before dispatch, so a held capture
  // can only ever fail closed. Recomputation is skipped while a token is held to
  // keep the dwell timer from restarting on unrelated inventory refreshes.
  function refreshExternalTarget() {
    var descriptor = null
    if (root.rowKey && root.controller
        && typeof root.controller.externalDragTarget === "function")
      descriptor = root.controller.externalDragTarget(root.rowKey)
    root.externalTarget = descriptor
      ? Object.assign({}, descriptor, {priority: root.externalPriority})
      : null
  }

  function clearPublishedWorkspaceHover() {
    var published = root.lastPublishedWorkspaceKey
    root.lastPublishedWorkspaceKey = ""
    if (!root.viewport || published === "") return
    if (root.viewport.hoveredWorkspaceKey === published)
      root.viewport.hoveredWorkspaceKey = ""
  }

  function syncWorkspaceHover(active) {
    if (!root.viewport) return
    if (active) {
      if (!root.workspaceHeader || root.controller.rowDragActive) return
      var key = root.rowKey
      if (!key) return
      root.viewport.hoveredWorkspaceKey = key
      root.lastPublishedWorkspaceKey = key
      return
    }
    root.clearPublishedWorkspaceHover()
  }

  function capturePress() {
    root.consumed = false
    root.pressedTarget = root.controller.captureTarget(root.rowKey)
    root.pressedConnector = root.panelConnector || root.controller.selectedConnector
    root.controller.rememberNavigationFocus()
    root.focusRequested()
  }

  function completeTap(control, modifiers) {
    var target = root.pressedTarget
    var monitor = root.pressedConnector
    root.pressedTarget = null
    if (!root.consumed && target && !root.controller.interactionBusy)
      root.activated(target, control === true, monitor, Number(modifiers || 0))
  }

  function cancelGesture(reason) {
    root.consumed = true
    root.pressedTarget = null
    if (root.dragOwned) root.controller.cancelRowDrag(reason)
    root.dragOwned = false
    // Always clear published hover; do not reassert. Later hover-enter republishes.
    root.clearPublishedWorkspaceHover()
  }

  readonly property bool hovered: !root.controller.rowDragActive && hover.hovered
  readonly property bool pressed: plainTap.pressed || controlTap.pressed

  HoverHandler {
    id: hover
    enabled: root.inputEnabled
    cursorShape: root.dragOwned ? Qt.ClosedHandCursor : Qt.ArrowCursor
    onHoveredChanged: root.syncWorkspaceHover(hovered)
  }

  // Grab cursor only on workspace headers; other rows keep the default arrow.
  HoverHandler {
    enabled: root.inputEnabled && root.workspaceHeader
    cursorShape: root.dragOwned || root.pressed
      ? Qt.ClosedHandCursor : Qt.OpenHandCursor
  }

  TapHandler {
    id: plainTap
    enabled: root.inputEnabled
    acceptedButtons: Qt.LeftButton
    acceptedModifiers: Qt.NoModifier
    onPressedChanged: if (pressed) root.capturePress()
    onTapped: root.completeTap(false, point.modifiers)
    onCanceled: root.consumed = true
  }
  TapHandler {
    id: controlTap
    enabled: root.inputEnabled
    acceptedButtons: Qt.LeftButton
    acceptedModifiers: Qt.ControlModifier
    onPressedChanged: if (pressed) root.capturePress()
    onTapped: root.completeTap(true, point.modifiers)
    onCanceled: root.consumed = true
  }
  TapHandler {
    enabled: root.inputEnabled
    acceptedButtons: Qt.RightButton
    onPressedChanged: if (pressed) root.capturePress()
    onTapped: {
      var target = root.pressedTarget
      root.pressedTarget = null
      if (!root.consumed && target) root.contextRequested(target)
    }
    onCanceled: root.consumed = true
  }
  DragHandler {
    id: drag
    target: null
    cursorShape: Qt.ClosedHandCursor
    enabled: root.inputEnabled && root.dragEnabled
    acceptedButtons: Qt.LeftButton
    onActiveChanged: if (active) {
      root.consumed = true
      root.dragOwned = root.controller.beginRowDrag(root.pressedTarget, root.pressedConnector,
        root.viewport ? root.viewport.dropSurfaceGeneration : 0)
      if (root.dragOwned) root.dragMoved(centroid.scenePosition)
    }
    onTranslationChanged: if (active && root.dragOwned) root.dragMoved(centroid.scenePosition)
    // Qt 6.4 also drops active on cancellation. Only UngrabExclusive is a
    // successful release; never commit from onActiveChanged(false).
    onGrabChanged: function(transition, point) {
      if (transition === PointerDevice.UngrabExclusive && root.dragOwned) {
        root.dragReleased(point.scenePosition)
        root.dragOwned = false
        root.pressedTarget = null
      } else if (transition === PointerDevice.CancelGrabExclusive
                 || transition === PointerDevice.CancelGrabPassive) {
        root.cancelGesture("grab-loss")
      }
    }
  }
  Connections {
    target: root.controller
    function onRowDragActiveChanged() {
      if (!root.controller.rowDragActive && root.dragOwned) root.cancelGesture("controller-cancelled")
    }
  }
  // Recapture on drag entry so a row exposed by a projection refresh (expanded
  // application, provider snapshot, scroll anchor) is immediately eligible.
  Connections {
    target: externalArea
    function onContainsDragChanged() {
      if (externalArea.containsDrag) root.refreshExternalTarget()
    }
  }
  // Nonvisual native drag region. It is deliberately outside the tap/drag
  // handlers above: external hover never fires activated/focusRequested or the
  // internal row-drag lifecycle.
  DockExternalDragArea {
    id: externalArea
    anchors.fill: parent
    navigation: root.navigation
    owner: root.navigationOwner
    targetDescriptor: root.externalTarget
    navigationEnabled: root.externalEligible
  }
  onEnabledChanged: if (!enabled) root.cancelGesture("input-disabled")
  onRowKeyChanged: {
    root.cancelGesture("delegate-reassigned")
    root.refreshExternalTarget()
  }
  onExternalPriorityChanged: if (externalArea.token === 0) root.refreshExternalTarget()
  onNavigationEnabledChanged: if (externalArea.token === 0) root.refreshExternalTarget()
  onWorkspaceHeaderChanged: if (!workspaceHeader) root.clearPublishedWorkspaceHover()
  Component.onCompleted: root.refreshExternalTarget()
  Component.onDestruction: root.cancelGesture("source-destroyed")
}
