import QtQuick

// Host-owned external drag dwell coordinator. It owns the single pending
// activation timer, the per-surface visibility handoff, and the fired-target
// latch. It never reads drag payloads and never saves or moves anything: every
// activation delegates to the existing window/sidebar owners.
Item {
  id: root

  property bool enabled: true
  property int dwellMs: 500
  property int handoffMs: 200
  property var windowActions: null
  property var sidebarController: null

  // A target descriptor is
  // { key, kind, toplevel?, workspaceIdentity?, sidebarTarget?, anchor?, priority? }
  // where kind is window, workspace, browser-tab, application, preview or reveal.
  // `reveal` only holds visibility; `preview` emits previewRequested instead of
  // dispatching focus.
  signal previewRequested(var owner, string key, var anchor)

  readonly property bool pendingActive: pending !== null
  property var pending: null
  property var tokens: []
  property var holds: []
  property bool sessionActive: false
  property string firedKey: ""
  property int holdRevision: 0
  property int tokenCounter: 0

  function findToken(token) {
    for (var i = 0; i < tokens.length; ++i) {
      if (tokens[i].token === token) return tokens[i]
    }
    return null
  }

  function findHold(owner) {
    for (var i = 0; i < holds.length; ++i) {
      if (holds[i].owner === owner) return holds[i]
    }
    return null
  }

  function targetPriority(target) {
    var value = Number(target && target.priority)
    return isFinite(value) ? value : 0
  }

  function scheduleHoldTimer() {
    var now = Date.now()
    var next = 0
    for (var i = 0; i < holds.length; ++i) {
      var entry = holds[i]
      if (entry.tokens.length > 0 || entry.graceUntil <= now) continue
      if (!next || entry.graceUntil < next) next = entry.graceUntil
    }
    if (!next) {
      holdTimer.stop()
      return
    }
    holdTimer.interval = Math.max(1, Math.ceil(next - now))
    holdTimer.restart()
  }

  function addHold(owner, token) {
    var next = holds.slice()
    var existing = null
    for (var i = 0; i < next.length; ++i) {
      if (next[i].owner === owner) {
        existing = next[i]
        break
      }
    }
    if (existing) {
      existing.tokens = existing.tokens.concat([token])
      existing.graceUntil = 0
    } else {
      next.push({ owner: owner, tokens: [token], graceUntil: 0 })
    }
    holds = next
    holdRevision++
    scheduleHoldTimer()
  }

  // A genuine exit keeps the surface visible for the handoff grace. A
  // non-genuine release (delegate destruction, reassignment, disable) stops
  // holding immediately and must not arm the fired-target exit latch.
  function removeHold(owner, token, immediate) {
    var now = Date.now()
    var next = []
    var changed = false
    for (var i = 0; i < holds.length; ++i) {
      var entry = holds[i]
      if (entry.owner !== owner) {
        next.push(entry)
        continue
      }
      changed = true
      var remaining = entry.tokens.filter(function(value) { return value !== token })
      if (remaining.length > 0) {
        next.push({ owner: owner, tokens: remaining, graceUntil: 0 })
        continue
      }
      var graceUntil = immediate === true ? 0 : now + Math.max(0, Number(handoffMs) || 0)
      if (graceUntil > now) next.push({ owner: owner, tokens: [], graceUntil: graceUntil })
    }
    if (!changed) return
    holds = next
    holdRevision++
    scheduleHoldTimer()
  }

  function clearHold(owner) {
    var next = holds.filter(function(entry) { return entry.owner !== owner })
    if (next.length === holds.length) return
    holds = next
    holdRevision++
    scheduleHoldTimer()
  }

  function heldFor(owner) {
    // Reading the revision makes bindings that call heldFor() re-evaluate.
    if (holdRevision < 0) return false
    for (var i = 0; i < holds.length; ++i) {
      if (holds[i].owner === owner) return true
    }
    return false
  }

  function cancelPending() {
    dwellTimer.stop()
    pending = null
  }

  function enter(owner, target) {
    if (!enabled) return 0
    if (!owner || !target || typeof target.key !== "string" || !target.key) return 0

    var token = ++tokenCounter
    sessionActive = true
    tokens = tokens.concat([{ token: token, owner: owner, key: target.key }])
    addHold(owner, token)

    if (target.kind === "reveal") {
      // A reveal strip only holds the surface open; it never arms focus. A
      // passive reveal is an enclosing surface hold (whole dock, popup body),
      // so it must not cancel a more specific pending target it encloses.
      if (target.passive !== true && pending && pending.owner === owner) cancelPending()
      return token
    }

    if (pending && pending.owner === owner && pending.key === target.key) {
      // Motion inside one stable target keeps the original dwell.
      pending.tokens = pending.tokens.concat([token])
      return token
    }

    var priority = targetPriority(target)
    if (pending && pending.owner === owner && targetPriority(pending.target) > priority) {
      // Child targets win independent of event order: a row that enters after
      // its badge must not replace the more specific pending target.
      return token
    }

    cancelPending()
    if (firedKey === target.key) {
      // The same target already activated during this session. Re-entry keeps
      // the latch for the handoff window instead of re-arming focus.
      firedTimer.stop()
      return token
    }

    pending = {
      owner: owner,
      key: target.key,
      target: target,
      tokens: [token]
    }
    dwellTimer.interval = Math.max(1, Number(dwellMs) || 1)
    dwellTimer.restart()
    return token
  }

  function leave(token, genuineExit) {
    var entry = findToken(token)
    if (!entry) return false
    tokens = tokens.filter(function(value) { return value.token !== token })

    if (pending && pending.tokens.indexOf(token) >= 0) cancelPending()
    removeHold(entry.owner, token, genuineExit === false)

    if (genuineExit !== false && firedKey === entry.key) {
      firedTimer.interval = Math.max(1, Number(handoffMs) || 1)
      firedTimer.restart()
    }
    return true
  }

  function cancelOwner(owner) {
    var owned = tokens.filter(function(entry) { return entry.owner === owner })
    if (owned.length === 0) {
      clearHold(owner)
      return false
    }
    tokens = tokens.filter(function(entry) { return entry.owner !== owner })
    if (pending && pending.owner === owner) cancelPending()
    clearHold(owner)
    return true
  }

  function endSession() {
    cancelPending()
    firedTimer.stop()
    holdTimer.stop()
    firedKey = ""
    tokens = []
    holds = []
    sessionActive = false
    holdRevision++
  }

  function expireHolds() {
    var now = Date.now()
    var next = holds.filter(function(entry) {
      return entry.tokens.length > 0 || entry.graceUntil > now
    })
    if (next.length !== holds.length) {
      holds = next
      holdRevision++
    }
    scheduleHoldTimer()
  }

  function expireFired() {
    firedKey = ""
  }

  function activatePending() {
    if (!pending) return false
    var owner = pending.owner
    var target = pending.target
    var key = pending.key
    pending = null

    var activated = false
    if (target.kind === "window") {
      activated = !!(windowActions && target.toplevel
        && typeof windowActions.focusToplevelInPlace === "function"
        && windowActions.focusToplevelInPlace(target.toplevel))
    } else if (target.kind === "workspace") {
      activated = !!(windowActions && target.workspaceIdentity
        && typeof windowActions.focusWorkspaceInPlace === "function"
        && windowActions.focusWorkspaceInPlace(target.workspaceIdentity))
    } else if (target.kind === "browser-tab" || target.kind === "application") {
      activated = !!(sidebarController && target.sidebarTarget
        && typeof sidebarController.activateExternalDragTarget === "function"
        && sidebarController.activateExternalDragTarget(target.sidebarTarget))
    } else if (target.kind === "preview") {
      previewRequested(owner, key, target.anchor || null)
      activated = true
    }

    if (activated) {
      firedKey = key
      firedTimer.stop()
    }
    return activated
  }

  onEnabledChanged: {
    if (!enabled) endSession()
  }
  onDwellMsChanged: cancelPending()

  Timer {
    id: dwellTimer
    repeat: false
    onTriggered: root.activatePending()
  }

  Timer {
    id: firedTimer
    repeat: false
    onTriggered: root.expireFired()
  }

  Timer {
    id: holdTimer
    repeat: false
    onTriggered: root.expireHolds()
  }
}
