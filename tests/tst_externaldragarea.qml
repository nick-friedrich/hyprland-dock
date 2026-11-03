import QtQuick
import QtTest
import "../components"

TestCase {
  name: "ExternalDragArea"
  when: windowShown
  visible: true
  width: 420
  height: 260

  QtObject {
    id: actions
    property var alive: []
    property int focusCount: 0
    function focusToplevelInPlace(toplevel) {
      if (!toplevel || alive.indexOf(toplevel) < 0) return false
      focusCount++
      return true
    }
    function focusWorkspaceInPlace(identity) { return !!identity }
  }

  // Native Qt Quick drag source. Drag.Internal exercises the in-process Qt
  // drag/drop routing; the real Wayland data-device handoff is qualified only
  // by the Task 1/Task 5 KVM evidence.
  Item {
    id: source
    x: 10
    y: 10
    width: 48
    height: 48
    Drag.active: sourceMouse.drag.active
    Drag.dragType: Drag.Internal
    Drag.hotSpot: Qt.point(24, 24)
    Drag.mimeData: {"text/plain": "opaque payload"}
    Rectangle {
      anchors.fill: parent
      color: "#d55"
    }
    MouseArea {
      id: sourceMouse
      anchors.fill: parent
      drag.target: source
      drag.threshold: 1
    }
  }

  Component {
    id: navigationFactory
    DockExternalDragNavigation {
      windowActions: actions
      enabled: true
      dwellMs: 1500
      handoffMs: 40
    }
  }

  Component {
    id: surfaceFactory
    QtObject {}
  }

  Component {
    id: toplevelFactory
    QtObject {}
  }

  Component {
    id: areaFactory
    DockExternalDragArea {}
  }

  function init() {
    source.x = 10
    source.y = 10
    source.Drag.mimeData = {"text/plain": "opaque payload"}
  }

  function makeNavigation() {
    var nav = createTemporaryObject(navigationFactory, this)
    verify(nav)
    return nav
  }

  function beginDrag(formats) {
    source.Drag.mimeData = formats || {"text/plain": "opaque payload"}
    mousePress(source, 24, 24)
    mouseMove(source, 34, 34, 10, Qt.LeftButton)
  }

  function test_nativeDragKeepsTrackingAndExitCancels() {
    actions.focusCount = 0
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var toplevel = createTemporaryObject(toplevelFactory, this)
    actions.alive = [toplevel]
    var target = createTemporaryObject(areaFactory, this, {
      x: 220, y: 40, width: 140, height: 140,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "window:0x1", kind: "window", toplevel: toplevel}
    })
    verify(target)

    beginDrag()
    mouseMove(target, 60, 60, 20, Qt.LeftButton)
    tryCompare(target, "containsDrag", true, 1000)
    verify(target.token !== 0, "entry keeps an adaptive tracking token")
    verify(nav.pendingActive, "a real drag entry arms the dwell")
    compare(actions.focusCount, 0, "the configured dwell has not expired")
    compare(target.keys.length, 0, "no MIME keys predicate limits eligibility")

    // Leaving the target before expiry cancels the pending activation.
    mouseMove(this, 380, 230, 20, Qt.LeftButton)
    tryCompare(target, "containsDrag", false, 1000)
    compare(target.token, 0)
    verify(!nav.pendingActive, "target exit releases the tracking token")
    wait(80)
    compare(actions.focusCount, 0)
    mouseRelease(this, 380, 230, Qt.LeftButton)
    nav.endSession()
  }

  function test_dropContractExplicitlyRejects() {
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var target = createTemporaryObject(areaFactory, this, {
      x: 220, y: 40, width: 140, height: 140,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "window:drop", kind: "window"}
    })
    target.begin()
    verify(nav.pendingActive)
    // Qt delivers accepted=true by default; the adapter's handler must override it.
    var event = {accepted: true}
    verify(target.handleDrop(event))
    compare(event.accepted, false, "onDropped always rejects the navigation target")
    compare(target.lastDropAccepted, false)
    compare(nav.sessionActive, false, "a completed/rejected drop ends the session")
    compare(nav.pendingActive, false)
    nav.endSession()
  }

  function test_arbitraryMimeIsEligibleWithoutPayloadReads() {
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var toplevel = createTemporaryObject(toplevelFactory, this)
    actions.alive = [toplevel]
    var target = createTemporaryObject(areaFactory, this, {
      x: 220, y: 40, width: 140, height: 140,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "window:mime", kind: "window", toplevel: toplevel}
    })
    beginDrag({"application/x-dockrail-fixture": "never-read"})
    mouseMove(target, 50, 50, 20, Qt.LeftButton)
    tryCompare(target, "containsDrag", true, 1000)
    verify(target.token !== 0, "arbitrary formats enter without a payload predicate")
    mouseMove(this, 380, 230, 20, Qt.LeftButton)
    tryCompare(target, "containsDrag", false, 1000)
    mouseRelease(this, 380, 230, Qt.LeftButton)
    nav.endSession()
  }

  function test_internalGestureDisablesNavigation() {
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var toplevel = createTemporaryObject(toplevelFactory, this)
    actions.alive = [toplevel]
    var target = createTemporaryObject(areaFactory, this, {
      x: 220, y: 40, width: 140, height: 140,
      navigation: nav, owner: surface, navigationEnabled: false,
      targetDescriptor: {key: "window:internal", kind: "window", toplevel: toplevel}
    })
    beginDrag()
    mouseMove(target, 60, 60, 20, Qt.LeftButton)
    wait(60)
    compare(target.token, 0)
    verify(!nav.pendingActive, "an internal gesture suppresses external navigation")
    mouseRelease(target, 60, 60, Qt.LeftButton)
    nav.endSession()
  }

  function test_nestedBadgeWinsOverRowInBothEntryOrders() {
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var row = createTemporaryObject(areaFactory, this, {
      x: 10, y: 120, width: 200, height: 60,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "row:window", kind: "window", priority: 0}
    })
    var badge = createTemporaryObject(areaFactory, this, {
      x: 10, y: 120, width: 40, height: 40, z: 2,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "badge:workspace", kind: "workspace",
        workspaceIdentity: "id:3", priority: 10}
    })

    row.begin()
    badge.begin()
    compare(nav.pending.key, "badge:workspace", "badge wins when it enters second")
    nav.cancelOwner(surface)
    compare(nav.pending, null)

    badge.begin()
    row.begin()
    compare(nav.pending.key, "badge:workspace", "row entry does not replace the badge")
    nav.endSession()
  }

  function test_recycledDelegateReleasesPreviousToken() {
    var nav = makeNavigation()
    var surface = createTemporaryObject(surfaceFactory, this)
    var target = createTemporaryObject(areaFactory, this, {
      x: 10, y: 90, width: 120, height: 120,
      navigation: nav, owner: surface,
      targetDescriptor: {key: "window:first", kind: "window"}
    })
    var firstToken = target.begin()
    verify(firstToken !== 0)
    verify(nav.heldFor(surface))
    target.targetDescriptor = {key: "window:second", kind: "window"}
    verify(nav.leave(firstToken) === false, "the delegate released its previous token")
    compare(target.token, 0, "reassignment waits for a fresh drag entry")
    target.begin()
    compare(nav.pending.key, "window:second")
    target.destroy()
    nav.endSession()
    verify(!nav.heldFor(surface))
  }
}
