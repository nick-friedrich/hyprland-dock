import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "DockModel.js" as DockModel
import "DockWindowModel.js" as DockWindowModel

Item {
  id: root

  property var applicationMutationController: null
  readonly property string minimizedWorkspace: "special:smartdock-minimized"
  property var minimizedOrigins: ({})
  // Session-only movement policy. These maps deliberately live in the shared
  // host-owned controller rather than settings or compositor rules.
  property var windowWorkspacePins: ({})
  property var workspaceMonitorPins: ({})
  readonly property var minimizedOriginsSnapshot: DockWindowModel.copyOriginSnapshot(minimizedOrigins)
  readonly property var activeToplevel: ToplevelManager.activeToplevel

  function currentToplevels() {
    return ToplevelManager.toplevels
      ? ToplevelManager.toplevels.values || [] : []
  }

  function currentHandles() {
    return Hyprland.toplevels ? Hyprland.toplevels.values || [] : []
  }

  function currentWorkspaces() {
    return Hyprland.workspaces ? Hyprland.workspaces.values || [] : []
  }

  function currentMonitors() {
    return Hyprland.monitors ? Hyprland.monitors.values || [] : []
  }

  function clonePinMap(source) {
    var result = ({})
    var values = source || ({})
    Object.keys(values).forEach(function(key) { result[key] = values[key] })
    return result
  }

  function canonicalWorkspaceIdentity(value) {
    var identity = DockWindowModel.workspaceIdentity(value)
    if (!identity || identity.indexOf("special:") === 0) return ""
    var target = identity.indexOf("id:") === 0 ? identity.slice(3) : identity
    return DockModel.normalizeWorkspaceTarget(target) ? identity : ""
  }

  function workspaceCommandTarget(value) {
    var identity = canonicalWorkspaceIdentity(value)
    if (!identity) return ""
    return DockModel.normalizeWorkspaceTarget(
      identity.indexOf("id:") === 0 ? identity.slice(3) : identity)
  }

  function canonicalMonitorIdentity(value) {
    return DockWindowModel.canonicalMonitorIdentity(value, currentMonitors())
  }

  function monitorNameForIdentity(identity) {
    var monitors = currentMonitors()
    for (var i = 0; i < monitors.length; ++i) {
      var monitor = monitors[i]
      if (!monitor || DockWindowModel.canonicalMonitorIdentity(monitor, monitors) !== identity)
        continue
      var ipc = monitor.lastIpcObject || monitor
      return String(ipc.name !== undefined ? ipc.name : monitor.name || "").trim()
    }
    return ""
  }

  function handleFor(toplevel) {
    if (!isAlive(toplevel)) return null
    return DockWindowModel.handleForToplevel(toplevel, currentHandles())
  }

  function addressFor(toplevel) {
    var handle = handleFor(toplevel)
    return DockModel.normalizeWindowAddress(handle ? handle.address : "")
  }

  function isAlive(toplevel) {
    if (!toplevel) return false
    return currentToplevels().indexOf(toplevel) >= 0
  }

  function workspaceForHandle(handle) {
    if (!handle) return null
    var ipc = handle.lastIpcObject || ({})
    return ipc.workspace || handle.workspace || null
  }

  function workspaceTarget(workspace) {
    if (!workspace) return ""

    var ipc = workspace.lastIpcObject || workspace
    var id = Number(ipc.id !== undefined ? ipc.id : workspace.id)
    var target = ""
    if (Number.isInteger(id) && id > 0) {
      target = String(id)
    } else {
      var name = String(
        ipc.name !== undefined ? ipc.name : workspace.name || "").trim()
      if (!name || name.indexOf("special:") === 0) return ""
      // Numbered Quickshell placeholders (id -1) alias the real workspace.
      if (id === -1 && /^[1-9][0-9]*$/.test(name)) target = name
      else target = name.indexOf("name:") === 0 ? name : "name:" + name
    }
    return DockModel.normalizeWorkspaceTarget(target)
  }

  function monitorIdentity(handle) {
    if (!handle) return ""
    var ipc = handle.lastIpcObject || ({})
    if (ipc.monitor === undefined || ipc.monitor === null) return ""
    return String(ipc.monitor)
  }

  function originAddress(value) {
    if (typeof value === "string")
      return DockModel.normalizeWindowAddress(value)
    return addressFor(value)
  }

  function originFor(value) {
    var address = originAddress(value)
    if (!address || minimizedOrigins[address] === undefined) return null
    var origin = minimizedOrigins[address] || ({})
    return {
      workspace: String(origin.workspace || ""),
      monitor: String(origin.monitor || "")
    }
  }

  function setOrigin(address, origin) {
    var normalized = DockModel.normalizeWindowAddress(address)
    if (!normalized || !origin || !origin.workspace) return false

    var origins = DockWindowModel.copyOriginSnapshot(minimizedOrigins)
    origins[normalized] = {
      workspace: String(origin.workspace),
      monitor: String(origin.monitor || "")
    }
    minimizedOrigins = origins
    return true
  }

  function forgetOrigin(value) {
    var address = originAddress(value)
    if (!address || minimizedOrigins[address] === undefined) return false

    var origins = DockWindowModel.copyOriginSnapshot(minimizedOrigins)
    delete origins[address]
    minimizedOrigins = origins
    return true
  }

  function isMinimized(toplevel) {
    var handle = handleFor(toplevel)
    if (!handle) return false

    var workspace = workspaceForHandle(handle)
    var workspaceName = workspace ? String(workspace.name || "") : ""
    var ipc = handle.lastIpcObject || ({})
    if (ipc.workspace && ipc.workspace.name !== undefined)
      workspaceName = String(ipc.workspace.name || "")

    if (workspaceName === minimizedWorkspace) return true

    var address = DockModel.normalizeWindowAddress(handle.address || "")
    return address !== "" && minimizedOrigins[address] !== undefined
  }

  function windowState(toplevel) {
    var handle = handleFor(toplevel)
    if (!handle)
      return { minimized: false, workspace: "", monitor: "" }

    var minimized = isMinimized(toplevel)
    var origin = originFor(toplevel)
    var workspace = minimized && origin
      ? origin.workspace : workspaceTarget(workspaceForHandle(handle))
    var monitor = minimized && origin
      ? origin.monitor : monitorIdentity(handle)

    return {
      minimized: minimized,
      workspace: workspace,
      monitor: monitor
    }
  }

  function liveMembers(toplevels) {
    return DockWindowModel.liveGroupMembers(toplevels, currentToplevels())
  }

  function focusToplevels(toplevels, originOnly) {
    var members = liveMembers(toplevels)
    if (members.length === 0) return false
    var member = root.activeToplevel && members.indexOf(root.activeToplevel) >= 0
      ? root.activeToplevel : members[0]
    return activateToplevel(member, originOnly)
  }

  function dispatchRequest(request) {
    if (!request) return false
    Hyprland.dispatch(request)
    return true
  }

  function dispatchRequests(requests) {
    var values = requests || []
    if (values.length === 0) return false
    for (var i = 0; i < values.length; ++i) {
      if (typeof values[i] !== "string" || !values[i]) return false
    }
    if (values.length === 1) return dispatchRequest(values[0])

    if (Hyprland.usingLua) {
      var statements = values.map(function(request) {
        return "hl.dispatch(" + request + ")"
      })
      return dispatchRequest("function() " + statements.join("; ") + " end")
    }

    var batch = values.map(function(request) { return "dispatch " + request })
    Quickshell.execDetached(["hyprctl", "--batch", batch.join("; ")])
    return true
  }

  // Sidebar header navigation focuses the live owner; it never carries pull
  // intent. Keep classic header/wheel callers on workspaceOnMonitorRequests.
  function focusWorkspaceInPlace(workspace) {
    var destination = resolveWorkspaceDropTarget(canonicalWorkspaceIdentity(workspace))
    if (!destination) return false
    return dispatchRequest(DockModel.focusWorkspaceTargetRequest(
      destination.target, Hyprland.usingLua))
  }

  function workspaceOnMonitorRequests(workspace, monitor) {
    // A present relocation is authoritative even if a delayed event refresh is
    // still pending. Missing inventory remains non-destructive here.
    reconcileSessionPins({})
    var focusRequest = DockModel.focusWorkspaceTargetRequest(
      workspace, Hyprland.usingLua)
    if (!focusRequest) return []

    // A monitor-pinned workspace is focused where it already lives. Every dock
    // surface calls this shared path, so app, preview, cycling and header
    // activation cannot accidentally pull it onto the activating monitor.
    if (workspaceMonitorPin(workspace)) return [focusRequest]

    var current = resolveWorkspaceDropTarget(
      canonicalWorkspaceIdentity(workspace))
    if (current && current.monitor === canonicalMonitorIdentity(monitor))
      return [focusRequest]

    var moveRequest = DockModel.moveWorkspaceToMonitorRequest(
      workspace, monitor, Hyprland.usingLua)
    if (moveRequest) return [focusRequest, moveRequest, focusRequest]

    var moveCurrentRequest = DockModel.moveCurrentWorkspaceToMonitorRequest(
      monitor, Hyprland.usingLua)
    if (!moveCurrentRequest) return []
    return [focusRequest, moveCurrentRequest, focusRequest]
  }

  // Drag payloads own exact objects AND addresses, never an app-id lookup.
  function captureWorkspaceMove(toplevels) {
    var values = toplevels || []
    var captured = []
    var seen = []
    for (var i = 0; i < values.length; ++i) {
      var toplevel = values[i]
      if (!isAlive(toplevel)) return []
      if (seen.indexOf(toplevel) >= 0) continue
      seen.push(toplevel)
      captured.push({ toplevel: toplevel, address: addressFor(toplevel) })
    }
    var validated = workspaceMoveMembers(captured)
    return validated && validated.length === captured.length ? captured : []
  }

  function workspaceMoveLocation(toplevel, address) {
    var handle = handleFor(toplevel)
    if (!handle || !address || addressFor(toplevel) !== address) return null
    var ipc = handle.lastIpcObject || ({})
    if (ipc.pinned === true) return null
    var handles = currentHandles()
    for (var i = 0; i < handles.length; ++i) {
      var other = handles[i]
      if (other && other.wayland !== toplevel && isAlive(other.wayland)
          && DockModel.normalizeWindowAddress(other.address) === address)
        return null
    }
    // IPC wins over both stale object relationships and saved origins.
    var identity = DockWindowModel.workspaceIdentity(workspaceForHandle(handle))
    var minimized = identity === minimizedWorkspace
    var target = workspaceTarget(workspaceForHandle(handle))
    // A resolvable fallback source needs no guessed source workspace: only
    // its exact address and the independently validated destination are sent.
    var origin = minimized ? originFor(address) : null
    return {
      toplevel: toplevel, address: address, minimized: minimized,
      workspace: minimized ? origin ? origin.workspace : "" : target,
      monitor: minimized ? origin ? origin.monitor : "" : monitorIdentity(handle)
    }
  }

  // null means an unsafe surviving member; [] means all captured objects closed.
  function workspaceMoveMembers(members) {
    var values = members || []
    var result = []
    var seen = []
    for (var i = 0; i < values.length; ++i) {
      var member = values[i]
      if (!member || !member.address) return null
      if (!isAlive(member.toplevel)) continue
      if (seen.indexOf(member.toplevel) >= 0) continue
      var location = workspaceMoveLocation(member.toplevel, member.address)
      if (!location) return null
      seen.push(member.toplevel)
      result.push(location)
    }
    return result
  }

  function resolveWorkspaceDropTarget(identity) {
    if (typeof identity !== "string"
        || DockWindowModel.workspaceIdentity(identity) !== identity) return null
    var target = identity.indexOf("id:") === 0 ? identity.slice(3) : identity
    if (!DockModel.moveWindowRequest("1", target, false)) return null
    var workspaces = Hyprland.workspaces ? Hyprland.workspaces.values || [] : []
    var monitors = Hyprland.monitors ? Hyprland.monitors.values || [] : []
    var resolved = null
    for (var i = 0; i < workspaces.length; ++i) {
      var descriptor = workspaces[i]
      if (!descriptor || DockWindowModel.workspaceIdentity(descriptor) !== identity) continue
      var ipc = descriptor.lastIpcObject || descriptor
      // Unhydrated Quickshell placeholders carry no authoritative owner.
      if (descriptor.id === -1 && descriptor.lastIpcObject && Object.keys(ipc).length === 0) continue
      if (identity.indexOf("name:") === 0) {
        var name = String(ipc.name !== undefined ? ipc.name : descriptor.name || "")
        if ((name.indexOf("name:") === 0 ? name : "name:" + name) !== target) return null
      }
      var owner = DockWindowModel.canonicalMonitorIdentity(
        ipc.monitorID !== undefined ? ipc.monitorID
          : ipc.monitor !== undefined ? ipc.monitor : descriptor.monitor, monitors)
      if (!owner || resolved && resolved.monitor !== owner) return null
      resolved = { identity: identity, target: target, monitor: owner }
    }
    return resolved
  }

  function workspaceMoveChangesLocation(member, destination) {
    if (DockModel.normalizeWorkspaceTarget(member.workspace) !== destination.target) return true
    if (!member.minimized) return false
    var monitors = Hyprland.monitors ? Hyprland.monitors.values || [] : []
    return DockWindowModel.canonicalMonitorIdentity(member.monitor, monitors) !== destination.monitor
  }

  function workspaceMoveWouldChange(members, identity) {
    var destination = resolveWorkspaceDropTarget(identity)
    var live = workspaceMoveMembers(members)
    if (!destination || !live) return false
    for (var i = 0; i < live.length; ++i) {
      if (!canMoveToplevelToWorkspace(live[i].toplevel, destination.identity))
        return false
    }
    for (var changedIndex = 0; changedIndex < live.length; ++changedIndex) {
      if (workspaceMoveChangesLocation(live[changedIndex], destination)) return true
    }
    return false
  }

  function moveCapturedToplevels(members, workspaceIdentity, follow) {
    var followMode = follow === true
    var destination = resolveWorkspaceDropTarget(workspaceIdentity)
    var live = workspaceMoveMembers(members)
    if (!destination || !live || live.length === 0) return false

    // First pass: one blocked member rejects the entire represented payload.
    var planned = []
    for (var i = 0; i < live.length; ++i) {
      if (!canMoveToplevelToWorkspace(live[i].toplevel, destination.identity))
        return false
      if (workspaceMoveChangesLocation(live[i], destination)) planned.push(live[i])
    }
    if (planned.length === 0) return false

    // Second pass immediately before the first side effect. This catches a pin,
    // replacement or workspace change that appeared after drag hover/capture.
    destination = resolveWorkspaceDropTarget(workspaceIdentity)
    if (!destination) return false
    var confirmed = []
    for (var checkIndex = 0; checkIndex < planned.length; ++checkIndex) {
      var member = workspaceMoveLocation(
        planned[checkIndex].toplevel, planned[checkIndex].address)
      if (!member
          || !canMoveToplevelToWorkspace(member.toplevel, destination.identity))
        return false
      if (workspaceMoveChangesLocation(member, destination)) confirmed.push(member)
    }
    if (confirmed.length === 0) return false

    if (!followMode) {
      var changed = false
      for (var dispatchIndex = 0; dispatchIndex < confirmed.length; ++dispatchIndex) {
        var current = confirmed[dispatchIndex]
        if (current.minimized) {
          changed = setOrigin(current.address, {
            workspace: destination.target, monitor: destination.monitor
          }) || changed
        } else {
          var request = DockModel.moveWindowRequest(
            current.address, destination.target, Hyprland.usingLua)
          if (dispatchRequest(request)) {
            forgetOrigin(current.address)
            changed = true
          }
        }
      }
      return changed
    }

    var requests = []
    var moved = []
    for (var moveIndex = 0; moveIndex < confirmed.length; ++moveIndex) {
      var followCurrent = confirmed[moveIndex]
      var moveRequest = followCurrent.minimized
        ? DockModel.restoreWindowRequest(
          followCurrent.address, destination.target, Hyprland.usingLua)
        : DockModel.moveWindowRequest(
          followCurrent.address, destination.target, Hyprland.usingLua)
      if (!moveRequest) return false
      requests.push(moveRequest)
      moved.push(followCurrent)
    }
    if (moved.length === 0) return false
    var focusMember = moved[0]
    for (var focusIndex = 0; focusIndex < moved.length; ++focusIndex) {
      if (moved[focusIndex].toplevel === root.activeToplevel) {
        focusMember = moved[focusIndex]
        break
      }
    }
    var focusWorkspaceRequest = DockModel.focusWorkspaceTargetRequest(
      destination.target, Hyprland.usingLua)
    var focusWindowRequest = DockModel.focusWindowRequest(
      focusMember.address, Hyprland.usingLua)
    if (!focusWorkspaceRequest || !focusWindowRequest) return false
    requests.push(focusWorkspaceRequest)
    requests.push(focusWindowRequest)
    if (!dispatchRequests(requests)) return false
    for (var forgetIndex = 0; forgetIndex < moved.length; ++forgetIndex)
      forgetOrigin(moved[forgetIndex].address)
    return true
  }

  function numericWorkspaceIdFromValue(value) {
    var raw = String(value === undefined || value === null ? "" : value).trim()
    if (/^[1-9][0-9]*$/.test(raw)) return Number(raw)
    if (/^id:[1-9][0-9]*$/.test(raw)) return Number(raw.slice(3))
    var identity = DockWindowModel.workspaceIdentity(value)
    if (/^id:[1-9][0-9]*$/.test(identity)) return Number(identity.slice(3))
    return 0
  }

  function occupiedNumericWorkspaceIds() {
    var occupied = ({})
    var workspaces = currentWorkspaces()
    for (var i = 0; i < workspaces.length; ++i) {
      var descriptor = workspaces[i]
      if (!descriptor) continue
      var ipc = descriptor.lastIpcObject || descriptor
      var id = Number(ipc.id !== undefined ? ipc.id : descriptor.id)
      if (Number.isInteger(id) && id > 0) occupied[id] = true
    }
    var origins = minimizedOrigins || ({})
    Object.keys(origins).forEach(function(address) {
      var origin = origins[address] || ({})
      var retained = numericWorkspaceIdFromValue(origin.workspace)
      if (retained > 0) occupied[retained] = true
    })
    var windowPins = windowWorkspacePins || ({})
    Object.keys(windowPins).forEach(function(address) {
      var pin = windowPins[address]
      var pinned = pin ? numericWorkspaceIdFromValue(pin.workspace) : 0
      if (pinned > 0) occupied[pinned] = true
    })
    var monitorPins = workspaceMonitorPins || ({})
    Object.keys(monitorPins).forEach(function(identity) {
      var keyed = numericWorkspaceIdFromValue(identity)
      if (keyed > 0) occupied[keyed] = true
      var entry = monitorPins[identity]
      if (entry) {
        var entryId = numericWorkspaceIdFromValue(entry.workspace)
        if (entryId > 0) occupied[entryId] = true
      }
    })
    return occupied
  }

  function allocateNewWorkspaceId() {
    var occupied = occupiedNumericWorkspaceIds()
    var candidate = 1
    while (occupied[candidate] === true) {
      candidate += 1
      if (candidate > 1000000) return 0
    }
    return candidate
  }

  function newWorkspaceMovePlan(members, monitorIdentity) {
    var requested = canonicalMonitorIdentity(monitorIdentity)
    if (!requested) return null
    var live = workspaceMoveMembers(members)
    if (!live || live.length === 0) return null
    var newId = allocateNewWorkspaceId()
    if (!(newId > 0)) return null
    var newTarget = String(newId)
    var newIdentity = "id:" + newTarget
    for (var i = 0; i < live.length; ++i) {
      if (!canMoveToplevelToWorkspace(live[i].toplevel, newIdentity))
        return null
    }
    return {
      monitor: requested,
      id: newId,
      target: newTarget,
      identity: newIdentity,
      members: live
    }
  }

  function canMoveCapturedToplevelsToNewWorkspace(members, monitorIdentity) {
    return newWorkspaceMovePlan(members, monitorIdentity) !== null
  }

  function moveCapturedToplevelsToNewWorkspaceResult(members, monitorIdentity) {
    var plan = newWorkspaceMovePlan(members, monitorIdentity)
    if (!plan) return {accepted:false}

    // Revalidate the target monitor, free workspace id and every surviving
    // captured member immediately before the first compositor side effect.
    var reMonitor = canonicalMonitorIdentity(monitorIdentity)
    if (!reMonitor || reMonitor !== plan.monitor) return {accepted:false}
    if (occupiedNumericWorkspaceIds()[plan.id] === true) return {accepted:false}
    var confirmed = workspaceMoveMembers(members)
    if (!confirmed || confirmed.length === 0) return {accepted:false}
    for (var checkIndex = 0; checkIndex < confirmed.length; ++checkIndex) {
      if (!canMoveToplevelToWorkspace(confirmed[checkIndex].toplevel, plan.identity))
        return {accepted:false}
    }

    var requests = []
    for (var moveIndex = 0; moveIndex < confirmed.length; ++moveIndex) {
      var current = confirmed[moveIndex]
      var moveRequest = current.minimized
        ? DockModel.restoreWindowRequest(
          current.address, plan.target, Hyprland.usingLua)
        : DockModel.moveWindowRequest(
          current.address, plan.target, Hyprland.usingLua)
      if (!moveRequest) return {accepted:false}
      requests.push(moveRequest)
    }

    var relocateRequest = DockModel.moveWorkspaceToMonitorRequest(
      plan.target, reMonitor, Hyprland.usingLua)
    var activateRequest = DockModel.focusWorkspaceTargetRequest(
      plan.target, Hyprland.usingLua)
    var focusMember = confirmed[0]
    for (var focusIndex = 0; focusIndex < confirmed.length; ++focusIndex) {
      if (confirmed[focusIndex].toplevel === root.activeToplevel) {
        focusMember = confirmed[focusIndex]
        break
      }
    }
    var focusRequest = DockModel.focusWindowRequest(
      focusMember.address, Hyprland.usingLua)
    if (!relocateRequest || !activateRequest || !focusRequest) return {accepted:false}
    requests.push(relocateRequest)
    requests.push(activateRequest)
    requests.push(focusRequest)
    if (!dispatchRequests(requests)) return {accepted:false}
    for (var forgetIndex = 0; forgetIndex < confirmed.length; ++forgetIndex)
      forgetOrigin(confirmed[forgetIndex].address)
    return {accepted:true, expectedWorkspace:plan.identity, expectedMonitor:reMonitor,
      members:confirmed.map(function(member) {
        return {toplevel:member.toplevel, address:member.address}
      })}
  }

  // Legacy callers retain strict boolean contracts and exactly one submission.
  function moveCapturedToplevelsToNewWorkspace(members, monitorIdentity) {
    return moveCapturedToplevelsToNewWorkspaceResult(members, monitorIdentity).accepted === true
  }

  function moveCapturedWindowToNewWorkspaceResult(member, monitorIdentity) {
    return moveCapturedToplevelsToNewWorkspaceResult([member], monitorIdentity)
  }

  function moveCapturedWindowToNewWorkspace(member, monitorIdentity) {
    return moveCapturedWindowToNewWorkspaceResult(member, monitorIdentity).accepted === true
  }

  function reliableWorkspaceForToplevel(toplevel) {
    if (!isAlive(toplevel)) return ""
    var state = windowState(toplevel)
    return canonicalWorkspaceIdentity(state ? state.workspace : "")
  }

  function windowWorkspacePin(toplevel) {
    if (!toplevel) return null
    var address = addressFor(toplevel)
    if (!address) return null
    var pin = windowWorkspacePins[address]
    if (!pin || pin.toplevel !== toplevel || pin.address !== address) return null
    var current = reliableWorkspaceForToplevel(toplevel)
    if (current && current !== pin.workspace) return null
    return pin
  }

  function pinWindowToWorkspace(toplevel) {
    var address = addressFor(toplevel)
    var workspace = reliableWorkspaceForToplevel(toplevel)
    if (!address || !workspace) return false
    var pins = clonePinMap(windowWorkspacePins)
    pins[address] = {
      toplevel: toplevel,
      address: address,
      workspace: workspace
    }
    windowWorkspacePins = pins
    return true
  }

  function unpinWindowFromWorkspace(toplevel) {
    var address = addressFor(toplevel)
    var pin = address ? windowWorkspacePins[address] : null
    if (!pin || pin.toplevel !== toplevel) return false
    var pins = clonePinMap(windowWorkspacePins)
    delete pins[address]
    windowWorkspacePins = pins
    return true
  }

  function canMoveToplevelToWorkspace(toplevel, workspace) {
    var destination = canonicalWorkspaceIdentity(workspace)
    if (!destination || !isAlive(toplevel)) return false
    var pin = windowWorkspacePin(toplevel)
    return !pin || pin.workspace === destination
  }

  function moveToplevelToWorkspace(toplevel, capturedAddress, workspace) {
    var address = DockModel.normalizeWindowAddress(capturedAddress)
    var destinationIdentity = canonicalWorkspaceIdentity(workspace)
    var target = workspaceCommandTarget(workspace)
    if (!address || !destinationIdentity || !target
        || !canMoveToplevelToWorkspace(toplevel, destinationIdentity)) return false
    var member = workspaceMoveLocation(toplevel, address)
    if (!member) return false
    if (DockModel.normalizeWorkspaceTarget(member.workspace) === target)
      return false
    if (member.minimized) {
      // Keep minimized storage untouched, but record the destination owner
      // exactly as a workspace-card drag does. Unknown ownership is not a move.
      var destination = resolveWorkspaceDropTarget(destinationIdentity)
      if (!destination) return false
      return setOrigin(address, {
        workspace: destination.target,
        monitor: destination.monitor
      })
    }
    var request = DockModel.moveWindowRequest(address, target, Hyprland.usingLua)
    if (!dispatchRequest(request)) return false
    forgetOrigin(address)
    return true
  }

  function monitorActiveWorkspaceIdentity(monitor) {
    var requested = canonicalMonitorIdentity(monitor)
    if (!requested) return ""
    var monitors = currentMonitors()
    var workspace = ""
    for (var monitorIndex = 0; monitorIndex < monitors.length; ++monitorIndex) {
      if (canonicalMonitorIdentity(monitors[monitorIndex]) !== requested) continue
      workspace = DockWindowModel.workspaceIdentity(
        DockWindowModel.monitorActiveWorkspace(monitors[monitorIndex]))
      break
    }
    return canonicalWorkspaceIdentity(workspace)
  }

  function pullToplevelToMonitorWorkspace(toplevel, originOnly, monitor) {
    var requested = canonicalMonitorIdentity(monitor)
    var workspace = monitorActiveWorkspaceIdentity(monitor)
    if (!workspace) return false
    if (reliableWorkspaceForToplevel(toplevel) === workspace)
      return activateToplevel(toplevel, originOnly, "", true)
    var address = addressFor(toplevel)
    var minimized = isMinimized(toplevel)
    var focusRequest = minimized ? ""
      : DockModel.focusWindowRequest(address, Hyprland.usingLua)
    if (!minimized && !focusRequest) return false
    if (!moveToplevelToWorkspace(toplevel, address, workspace)) return false
    if (minimized)
      return activateToplevel(toplevel, originOnly, requested, true)
    return dispatchRequest(focusRequest)
  }

  function workspaceMonitorPin(workspace) {
    var identity = canonicalWorkspaceIdentity(workspace)
    if (!identity) return null
    var pin = workspaceMonitorPins[identity]
    if (!pin || pin.workspace !== identity) return null
    var resolved = resolveWorkspaceDropTarget(identity)
    if (resolved && resolved.monitor !== pin.monitor) return null
    return pin
  }

  function pinWorkspaceToMonitor(workspace) {
    var identity = canonicalWorkspaceIdentity(workspace)
    var resolved = identity ? resolveWorkspaceDropTarget(identity) : null
    if (!resolved || !resolved.monitor) return false
    var pins = clonePinMap(workspaceMonitorPins)
    pins[identity] = {
      workspace: identity,
      monitor: resolved.monitor,
      monitorName: monitorNameForIdentity(resolved.monitor)
    }
    workspaceMonitorPins = pins
    return true
  }

  function unpinWorkspaceFromMonitor(workspace) {
    var identity = canonicalWorkspaceIdentity(workspace)
    if (!identity || workspaceMonitorPins[identity] === undefined) return false
    var pins = clonePinMap(workspaceMonitorPins)
    delete pins[identity]
    workspaceMonitorPins = pins
    return true
  }

  function canRelocateWorkspaceToMonitor(workspace, monitor) {
    var identity = canonicalWorkspaceIdentity(workspace)
    var requested = canonicalMonitorIdentity(monitor)
    if (!identity || !requested) return false
    var pin = workspaceMonitorPin(identity)
    return !pin || pin.monitor === requested
  }

  function workspaceMonitorMoveRequest(workspace, monitor) {
    var identity = canonicalWorkspaceIdentity(workspace)
    var requested = canonicalMonitorIdentity(monitor)
    var resolved = identity ? resolveWorkspaceDropTarget(identity) : null
    if (!resolved || !requested || resolved.monitor === requested
        || !canRelocateWorkspaceToMonitor(identity, requested)) return ""
    return DockModel.moveWorkspaceToMonitorRequest(
      workspaceCommandTarget(identity), requested, Hyprland.usingLua)
  }

  function canMoveWorkspaceToMonitor(workspace, monitor) {
    return workspaceMonitorMoveRequest(workspace, monitor) !== ""
  }

  function moveWorkspaceToMonitor(workspace, monitor) {
    return dispatchRequest(workspaceMonitorMoveRequest(workspace, monitor))
  }

  function resolveOriginTarget(recorded, originOnly) {
    var target = DockModel.normalizeWorkspaceTarget(recorded)
    if (recorded || originOnly === true) return target
    return workspaceTarget(Hyprland.focusedWorkspace)
  }

  function minimizeToplevel(toplevel, originOnly) {
    if (!isAlive(toplevel) || isMinimized(toplevel)) return false

    var handle = handleFor(toplevel)
    var address = DockModel.normalizeWindowAddress(handle ? handle.address : "")
    if (!address) return false

    var workspace = resolveOriginTarget(
      workspaceTarget(workspaceForHandle(handle)), originOnly)
    if (!workspace) return false

    var request = DockModel.minimizeWindowRequest(address, Hyprland.usingLua)
    if (!request) return false

    setOrigin(address, {
      workspace: workspace,
      monitor: monitorIdentity(handle)
    })
    return dispatchRequest(request)
  }

  function restoreToplevel(toplevel, originOnly) {
    if (!isAlive(toplevel)) return false

    var address = addressFor(toplevel)
    if (!address) return false

    var origin = originFor(address)
    var target = resolveOriginTarget(origin ? origin.workspace : "", originOnly)
    if (!target) return false

    var request = DockModel.restoreWindowRequest(
      address, target, Hyprland.usingLua)
    if (!request) return false

    if (!dispatchRequest(request)) return false
    forgetOrigin(address)
    return true
  }

  function activateToplevel(toplevel, originOnly, activationMonitor,
                            focusAfterRestore, workspaceTargetOverride) {
    if (!isAlive(toplevel)) return false

    if (isMinimized(toplevel)) {
      var address = addressFor(toplevel)
      if (!address) return false

      var activation = DockModel.normalizeMonitorTarget(activationMonitor)
      if (activation) {
        var origin = originFor(address)
        var restoreWorkspace = resolveOriginTarget(
          origin ? origin.workspace : "", originOnly)
        if (!restoreWorkspace) return false
        var restoreRequest = DockModel.restoreWindowRequest(
          address, restoreWorkspace, Hyprland.usingLua)
        var restoreRequests = workspaceOnMonitorRequests(
          restoreWorkspace, activation)
        if (restoreRequests.length === 0) return false
        restoreRequests.push(restoreRequest)
        if (focusAfterRestore === true)
          restoreRequests.push(DockModel.focusWindowRequest(
            address, Hyprland.usingLua))
        if (!dispatchRequests(restoreRequests)) return false
        forgetOrigin(address)
        return true
      }

      return restoreToplevel(toplevel, originOnly)
    }

    var handle = handleFor(toplevel)
    var workspace = workspaceTargetOverride || workspaceTarget(workspaceForHandle(handle))
    var monitor = DockModel.normalizeMonitorTarget(activationMonitor)
    var request = DockModel.focusWindowRequest(
      addressFor(toplevel), Hyprland.usingLua)
    if (monitor && workspace && request) {
      var requests = workspaceOnMonitorRequests(workspace, monitor)
      if (requests.length === 0) return false
      requests.push(request)
      return dispatchRequests(requests)
    }

    if (dispatchRequest(request)) return true

    if (typeof toplevel.activate === "function") {
      toplevel.activate()
      return true
    }
    return false
  }

  // Narrow external-navigation entry point: focus the exact live window in
  // place. A Dockrail-minimized window is restored to its recorded origin and
  // then focused explicitly; the empty-monitor activateToplevel restore branch
  // returns after restoring even when focusAfterRestore is true.
  function focusToplevelInPlace(toplevel) {
    if (!isAlive(toplevel)) return false
    var address = addressFor(toplevel)
    if (!address) return false

    if (isMinimized(toplevel)) {
      if (!restoreToplevel(toplevel, false)) return false
      var focusRequest = DockModel.focusWindowRequest(address, Hyprland.usingLua)
      if (dispatchRequest(focusRequest)) return true
      if (typeof toplevel.activate === "function") {
        toplevel.activate()
        return true
      }
      return false
    }

    return activateToplevel(toplevel, false)
  }

  function cycleToplevels(toplevels, direction, activeToplevel, originOnly,
                          activationMonitor) {
    var members = liveMembers(toplevels)
    if (members.length < 2) return false

    var active = activeToplevel === undefined
      ? root.activeToplevel : activeToplevel
    var target = DockWindowModel.cycleGroupMember(
      members, active, currentToplevels(), direction)
    if (!target) return false

    var address = addressFor(target)
    if (!address) return false

    if (isMinimized(target)) {
      var activation = DockModel.normalizeMonitorTarget(activationMonitor)
      if (activation)
        return activateToplevel(
          target, originOnly, activationMonitor, true)
      if (!activateToplevel(target, originOnly, activationMonitor)) return false
      var focusRequest = DockModel.focusWindowRequest(address, Hyprland.usingLua)
      if (dispatchRequest(focusRequest)) return true
      if (typeof target.activate === "function") {
        target.activate()
        return true
      }
      return true
    }

    return activateToplevel(target, originOnly, activationMonitor)
  }

  function minimizeRestoreToplevels(toplevels, originOnly) {
    var members = liveMembers(toplevels)
    if (members.length === 0) return false

    var states = []
    for (var stateIndex = 0; stateIndex < members.length; ++stateIndex)
      states.push(windowState(members[stateIndex]))

    var mode = DockModel.minimizeRestoreMode(states)
    var changed = false
    for (var i = 0; i < members.length; ++i) {
      if (mode === "minimize" && !states[i].minimized)
        changed = minimizeToplevel(members[i], originOnly) || changed
      else if (mode === "restore" && states[i].minimized)
        changed = restoreToplevel(members[i], originOnly) || changed
    }
    return changed
  }

  function closeToplevels(toplevels) {
    var members = liveMembers(toplevels)
    var requested = false
    for (var i = 0; i < members.length; ++i)
      requested = closeToplevel(members[i]) || requested
    return requested
  }

  function closeToplevel(toplevel) {
    if (!isAlive(toplevel) || typeof toplevel.close !== "function")
      return false
    toplevel.close()
    return true
  }

  function reconcileSessionPins(options) {
    var opts = options || ({})
    var live = currentToplevels()
    var nextWindowPins = clonePinMap(windowWorkspacePins)
    var windowChanged = false
    Object.keys(nextWindowPins).forEach(function(address) {
      var pin = nextWindowPins[address]
      if (!pin || !pin.toplevel) {
        delete nextWindowPins[address]
        windowChanged = true
        return
      }
      var alive = live.indexOf(pin.toplevel) >= 0
      if (!alive) {
        if (opts.completeToplevels === true) {
          delete nextWindowPins[address]
          windowChanged = true
        }
        return
      }
      var currentAddress = addressFor(pin.toplevel)
      if (currentAddress && currentAddress !== address) {
        delete nextWindowPins[address]
        windowChanged = true
        return
      }
      if (!currentAddress) {
        if (opts.completeToplevels === true) {
          delete nextWindowPins[address]
          windowChanged = true
        }
        return
      }
      var workspace = reliableWorkspaceForToplevel(pin.toplevel)
      if (workspace && workspace !== pin.workspace) {
        delete nextWindowPins[address]
        windowChanged = true
      }
    })
    if (windowChanged) windowWorkspacePins = nextWindowPins

    var nextWorkspacePins = clonePinMap(workspaceMonitorPins)
    var workspaceChanged = false
    Object.keys(nextWorkspacePins).forEach(function(identity) {
      var pin = nextWorkspacePins[identity]
      if (!pin) {
        delete nextWorkspacePins[identity]
        workspaceChanged = true
        return
      }
      if (opts.completeMonitors === true
          && !DockWindowModel.canonicalMonitorIdentity(pin.monitor, currentMonitors())) {
        delete nextWorkspacePins[identity]
        workspaceChanged = true
        return
      }
      var resolved = resolveWorkspaceDropTarget(identity)
      if (resolved) {
        if (resolved.monitor !== pin.monitor) {
          delete nextWorkspacePins[identity]
          workspaceChanged = true
        }
      } else if (opts.completeWorkspaces === true) {
        delete nextWorkspacePins[identity]
        workspaceChanged = true
      }
    })
    if (workspaceChanged) workspaceMonitorPins = nextWorkspacePins
    return windowChanged || workspaceChanged
  }

  function eventFields(event) {
    var data = event && event.data !== undefined ? String(event.data || "") : ""
    return data.split(",").map(function(value) { return String(value).trim() })
  }

  function confirmWindowClosed(event) {
    var fields = eventFields(event)
    var address = DockModel.normalizeWindowAddress(fields.length > 0 ? fields[0] : "")
    if (!address || windowWorkspacePins[address] === undefined) return false
    var pins = clonePinMap(windowWorkspacePins)
    delete pins[address]
    windowWorkspacePins = pins
    return true
  }

  function confirmMonitorRemoved(event) {
    var fields = eventFields(event)
    if (fields.length === 0) return false
    var pins = clonePinMap(workspaceMonitorPins)
    var changed = false
    Object.keys(pins).forEach(function(identity) {
      var pin = pins[identity]
      if (pin && pin.monitorName && fields.indexOf(pin.monitorName) >= 0) {
        delete pins[identity]
        changed = true
      }
    })
    if (changed) workspaceMonitorPins = pins
    return changed
  }

  function pruneOrigins() {
    var retained = DockWindowModel.pruneOriginSnapshot(
      minimizedOrigins, currentHandles(), currentToplevels())
    if (JSON.stringify(retained) !== JSON.stringify(minimizedOrigins))
      minimizedOrigins = DockWindowModel.copyOriginSnapshot(retained)
  }

  Timer {
    id: pruneTimer
    interval: 120
    repeat: false
    onTriggered: root.pruneOrigins()
  }

  Timer {
    id: pinReconcileTimer
    interval: 120
    repeat: false
    onTriggered: root.reconcileSessionPins({})
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      pruneTimer.restart()
      pinReconcileTimer.restart()
    }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() {
      pruneTimer.restart()
      pinReconcileTimer.restart()
    }
  }

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { pinReconcileTimer.restart() }
  }

  Connections {
    target: Hyprland.monitors
    function onValuesChanged() { pinReconcileTimer.restart() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name || "")
      if (name === "closewindow") root.confirmWindowClosed(event)
      if (name === "monitorremoved" || name === "monitorremovedv2") {
        root.confirmMonitorRemoved(event)
        if (typeof Hyprland.refreshMonitors === "function") Hyprland.refreshMonitors()
      }
      if (name === "moveworkspace" || name === "moveworkspacev2") {
        if (typeof Hyprland.refreshWorkspaces === "function") Hyprland.refreshWorkspaces()
      }
      if (["movewindow", "movewindowv2", "moveworkspace", "moveworkspacev2",
           "monitorremoved", "monitorremovedv2"].indexOf(name) >= 0)
        pinReconcileTimer.restart()
    }
  }
}
