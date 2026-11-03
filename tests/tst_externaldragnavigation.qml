import QtQuick
import QtTest
import "../components"

TestCase {
  name: "ExternalDragNavigation"
  when: windowShown

  QtObject {
    id: actions
    property var alive: []
    property var focused: []
    property int focusCount: 0
    property var workspaces: []
    property int workspaceCount: 0
    function focusToplevelInPlace(toplevel) {
      if (!toplevel || alive.indexOf(toplevel) < 0) return false
      focused = focused.concat([toplevel])
      focusCount++
      return true
    }
    function focusWorkspaceInPlace(identity) {
      if (!identity) return false
      workspaces = workspaces.concat([identity])
      workspaceCount++
      return true
    }
  }

  QtObject {
    id: sidebar
    property var activated: []
    property int activationCount: 0
    function activateExternalDragTarget(target) {
      if (!target) return false
      activated = activated.concat([target])
      activationCount++
      return true
    }
  }

  Component {
    id: ownerFactory
    QtObject {}
  }

  Component {
    id: holdFactory
    QtObject {
      property var navigation: null
      property var targetOwner: null
      property bool held: navigation ? navigation.heldFor(targetOwner) : false
    }
  }

  Component {
    id: navigationFactory
    DockExternalDragNavigation {
      windowActions: actions
      sidebarController: sidebar
      enabled: true
      dwellMs: 40
      handoffMs: 40
    }
  }

  function makeNavigation(properties) {
    var nav = createTemporaryObject(navigationFactory, this, properties || ({}))
    verify(nav)
    return nav
  }

  function makeOwner() {
    var owner = createTemporaryObject(ownerFactory, this)
    verify(owner)
    return owner
  }

  function makeHold(nav, owner) {
    var hold = createTemporaryObject(holdFactory, this,
      {navigation: nav, targetOwner: owner})
    verify(hold)
    return hold
  }

  function resetActions() {
    actions.alive = []
    actions.focused = []
    actions.focusCount = 0
    actions.workspaces = []
    actions.workspaceCount = 0
    sidebar.activated = []
    sidebar.activationCount = 0
  }

  function windowTarget(toplevel, key) {
    return {key: key || "window:0x1", kind: "window", toplevel: toplevel}
  }

  function test_dwellActivatesOnce() {
    resetActions()
    var nav = makeNavigation({dwellMs: 40, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    nav.enter(owner, windowTarget(toplevel))
    compare(actions.focusCount, 0, "dwell never focuses immediately")
    tryCompare(actions, "focusCount", 1, 500)
    wait(120)
    compare(actions.focusCount, 1, "activation fires exactly once per visit")
    compare(actions.focused[0], toplevel)
    nav.endSession()
  }

  function test_sameTargetMotionDoesNotRestart() {
    resetActions()
    var nav = makeNavigation({dwellMs: 120, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var start = Date.now()
    nav.enter(owner, windowTarget(toplevel))
    wait(70)
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 400)
    verify(Date.now() - start < 180, "motion within the target must not restart the dwell")
  }

  function test_exitCancelsImmediately() {
    resetActions()
    var nav = makeNavigation({dwellMs: 80, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var token = nav.enter(owner, windowTarget(toplevel))
    wait(20)
    verify(nav.leave(token))
    wait(140)
    compare(actions.focusCount, 0, "exiting before expiry cancels activation")
    verify(!nav.pendingActive)
  }

  function test_staleLeaveCannotCancelNewTarget() {
    resetActions()
    var nav = makeNavigation({dwellMs: 80, handoffMs: 40})
    var owner = makeOwner()
    var first = createTemporaryObject(ownerFactory, this)
    var second = createTemporaryObject(ownerFactory, this)
    actions.alive = [first, second]
    var stale = nav.enter(owner, windowTarget(first, "window:first"))
    nav.enter(owner, windowTarget(second, "window:second"))
    // A recycled delegate's late leave must not cancel the new target.
    compare(nav.leave(stale), true)
    tryCompare(actions, "focusCount", 1, 500)
    compare(actions.focused[0], second, "the new target still activates")
  }

  function test_ownerHandoffHoldsOnlyVisibility() {
    resetActions()
    var nav = makeNavigation({dwellMs: 1000, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var hold = makeHold(nav, owner)
    var token = nav.enter(owner, windowTarget(toplevel))
    verify(hold.held, "the dock is held while the drag is over it")
    nav.leave(token)
    verify(hold.held, "visibility survives the 200 ms-class handoff grace")
    tryCompare(hold, "held", false, 500)
    compare(actions.focusCount, 0, "a held surface never continues activation after exit")
    nav.endSession()
  }

  function test_removedTargetDoesNotActivate() {
    resetActions()
    var nav = makeNavigation({dwellMs: 30, handoffMs: 40})
    var owner = makeOwner()
    var dead = createTemporaryObject(ownerFactory, this)
    actions.alive = []
    nav.enter(owner, windowTarget(dead))
    wait(120)
    compare(actions.focusCount, 0, "a vanished toplevel fails closed")
    compare(nav.firedKey, "")
    nav.endSession()
  }

  function test_ownerDestructionClearsHold() {
    resetActions()
    var nav = makeNavigation({dwellMs: 40, handoffMs: 200})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var hold = makeHold(nav, owner)
    nav.enter(owner, windowTarget(toplevel))
    verify(hold.held)
    verify(nav.cancelOwner(owner))
    verify(!hold.held, "owner destruction clears the hold without waiting for grace")
    wait(120)
    compare(actions.focusCount, 0)
  }

  function test_reprojectionDoesNotRepeatActivation() {
    resetActions()
    var nav = makeNavigation({dwellMs: 30, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var token = nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    // Delegate reconstruction releases the old token without a genuine exit.
    nav.leave(token, false)
    var replacement = nav.enter(owner, windowTarget(toplevel))
    wait(120)
    compare(actions.focusCount, 1, "a recycled delegate must not repeat the activation")
    nav.leave(replacement, false)
    nav.endSession()
  }

  function test_reprojectionAfterHandoffDoesNotRepeat() {
    resetActions()
    var nav = makeNavigation({dwellMs: 30, handoffMs: 30})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var token = nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    // Focus/projection teardown is not a genuine pointer exit, however long it
    // takes: the fired latch survives past the visibility handoff.
    nav.leave(token, false)
    wait(100)
    nav.enter(owner, windowTarget(toplevel))
    wait(120)
    compare(actions.focusCount, 1, "projection after handoff does not re-activate")
    nav.endSession()
  }

  function test_sameTargetExitReentryWithinHandoffSuppressed() {
    resetActions()
    var nav = makeNavigation({dwellMs: 30, handoffMs: 80})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var token = nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    nav.leave(token, true)
    wait(10)
    var reentry = nav.enter(owner, windowTarget(toplevel))
    wait(120)
    compare(actions.focusCount, 1, "re-entry inside the handoff stays latched")
    nav.leave(reentry, true)
    wait(150)
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 2, 500)
    nav.endSession()
  }

  function test_newDragSessionActivatesAgain() {
    resetActions()
    var nav = makeNavigation({dwellMs: 30, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    nav.endSession()
    compare(nav.sessionActive, false)
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 2, 500)
    nav.endSession()
  }

  function test_liveDisableCancelsPendingAndHolds() {
    resetActions()
    var nav = makeNavigation({dwellMs: 60, handoffMs: 200})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    var hold = makeHold(nav, owner)
    nav.enter(owner, windowTarget(toplevel))
    wait(20)
    nav.enabled = false
    verify(!nav.pendingActive, "disabling clears the pending dwell")
    verify(!hold.held, "disabling clears drag-owned visibility immediately")
    wait(120)
    compare(actions.focusCount, 0, "a disabled coordinator never focuses")
    nav.enabled = true
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    nav.endSession()
  }

  function test_delayReloadCancelsCurrentDwell() {
    resetActions()
    var nav = makeNavigation({dwellMs: 200, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    nav.enter(owner, windowTarget(toplevel))
    wait(40)
    nav.dwellMs = 30
    verify(!nav.pendingActive, "changing the delay cancels the current dwell")
    wait(100)
    compare(actions.focusCount, 0, "the old dwell must not fire unexpectedly")
    nav.enter(owner, windowTarget(toplevel))
    tryCompare(actions, "focusCount", 1, 500)
    nav.endSession()
  }

  function test_kindRoutingUsesExistingOwners() {
    resetActions()
    var nav = makeNavigation({dwellMs: 20, handoffMs: 40})
    var owner = makeOwner()
    nav.enter(owner, {key: "workspace:id:3", kind: "workspace",
      workspaceIdentity: "id:3"})
    tryCompare(actions, "workspaceCount", 1, 500)
    compare(actions.workspaces[0], "id:3")
    nav.endSession()

    var tab = {key: "tab:42", kind: "browser-tab", sidebarTarget: {rowKey: "tab:42"}}
    nav.enter(owner, tab)
    tryCompare(sidebar, "activationCount", 1, 500)
    compare(sidebar.activated[0].rowKey, "tab:42")
    nav.endSession()

    nav.enter(owner, {key: "application:a", kind: "application",
      sidebarTarget: {rowKey: "application:a"}})
    tryCompare(sidebar, "activationCount", 2, 500)
    nav.endSession()
  }

  function test_previewRequestsButNeverFocuses() {
    resetActions()
    var nav = makeNavigation({dwellMs: 20, handoffMs: 40})
    var owner = makeOwner()
    var requests = []
    nav.previewRequested.connect(function(requestOwner, key, anchor) {
      requests.push({owner: requestOwner, key: key, anchor: anchor})
    })
    nav.enter(owner, {key: "preview:chrome", kind: "preview", anchor: null})
    tryCompare(nav, "firedKey", "preview:chrome", 500)
    compare(requests.length, 1)
    compare(requests[0].owner, owner)
    compare(requests[0].key, "preview:chrome")
    compare(actions.focusCount, 0, "preview requests never dispatch focus")
    nav.endSession()
  }

  function test_revealOnlyHolds() {
    resetActions()
    var nav = makeNavigation({dwellMs: 20, handoffMs: 40})
    var owner = makeOwner()
    var hold = makeHold(nav, owner)
    var token = nav.enter(owner, {key: "reveal:dock", kind: "reveal"})
    verify(hold.held)
    verify(!nav.pendingActive, "the reveal strip never arms an activation timer")
    wait(80)
    compare(actions.focusCount, 0)
    nav.leave(token)
    tryCompare(hold, "held", false, 500)
    nav.endSession()
  }
}
