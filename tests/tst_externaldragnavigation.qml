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

  function test_passiveRevealKeepsEnclosedPendingTarget() {
    resetActions()
    var nav = makeNavigation({dwellMs: 40, handoffMs: 40})
    var owner = makeOwner()
    var toplevel = createTemporaryObject(ownerFactory, this)
    actions.alive = [toplevel]
    // A dock-wide surface hold may arrive before or after the icon target.
    nav.enter(owner, {key: "reveal:surface", kind: "reveal", passive: true})
    nav.enter(owner, windowTarget(toplevel))
    compare(nav.pending.key, "window:0x1")
    nav.enter(owner, {key: "reveal:surface", kind: "reveal", passive: true})
    tryCompare(actions, "focusCount", 1, 500)
    compare(nav.pending, null)
    verify(nav.heldFor(owner))
    nav.endSession()
  }

  // --- Sidebar integration: descriptors, revalidation and narrow routing -----

  // Shared local probe: records the order of sidebar/window dispatches so tests
  // can prove focus happens before provider tab activation.
  QtObject {
    id: probe
    property var events: []
    function reset() { events = [] }
  }

  QtObject {
    id: sidebarActions
    property var windows: []
    property var workspaceOwners: ({})
    property var focused: []
    property var focusedWorkspaces: []
    property int pullCount: 0
    property int moveWorkspaceCount: 0
    property int activateCount: 0
    property int cycleCount: 0
    function reset() {
      windows = []
      workspaceOwners = {}
      focused = []
      focusedWorkspaces = []
      pullCount = 0
      moveWorkspaceCount = 0
      activateCount = 0
      cycleCount = 0
      probe.reset()
    }
    function entry(toplevel) {
      for (var i = 0; i < windows.length; ++i) {
        if (windows[i].toplevel === toplevel) return windows[i]
      }
      return null
    }
    function isAlive(toplevel) {
      return !!toplevel && entry(toplevel) !== null
    }
    function addressFor(toplevel) {
      var value = entry(toplevel)
      return value ? value.address : ""
    }
    function resolveWorkspaceDropTarget(identity) {
      var owner = workspaceOwners[String(identity || "")]
      if (!owner) return null
      return {identity: String(identity), target: String(identity).replace("id:", ""),
        monitor: owner}
    }
    function focusToplevelInPlace(toplevel) {
      if (!isAlive(toplevel)) return false
      focused = focused.concat([toplevel])
      probe.events = probe.events.concat(["focus"])
      return true
    }
    function focusWorkspaceInPlace(identity) {
      if (!resolveWorkspaceDropTarget(identity)) return false
      focusedWorkspaces = focusedWorkspaces.concat([String(identity)])
      probe.events = probe.events.concat(["workspace"])
      return true
    }
    // Relocation/cycle entry points exist only so the tests can prove the
    // external path never reaches them.
    function activateToplevel() { activateCount++; return true }
    function pullToplevelToMonitorWorkspace() { pullCount++; return true }
    function moveWorkspaceToMonitor() { moveWorkspaceCount++; return true }
    function cycleToplevels() { cycleCount++; return true }
  }

  QtObject {
    id: sidebarBrowserService
    property bool available: true
    property int revision: 0
    property var tabs: ({})
    property bool activationInFlight: false
    property var activations: []
    function reset() {
      available = true
      revision = 0
      tabs = ({})
      activationInFlight = false
      activations = []
    }
    function allTabRows() {
      var rows = []
      Object.keys(tabs || ({})).forEach(function(key) {
        ;(tabs[key] || []).forEach(function(tab) {
          rows.push({targetId: String(tab.targetId || ""),
            windowAddress: String(key).toLowerCase()})
        })
      })
      return rows
    }
    function activateTarget(targetId) {
      if (!available || activationInFlight) return false
      activations = activations.concat([String(targetId)])
      probe.events = probe.events.concat(["activate"])
      return true
    }
  }

  Component {
    id: sidebarFactory
    DockSidebarController {}
  }
  Component {
    id: sidebarToplevelFactory
    QtObject {
      property string appId: "app"
      property string title: ""
      property bool activated: false
    }
  }

  function sidebarSettings() {
    return {presentationMode: "sidebar", pinned: ["terminal"], workspaceGroups: [],
      sidebarCollapsed: false, sidebarBrowserTabsEnabled: true,
      sidebarInlineSoloWorkspace: true}
  }

  // Two populated workspaces on one monitor: a multi-window application group
  // (inline badge on its header) and a sole window (inline badge on the window
  // row, plus browser-tab children). A pinned launcher with no windows covers
  // the excluded launcher kind.
  function makeSidebarFixture() {
    sidebarActions.reset()
    sidebarBrowserService.reset()
    var multiA = createTemporaryObject(sidebarToplevelFactory, this,
      {appId: "aa-multi", title: "Multi A"})
    var multiB = createTemporaryObject(sidebarToplevelFactory, this,
      {appId: "aa-multi", title: "Multi B"})
    var solo = createTemporaryObject(sidebarToplevelFactory, this,
      {appId: "zz-solo", title: "Solo"})
    verify(multiA && multiB && solo)
    sidebarActions.windows = [
      {toplevel: multiA, address: "0xa1"},
      {toplevel: multiB, address: "0xa2"},
      {toplevel: solo, address: "0x5b"}
    ]
    sidebarActions.workspaceOwners = {"id:1": "id:0", "id:2": "id:0"}
    sidebarBrowserService.tabs = {"0x5b": [
      {targetId: "tab-1", title: "Inbox", active: true, faviconPath: ""}
    ]}
    var controller = createTemporaryObject(sidebarFactory, this, {
      settings: sidebarSettings(),
      screens: [{name: "DP-1", width: 1920, height: 1080}],
      monitors: [{id: 0, name: "DP-1", activeWorkspace: {id: 1}}],
      workspaces: [{id: 1, monitorID: 0}, {id: 2, monitorID: 0}],
      toplevels: [multiA, multiB, solo],
      hyprToplevels: [
        {wayland: multiA, address: "0xa1",
          lastIpcObject: {workspace: {id: 1}, monitor: 0}},
        {wayland: multiB, address: "0xa2",
          lastIpcObject: {workspace: {id: 1}, monitor: 0}},
        {wayland: solo, address: "0x5b",
          lastIpcObject: {workspace: {id: 2}, monitor: 0}}
      ],
      host: {windowActions: sidebarActions,
        browserProfileService: sidebarBrowserService}
    })
    verify(controller)
    controller.refresh()
    return {controller: controller, multiA: multiA, multiB: multiB, solo: solo}
  }

  function rowsOfKind(controller, kind) {
    return (controller.projection.rows || []).filter(function(row) {
      return row.kind === kind
    })
  }

  function findRow(controller, predicate) {
    var rows = controller.projection.rows || []
    for (var i = 0; i < rows.length; ++i) {
      if (predicate(rows[i])) return rows[i]
    }
    return null
  }

  function test_sidebarExternalDescriptorKinds() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller

    var windowRow = rowsOfKind(controller, "window").filter(function(row) {
      return row.toplevel === fixture.multiA
    })[0]
    verify(windowRow)
    var windowTarget = controller.externalDragTarget(windowRow.key)
    verify(windowTarget)
    compare(windowTarget.kind, "window")
    compare(windowTarget.key, "window:0xa1")
    compare(windowTarget.toplevel, fixture.multiA)
    compare(windowTarget.workspaceIdentity, "id:1")
    compare(windowTarget.sidebarTarget.key, windowRow.key)

    var workspaceTarget = controller.externalDragTarget(
      controller.projection.workspaceTargets[0].key)
    verify(workspaceTarget)
    compare(workspaceTarget.kind, "workspace")
    compare(workspaceTarget.key, "workspace:id:1")
    compare(workspaceTarget.workspaceIdentity, "id:1")

    var tabRow = rowsOfKind(controller, "browser-tab")[0]
    verify(tabRow)
    var tabTarget = controller.externalDragTarget(tabRow.key)
    verify(tabTarget)
    compare(tabTarget.kind, "browser-tab")
    compare(tabTarget.key, "browser-tab:tab-1:0x5b")
    compare(tabTarget.sidebarTarget.targetId, "tab-1")
    compare(tabTarget.sidebarTarget.windowAddress, "0x5b")

    // The leading inline badge resolves the workspace; its enclosing row keeps
    // resolving its own window/application target.
    var appRow = findRow(controller, function(row) {
      return row.kind === "application" && !!row.leadingWorkspace
    })
    verify(appRow, "workspace 1 puts its inline badge on the application header")
    var appTarget = controller.externalDragTarget(appRow.key)
    compare(appTarget.kind, "application")
    compare(appTarget.key, "application:" + appRow.key)
    var appBadgeTarget = controller.externalDragTarget(appRow.leadingWorkspace.key)
    compare(appBadgeTarget.kind, "workspace")
    compare(appBadgeTarget.workspaceIdentity, "id:1")

    var soloRow = findRow(controller, function(row) {
      return row.kind === "window" && !!row.leadingWorkspace
    })
    verify(soloRow, "a sole window row carries the inline workspace badge")
    compare(controller.externalDragTarget(soloRow.key).kind, "window")
    compare(controller.externalDragTarget(soloRow.leadingWorkspace.key).workspaceIdentity,
      "id:2")
    controller.destroy()
  }

  function test_sidebarExternalApplicationExpansionAndExclusions() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var appRow = findRow(controller, function(row) {
      return row.kind === "application" && row.expandable === true
    })
    verify(appRow)
    var appTarget = controller.externalDragTarget(appRow.key)
    verify(appTarget)

    // Fold the group and let the projection settle; a collapsed group exposes
    // only its header but stays an expansion target.
    var folds = {}
    folds[appRow.key] = true
    controller.folds = folds
    controller.refresh()
    var foldedRow = controller.rowsByKey[appRow.key]
    verify(foldedRow && foldedRow.folded === true)
    compare(rowsOfKind(controller, "window").filter(function(row) {
      return row.toplevel === fixture.multiA
    }).length, 0, "collapsed application hides its members")
    var foldedTarget = controller.externalDragTarget(appRow.key)
    verify(foldedTarget)
    compare(foldedTarget.kind, "application")

    var writes = 0
    controller.host = {windowActions: sidebarActions,
      browserProfileService: sidebarBrowserService,
      saveSetting: function() { writes++; return {ok: true, data: {applied: true}} }}
    compare(controller.activateExternalDragTarget(foldedTarget.sidebarTarget), true)
    compare(controller.folds[appRow.key], undefined, "expansion clears the fold flag once")
    tryVerify(function() {
      return controller.projection.rows.filter(function(row) {
        return row.kind === "window" && row.toplevel === fixture.multiA
      }).length === 1
    }, 500)
    compare(writes, 0, "expansion never writes configuration")
    compare(sidebarActions.focused.length, 0, "expansion never focuses")
    compare(sidebarActions.pullCount, 0)

    // An already expanded group is never folded closed, and repeated dwells are
    // idempotent.
    var expandedTarget = controller.externalDragTarget(appRow.key)
    compare(controller.activateExternalDragTarget(expandedTarget.sidebarTarget), true)
    compare(controller.folds[appRow.key], undefined)
    compare(controller.projection.rows.filter(function(row) {
      return row.kind === "window" && row.toplevel === fixture.multiB
    }).length, 1)
    compare(writes, 0)

    // Cancellation leaves the group expanded, matching manual expansion.
    controller.cancelRowDrag("escape")
    compare(controller.folds[appRow.key], undefined)
    verify(rowsOfKind(controller, "window").length >= 2)

    // Newly exposed window rows immediately resolve their own targets.
    var exposed = rowsOfKind(controller, "window").filter(function(row) {
      return row.toplevel === fixture.multiB
    })[0]
    compare(controller.externalDragTarget(exposed.key).kind, "window")

    // Excluded kinds: monitors, launcher-only pins and unknown rows.
    var monitorRow = rowsOfKind(controller, "monitor")[0]
    compare(controller.externalDragTarget(monitorRow.key), null)
    var launcherRow = (controller.projection.launchers || [])[0]
    verify(launcherRow, "the pinned terminal without windows is a launcher row")
    compare(controller.externalDragTarget(launcherRow.key), null)
    compare(controller.externalDragTarget("window:missing"), null)
    compare(controller.externalDragTarget(""), null)
    controller.destroy()
  }

  function test_sidebarExternalWindowFocusInPlaceWithoutRelocation() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var windowRow = rowsOfKind(controller, "window").filter(function(row) {
      return row.toplevel === fixture.solo
    })[0]
    var target = controller.externalDragTarget(windowRow.key)
    verify(target)
    probe.reset()
    compare(controller.activateExternalDragTarget(target.sidebarTarget), true)
    compare(sidebarActions.focused.length, 1)
    compare(sidebarActions.focused[0], fixture.solo)
    compare(probe.events.join(","), "focus")
    compare(sidebarActions.pullCount, 0, "hover never pulls a window to another monitor")
    compare(sidebarActions.activateCount, 0, "hover never routes through the click action")
    compare(sidebarActions.cycleCount, 0)
    compare(controller.interactionBusy, false,
      "external hover keeps live inventory refreshing")
    compare(controller.focusReturnTarget, null)

    // A dead capture fails closed.
    sidebarActions.windows = sidebarActions.windows.filter(function(entry) {
      return entry.toplevel !== fixture.solo
    })
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false)
    compare(sidebarActions.focused.length, 1)
    controller.destroy()
  }

  function test_sidebarExternalWorkspaceUsesCurrentMonitor() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var workspaceKey = controller.projection.workspaceTargets[0].key
    var target = controller.externalDragTarget(workspaceKey)
    verify(target)
    // Reassign the workspace to the other monitor mid-dwell. The internal
    // relocation predicate keeps rejecting the stale monitor; the external
    // validator accepts the workspace where it lives now.
    sidebarActions.workspaceOwners = {"id:1": "id:1", "id:2": "id:0"}
    compare(controller.targetIsCurrent(target.sidebarTarget), false,
      "captured-monitor equality still guards internal relocation")
    compare(controller.externalTargetIsCurrent(target), true,
      "external navigation accepts the workspace at its current monitor")
    probe.reset()
    compare(controller.activateExternalDragTarget(target.sidebarTarget), true)
    compare(sidebarActions.focusedWorkspaces.length, 1)
    compare(sidebarActions.focusedWorkspaces[0], "id:1")
    compare(probe.events.join(","), "workspace")
    compare(sidebarActions.moveWorkspaceCount, 0, "hover never relocates the workspace")
    compare(sidebarActions.pullCount, 0)

    // A workspace that disappears fails closed.
    sidebarActions.workspaceOwners = {"id:2": "id:0"}
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false)
    compare(sidebarActions.focusedWorkspaces.length, 1)
    controller.destroy()
  }

  function test_sidebarExternalBrowserTabValidation() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var tabRow = rowsOfKind(controller, "browser-tab")[0]
    var target = controller.externalDragTarget(tabRow.key)
    verify(target)

    sidebarBrowserService.available = false
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false,
      "an unavailable provider fails closed")
    sidebarBrowserService.available = true
    sidebarBrowserService.activationInFlight = true
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false,
      "a busy activation fails closed")
    sidebarBrowserService.activationInFlight = false
    sidebarBrowserService.tabs = ({})
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false,
      "a tab that closed during the dwell is not activated")
    sidebarBrowserService.tabs = {"0x5b": [
      {targetId: "other-tab", title: "Other", active: true, faviconPath: ""}
    ]}
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false,
      "a tab replaced by another target is stale")
    sidebarBrowserService.tabs = {"0x5b": [
      {targetId: "tab-1", title: "Inbox", active: true, faviconPath: ""}
    ]}
    probe.reset()
    compare(controller.activateExternalDragTarget(target.sidebarTarget), true)
    compare(probe.events.join(","), "focus,activate",
      "the owning window is focused in place before its verified tab activates")
    compare(sidebarBrowserService.activations.length, 1)
    compare(sidebarBrowserService.activations[0], "tab-1")
    compare(sidebarActions.pullCount, 0)
    compare(sidebarActions.activateCount, 0, "no mute/close/click path is used")
    controller.destroy()
  }

  function test_sidebarExternalStaleCapturesFailClosed() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var windowRow = rowsOfKind(controller, "window").filter(function(row) {
      return row.toplevel === fixture.multiB
    })[0]
    var target = controller.externalDragTarget(windowRow.key)
    verify(target)

    // Screen removal and presentation-mode change leave no mapped sidebar.
    controller.screens = []
    controller.refresh()
    compare(controller.mappedScreens.length, 0)
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false)
    compare(sidebarActions.focused.length, 0)

    // Restore the surface and prove the same capture is still usable, then a
    // recycled row identity (window gone) must not activate the new occupant.
    controller.screens = [{name: "DP-1", width: 1920, height: 1080}]
    controller.refresh()
    compare(controller.externalTargetIsCurrent(target.sidebarTarget), true)
    controller.toplevels = [fixture.multiA, fixture.solo]
    controller.hyprToplevels = controller.hyprToplevels.filter(function(handle) {
      return handle.wayland !== fixture.multiB
    })
    sidebarActions.windows = sidebarActions.windows.filter(function(entry) {
      return entry.toplevel !== fixture.multiB
    })
    controller.refresh()
    compare(controller.activateExternalDragTarget(target.sidebarTarget), false)
    compare(sidebarActions.focused.length, 0)

    // Workspace regrouping after activation keeps the identity valid; an
    // unpopulated workspace target stays resolvable by canonical identity.
    var workspaceTarget = controller.externalDragTarget(
      controller.projection.workspaceTargets[0].key)
    verify(workspaceTarget)
    sidebarActions.workspaceOwners = {"id:1": "id:1", "id:2": "id:0"}
    compare(controller.externalTargetIsCurrent(workspaceTarget.sidebarTarget), true)
    controller.destroy()
  }

  function test_sidebarExternalRailExposesWindowsOnly() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    var railRows = controller.railProjection.rows || []
    compare(railRows.filter(function(row) {
      return row.kind === "application"
    }).length, 0, "rail mode renders no application headers")
    compare(railRows.filter(function(row) {
      return row.kind === "browser-tab"
    }).length, 0, "rail mode renders no browser-tab children")
    var railWindow = railRows.filter(function(row) {
      return row.kind === "window" && row.toplevel === fixture.solo
    })[0]
    verify(railWindow, "rail mode already exposes individual windows")
    compare(controller.externalDragTarget(railWindow.key).kind, "window")
    var railWorkspace = railRows.filter(function(row) {
      return row.kind === "workspace"
    })[0]
    verify(railWorkspace, "rail mode keeps workspace badge rows")
    compare(controller.externalDragTarget(railWorkspace.key).kind, "workspace")
    controller.destroy()
  }

  function test_sidebarExternalCtrlNeverRoutesRelocation() {
    var fixture = makeSidebarFixture()
    var controller = fixture.controller
    // The external entry point takes no modifier input, so a Ctrl-held content
    // drag cannot reach the internal relocation routing at all. Every kind is
    // dispatched with the modifier-carrying click API untouched.
    var targets = []
    var windowRow = rowsOfKind(controller, "window")[0]
    targets.push(controller.externalDragTarget(windowRow.key))
    targets.push(controller.externalDragTarget(controller.projection.workspaceTargets[0].key))
    targets.push(controller.externalDragTarget(rowsOfKind(controller, "browser-tab")[0].key))
    for (var i = 0; i < targets.length; ++i) {
      verify(targets[i])
      verify(controller.activateExternalDragTarget(targets[i].sidebarTarget) === true)
    }
    compare(sidebarActions.pullCount, 0, "no Ctrl relocation path from hover")
    compare(sidebarActions.moveWorkspaceCount, 0)
    compare(sidebarActions.activateCount, 0)
    compare(controller.rowDragActive, false)
    compare(controller.interactionBusy, false)
    controller.destroy()
  }
}
