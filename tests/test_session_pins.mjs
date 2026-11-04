import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

const read = name => fs.readFileSync(new URL(`../components/${name}`, import.meta.url), 'utf8')
function model(name, imports = {}) {
  const scope = vm.createContext(imports)
  vm.runInContext(read(name).replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}
function methods(file, properties) {
  const scope = vm.createContext(properties)
  scope.root = scope
  vm.runInContext((read(file).match(/^  function [\s\S]*?^  }/gm) || []).join('\n'), scope,
    { filename: file })
  return scope
}

const DockModel = model('DockModel.js')
const DockWindowModel = model('DockWindowModel.js', { DockModel })

function fixture(usingLua = false) {
  const A = { appId: 'editor', title: 'A' }
  const B = { appId: 'editor', title: 'B' }
  const C = { appId: 'browser', title: 'C' }
  const windows = [A, B, C]
  const handles = [
    { wayland: A, address: 'a1', lastIpcObject: { workspace: { id: 3 }, monitor: 0, pinned: false } },
    { wayland: B, address: 'b2', lastIpcObject: { workspace: { id: 3 }, monitor: 0, pinned: false } },
    { wayland: C, address: 'c3', lastIpcObject: { workspace: { id: 4 }, monitor: 1, pinned: false } }
  ]
  const workspaces = [
    { id: 3, name: '3', monitorID: 0 },
    { id: 4, name: '4', monitorID: 1 },
    { id: -2, name: 'project space', monitorID: 0 }
  ]
  const monitors = [
    { id: 0, name: 'DP-1', activeWorkspace: { id: 3 } },
    { id: 1, name: 'DP-2', activeWorkspace: { id: 4 } }
  ]
  const requests = []
  const detached = []
  const actions = methods('DockWindowActions.qml', {
    DockModel, DockWindowModel,
    minimizedWorkspace: 'special:smartdock-minimized', minimizedOrigins: {},
    windowWorkspacePins: {}, workspaceMonitorPins: {},
    ToplevelManager: { toplevels: { values: windows }, activeToplevel: null },
    Hyprland: {
      toplevels: { values: handles }, workspaces: { values: workspaces },
      monitors: { values: monitors }, usingLua,
      focusedWorkspace: workspaces[0], dispatch: request => requests.push(request)
    },
    Quickshell: { execDetached: args => detached.push(args) }
  })
  return { actions, A, B, C, windows, handles, workspaces, monitors, requests, detached }
}

{
  const { actions: a } = fixture()
  for (const name of [
    'pinWindowToWorkspace', 'unpinWindowFromWorkspace', 'windowWorkspacePin',
    'canMoveToplevelToWorkspace', 'moveToplevelToWorkspace',
    'pinWorkspaceToMonitor', 'unpinWorkspaceFromMonitor', 'workspaceMonitorPin',
    'canRelocateWorkspaceToMonitor', 'canMoveWorkspaceToMonitor',
    'reconcileSessionPins'
  ]) assert.equal(typeof a[name], 'function', `CM-04 requires central ${name}()`)
}

// Hover eligibility includes compositor command compatibility, not pins alone.
{
  const f = fixture(false)
  const native = f.actions
  assert.equal(native.canMoveWorkspaceToMonitor('id:3', 'id:1'), true)
  assert.equal(native.canMoveWorkspaceToMonitor('id:3', 'id:0'), false,
    'the live workspace owner is a no-op destination')
  assert.equal(native.canMoveWorkspaceToMonitor('name:project space', 'id:1'), false)
  assert.equal(fixture(true).actions.canMoveWorkspaceToMonitor(
    'name:project space', 'id:1'), true)
  f.workspaces.splice(0, 1)
  assert.equal(native.canMoveWorkspaceToMonitor('id:3', 'id:1'), false,
    'a vanished workspace is never an eligible drop payload')
}

// One pinned member blocks the whole represented move before any side effect.
{
  const f = fixture()
  const { actions: a, A, B, requests } = f
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.windowWorkspacePin(A).workspace, 'id:3')
  const captured = a.captureWorkspaceMove([A, B])
  assert.equal(captured.length, 2)
  assert.equal(a.workspaceMoveWouldChange(captured, 'id:4'), false,
    'drag hover must reject a mixed group containing a pinned member')
  assert.equal(a.moveCapturedToplevels(captured, 'id:4'), false,
    'drop preflight must reject the whole mixed group')
  assert.equal(requests.length, 0, 'blocked group move dispatches nothing')

  assert.equal(a.moveToplevelToWorkspace(A, a.addressFor(A), 4), false,
    'menu move must use the same central pin guard')
  assert.equal(requests.length, 0)
  assert.equal(a.canMoveToplevelToWorkspace(A, 3), true,
    'same-workspace interaction is not a relocation ban')

  assert.equal(a.unpinWindowFromWorkspace(A), true)
  assert.equal(a.workspaceMoveWouldChange(captured, 'id:4'), true)
  assert.equal(a.moveCapturedToplevels(captured, 'id:4'), true)
  assert.equal(requests.length, 2)
}

// A pin added after drag capture/hover is authoritative at drop time.
{
  const f = fixture()
  const { actions: a, A, B, requests } = f
  const captured = a.captureWorkspaceMove([A, B])
  assert.equal(a.workspaceMoveWouldChange(captured, 'id:4'), true)
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.workspaceMoveWouldChange(captured, 'id:4'), false)
  assert.equal(a.moveCapturedToplevels(captured, 'id:4'), false)
  assert.equal(requests.length, 0)
}

// Minimize/restore keeps the original workspace pin and recorded origin.
{
  const f = fixture()
  const { actions: a, A, handles, requests } = f
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.minimizeToplevel(A, true), true)
  handles[0].lastIpcObject.workspace = { name: 'special:smartdock-minimized' }
  a.reconcileSessionPins({})
  assert.equal(a.windowWorkspacePin(A).workspace, 'id:3',
    'minimized storage must not clear or retarget the pin')
  assert.equal(a.restoreToplevel(A, true), true)
  assert.equal(a.windowWorkspacePin(A).workspace, 'id:3')
  assert.equal(requests.length, 2)
}

// External drag hover focuses in place under window and workspace pins.
{
  const f = fixture(false)
  const { actions: a, A, requests } = f
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  assert.equal(a.pinWindowToWorkspace(A), true)
  requests.length = 0
  assert.equal(a.focusToplevelInPlace(A), true)
  assert.deepEqual(requests, [DockModel.focusWindowRequest(a.addressFor(A), false)])
  assert.equal(a.windowWorkspacePin(A).workspace, 'id:3',
    'hover keeps the window pin')
  assert.equal(a.workspaceMonitorPin('id:3').monitor, 'id:0',
    'hover keeps the workspace pin')
  assert.doesNotMatch(requests.join(' '), /moveworkspace|movecurrentworkspace/i,
    'hover never routes through monitor relocation')
}
{
  const f = fixture(false)
  const { actions: a, A, handles, requests } = f
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.minimizeToplevel(A, true), true)
  handles[0].lastIpcObject.workspace = { name: 'special:smartdock-minimized' }
  requests.length = 0
  assert.equal(a.focusToplevelInPlace(A), true)
  assert.deepEqual(requests, ['movetoworkspace 3,address:0xa1',
    'focuswindow address:0xa1'], 'hover restores then focuses the pinned window')
  assert.equal(a.windowWorkspacePin(A).workspace, 'id:3')
  assert.doesNotMatch(requests.join(' '), /moveworkspace|movecurrentworkspace/i)
}

// Workspace pins turn every cross-monitor activation into focus-in-place.
{
  const f = fixture(false)
  const { actions: a, A, detached } = f
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  assert.equal(a.workspaceMonitorPin('id:3').monitor, 'id:0')
  const requests = a.workspaceOnMonitorRequests(3, 'id:1')
  assert.deepEqual(Array.from(requests), [DockModel.focusWorkspaceTargetRequest(3, false)])
  assert.equal(a.canRelocateWorkspaceToMonitor('id:3', 'id:1'), false)
  assert.equal(a.canRelocateWorkspaceToMonitor('id:3', 'id:0'), true)

  assert.equal(a.activateToplevel(A, true, 'id:1', false, 3), true)
  const command = detached.flat().join(' ')
  assert.doesNotMatch(command, /movecurrentworkspacetomonitor|moveworkspacetomonitor/i,
    'app/preview activation must focus pinned workspace in place')

  assert.equal(a.unpinWorkspaceFromMonitor('id:3'), true)
  assert.ok(a.workspaceOnMonitorRequests(3, 'id:1').length > 1,
    'unpinned workspace retains the existing pull behavior')
}

// Ctrl on a window pulls only that window onto the clicked monitor's live
// workspace; a window already home focuses without moving.
for (const usingLua of [false, true]) {
  const f = usingLua ? fixture(true) : fixture(false)
  const tag = usingLua ? 'lua' : 'legacy'
  const { actions: a, A, C, requests, detached } = f
  const focusA = usingLua
    ? 'hl.dsp.focus({ window = "address:0xa1" })' : 'focuswindow address:0xa1'
  const focusC = usingLua
    ? 'hl.dsp.focus({ window = "address:0xc3" })' : 'focuswindow address:0xc3'
  const moveC = usingLua
    ? 'hl.dsp.window.move({ window = "address:0xc3", workspace = "3", follow = false })'
    : 'movetoworkspacesilent 3,address:0xc3'
  function clearAll() {
    requests.length = 0
    detached.length = 0
  }

  clearAll()
  assert.equal(a.pullToplevelToMonitorWorkspace(A, true, 'id:0'), true)
  assert.deepEqual(requests, [focusA],
    `pull with the window already home focuses only (${tag})`)
  assert.equal(detached.length, 0)

  clearAll()
  assert.equal(a.pullToplevelToMonitorWorkspace(C, true, 'id:0'), true)
  assert.deepEqual(requests, [moveC, focusC],
    `pull moves only the window to the monitor workspace (${tag})`)
  assert.equal(detached.length, 0)

  clearAll()
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.pullToplevelToMonitorWorkspace(A, true, 'id:1'), false,
    'a pinned window refuses the Ctrl pull')
  assert.equal(requests.length, 0)
  assert.equal(detached.length, 0)
  assert.equal(a.unpinWindowFromWorkspace(A), true)

  clearAll()
  assert.equal(a.pullToplevelToMonitorWorkspace(A, true, 'id:99'), false)
  assert.equal(a.pullToplevelToMonitorWorkspace(A, true, ''), false)
  assert.equal(requests.length, 0)
  assert.equal(detached.length, 0)

  clearAll()
  assert.equal(a.minimizeToplevel(C, true), true)
  f.handles[2].lastIpcObject.workspace = { name: 'special:smartdock-minimized' }
  clearAll()
  assert.equal(a.pullToplevelToMonitorWorkspace(C, true, 'id:0'), true)
  const focusHome = usingLua
    ? 'hl.dsp.focus({ workspace = "3" })' : 'workspace 3'
  const restoreHome = usingLua
    ? 'hl.dsp.window.move({ window = "address:0xc3", workspace = "3", follow = true })'
    : 'movetoworkspace 3,address:0xc3'
  if (usingLua) {
    assert.deepEqual(requests, [
      `function() ${[focusHome, restoreHome, focusC].map(step => `hl.dispatch(${step})`).join('; ')} end`
    ], `pull restores a minimized window on the monitor workspace (${tag})`)
    assert.equal(detached.length, 0)
  } else {
    assert.deepEqual(requests, [],
      `pull restore does not race IPC sockets (${tag})`)
    assert.deepEqual(detached.map(command => Array.from(command)), [[
      'hyprctl', '--batch', [focusHome, restoreHome, focusC]
        .map(step => `dispatch ${step}`).join('; ')
    ]], `pull restores a minimized window on the monitor workspace (${tag})`)
  }
}

// Sidebar Ctrl routing through the real controller: window+Ctrl moves only
// the window, workspace+Ctrl pulls the workspace, plain clicks stay in place.
function sidebarScope(f) {
  const scope = methods('DockSidebarController.qml', { DockModel })
  Object.assign(scope, {
    interactionBusy: false,
    focusReturnTarget: null,
    windowActions: f.actions,
    targetIsCurrent: () => true,
    connectorIsMapped: name => name === 'DP-1' || name === 'DP-2',
    toggleApplication: () => false
  })
  return scope
}
for (const usingLua of [false, true]) {
  const f = usingLua ? fixture(true) : fixture(false)
  const tag = usingLua ? 'lua' : 'legacy'
  const { actions: a, A, C, requests, detached } = f
  const sidebar = sidebarScope(f)
  function clearAll() {
    requests.length = 0
    detached.length = 0
  }
  function expectRouted(steps, label) {
    if (usingLua) {
      assert.deepEqual(requests, [
        `function() ${steps.map(step => `hl.dispatch(${step})`).join('; ')} end`
      ], label)
      assert.equal(detached.length, 0, `${label} does not spawn hyprctl`)
    } else {
      assert.deepEqual(requests, [], `${label} does not race IPC sockets`)
      assert.deepEqual(detached.map(command => Array.from(command)), [[
        'hyprctl', '--batch', steps.map(step => `dispatch ${step}`).join('; ')
      ]], label)
    }
  }
  const focusA = usingLua
    ? 'hl.dsp.focus({ window = "address:0xa1" })' : 'focuswindow address:0xa1'
  const focusC = usingLua
    ? 'hl.dsp.focus({ window = "address:0xc3" })' : 'focuswindow address:0xc3'
  const moveC = usingLua
    ? 'hl.dsp.window.move({ window = "address:0xc3", workspace = "3", follow = false })'
    : 'movetoworkspacesilent 3,address:0xc3'
  const focusWs = target => usingLua
    ? `hl.dsp.focus({ workspace = "${target}" })` : `workspace ${target}`

  // Window with Ctrl on DP-1 (live workspace id:3): move only the window.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'window', key: 'win-c', toplevel: C, address: '0xc3' }, true, 'DP-1'), true)
  assert.deepEqual(requests, [moveC, focusC],
    `sidebar window+Ctrl moves only the window (${tag})`)
  assert.doesNotMatch(requests.join(' '), /moveworkspace/i,
    `sidebar window+Ctrl never moves a workspace (${tag})`)
  assert.equal(detached.length, 0)

  // Plain window click: focus in place.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'window', key: 'win-a', toplevel: A, address: '0xa1' }, false, 'DP-1'), true)
  assert.deepEqual(requests, [focusA],
    `sidebar plain window click focuses in place (${tag})`)
  assert.equal(detached.length, 0)

  // Workspace with Ctrl pulls the workspace to the clicked monitor. The
  // named workspace lives on DP-1, so Ctrl on DP-2 routes a monitor pull.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'workspace', key: 'ws-proj', workspaceIdentity: 'name:project space' },
    true, 'DP-2'), true)
  expectRouted([focusWs('name:project space'), usingLua
    ? 'hl.dsp.workspace.move({ workspace = "name:project space", monitor = "1" })'
    : 'movecurrentworkspacetomonitor 1', focusWs('name:project space')],
  `sidebar workspace+Ctrl pulls the workspace to the monitor (${tag})`)

  // Ctrl on the workspace's current monitor focuses without moving.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'workspace', key: 'ws-proj', workspaceIdentity: 'name:project space' },
    true, 'DP-1'), true)
  assert.deepEqual(requests, [focusWs('name:project space')],
    `sidebar workspace+Ctrl on the home monitor focuses in place (${tag})`)
  assert.equal(detached.length, 0)

  // Numeric workspace rows carry id:-form identities; the controller converts
  // to a command target before routing, so workspace+Ctrl pulls the workspace
  // like named workspaces. id:4 lives on DP-2, so Ctrl on DP-1 routes a pull.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'workspace', key: 'ws-4', workspaceIdentity: 'id:4' },
    true, 'DP-1'), true)
  expectRouted([focusWs('4'), usingLua
    ? 'hl.dsp.workspace.move({ workspace = "4", monitor = "0" })'
    : 'moveworkspacetomonitor 4 0', focusWs('4')],
  `sidebar workspace+Ctrl pulls the numeric workspace to the monitor (${tag})`)

  // Plain workspace click: focus in place.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'workspace', key: 'ws-4', workspaceIdentity: 'id:4' }, false, 'DP-1'), true)
  assert.deepEqual(requests, [focusWs('4')],
    `sidebar plain workspace click focuses in place (${tag})`)
  assert.equal(detached.length, 0)

  // An unmapped panel connector authorizes nothing.
  clearAll()
  assert.equal(sidebar.activateTarget(
    { kind: 'window', key: 'win-c', toplevel: C, address: '0xc3' }, true, 'GHOST'), false)
  assert.equal(sidebar.activateTarget(
    { kind: 'workspace', key: 'ws-4', workspaceIdentity: 'id:4' }, true, 'GHOST'), false)
  assert.equal(requests.length, 0)
  assert.equal(detached.length, 0)
  assert.equal(a, sidebar.windowActions, 'sidebar routes through the shared controller')
}

// Explicit workspace relocation is silent: one move, never focus→move→focus.
{
  const f = fixture(false)
  const { actions: a, requests, detached } = f
  assert.equal(a.moveWorkspaceToMonitor(3, 'id:1'), true)
  assert.deepEqual(requests, ['moveworkspacetomonitor 3 1'])
  assert.equal(detached.length, 0,
    'workspace relocation must not batch focus→move→focus commands')

  requests.length = 0
  detached.length = 0
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  assert.equal(a.moveWorkspaceToMonitor(3, 'id:1'), false)
  assert.equal(requests.length, 0)
  assert.equal(detached.length, 0, 'a pinned workspace blocks relocation before dispatch')
}

// Activation on a workspace's current monitor must not emit a redundant move.
{
  const f = fixture(false)
  const { actions: a, A, detached } = f
  assert.deepEqual(Array.from(a.workspaceOnMonitorRequests(3, 'id:0')),
    [DockModel.focusWorkspaceTargetRequest(3, false)])
  assert.equal(a.activateToplevel(A, true, 'id:0', false, 3), true)
  assert.doesNotMatch(detached.flat().join(' '),
    /movecurrentworkspacetomonitor|moveworkspacetomonitor/i,
    'same-monitor activation must focus without moving the workspace')
}

// Cycling and minimized activation share the same monitor-pin focus-only path.
{
  const f = fixture(false)
  const { actions: a, A, C, handles, detached } = f
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  assert.equal(a.cycleToplevels([C, A], 1, C, true, 'id:1'), true)
  assert.doesNotMatch(detached.flat().join(' '),
    /movecurrentworkspacetomonitor|moveworkspacetomonitor/i,
    'window cycling must not pull a pinned workspace')

  detached.length = 0
  assert.equal(a.minimizeToplevel(A, true), true)
  handles[0].lastIpcObject.workspace = { name: 'special:smartdock-minimized' }
  assert.equal(a.activateToplevel(A, true, 'id:1', true), true)
  assert.doesNotMatch(detached.flat().join(' '),
    /movecurrentworkspacetomonitor|moveworkspacetomonitor/i,
    'minimized restore/focus must keep a pinned workspace on its monitor')
}

// Explicit compositor lifecycle signals clear exact pins without guessing from gaps.
{
  const f = fixture()
  const { actions: a, A } = f
  assert.equal(a.pinWindowToWorkspace(A), true)
  assert.equal(a.confirmWindowClosed({ data: 'a1' }), true)
  assert.equal(a.windowWorkspacePins['0xa1'], undefined)

  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  assert.equal(a.confirmMonitorRemoved({ data: 'DP-1' }), true)
  assert.equal(a.workspaceMonitorPins['id:3'], undefined)
}

// Reconciliation clears only confirmed changes; incomplete inventory is retained.
{
  const f = fixture()
  const { actions: a, A, windows, handles, workspaces, monitors } = f
  assert.equal(a.pinWindowToWorkspace(A), true)
  const savedWindowPin = a.windowWorkspacePins['0xa1']
  windows.splice(windows.indexOf(A), 1)
  handles.splice(0, 1)
  a.reconcileSessionPins({})
  assert.equal(a.windowWorkspacePins['0xa1'], savedWindowPin,
    'transient missing window must not prove closure')
  a.reconcileSessionPins({ completeToplevels: true })
  assert.equal(a.windowWorkspacePins['0xa1'], undefined,
    'authoritative closure clears only the exact window pin')

  windows.unshift(A)
  handles.unshift({ wayland: A, address: 'a1',
    lastIpcObject: { workspace: { id: 3 }, monitor: 0, pinned: false } })
  assert.equal(a.pinWindowToWorkspace(A), true)
  handles[0].lastIpcObject.workspace = { id: 4 }
  a.reconcileSessionPins({})
  assert.equal(a.windowWorkspacePins['0xa1'], undefined,
    'present exact window on another workspace is a confirmed external relocation')

  handles[0].lastIpcObject.workspace = { id: 3 }
  assert.equal(a.pinWindowToWorkspace(A), true)
  const replacement = { appId: 'editor', title: 'replacement' }
  windows[0] = replacement
  handles[0].wayland = replacement
  a.reconcileSessionPins({ completeToplevels: true })
  assert.equal(a.windowWorkspacePins['0xa1'], undefined,
    'reused address must never transfer an old QObject pin')
  assert.equal(a.windowWorkspacePin(replacement), null)

  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  workspaces.splice(0, 1)
  a.reconcileSessionPins({})
  assert.ok(a.workspaceMonitorPins['id:3'],
    'transient missing workspace must not clear its pin')
  a.reconcileSessionPins({ completeWorkspaces: true })
  assert.equal(a.workspaceMonitorPins['id:3'], undefined)

  workspaces.unshift({ id: 3, name: '3', monitorID: 0 })
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  workspaces[0].monitorID = 1
  a.reconcileSessionPins({})
  assert.equal(a.workspaceMonitorPins['id:3'], undefined,
    'present workspace on another monitor confirms external relocation')

  workspaces[0].monitorID = 0
  assert.equal(a.pinWorkspaceToMonitor('id:3'), true)
  workspaces.splice(0, 1)
  monitors.splice(0, 1)
  a.reconcileSessionPins({})
  assert.ok(a.workspaceMonitorPins['id:3'],
    'partial monitor/workspace refresh retains the pin')
  a.reconcileSessionPins({ completeMonitors: true })
  assert.equal(a.workspaceMonitorPins['id:3'], undefined,
    'confirmed monitor disconnection clears affected monitor pins')
}

// Host/controller restart naturally starts with empty session state.
{
  const first = fixture()
  first.actions.pinWindowToWorkspace(first.A)
  first.actions.pinWorkspaceToMonitor('id:3')
  const restarted = fixture()
  assert.deepEqual(Object.keys(restarted.actions.windowWorkspacePins), [])
  assert.deepEqual(Object.keys(restarted.actions.workspaceMonitorPins), [])
}

const menuSource = read('DockContextMenu.qml')
assert.match(menuSource, /windowPin \? \"Unpin Window from \" : \"Pin Window to \"/)
assert.match(menuSource, /windowPinWorkspaceLabel\(reliableWorkspace\)/)
assert.match(menuSource, /pin-window-workspace/)
assert.match(menuSource, /unpin-window-workspace/)
const moveBody = menuSource.match(/function moveTargetToWorkspace\([\s\S]*?\n  }/)?.[0] || ''
assert.match(moveBody, /windowActions\.moveToplevelToWorkspace/,
  'context-menu moves must delegate to the central controller')
assert.doesNotMatch(moveBody, /DockModel\.moveWindowRequest|Hyprland\.dispatch/,
  'context menu must not retain a movement-dispatch bypass')

const dockSource = read('Dock.qml')
const headerActivationBody = dockSource.match(
  /function focusWorkspaceOnDockMonitor\([\s\S]*?\n  }/)?.[0] || ''
assert.match(headerActivationBody, /windowActions\.workspaceOnMonitorRequests/,
  'workspace-header activation must use the central monitor-pin policy')
assert.doesNotMatch(headerActivationBody, /moveWorkspaceToMonitorRequest|moveCurrentWorkspaceToMonitorRequest/,
  'workspace-header activation must not bypass the central monitor-pin policy')
assert.match(dockSource, /onActivated: pullToMonitor =>/,
  'plain header clicks focus in place while Ctrl pulls to the dock monitor')
assert.match(dockSource, /windowActions\.focusWorkspaceInPlace\(target\)/,
  'plain header clicks must use the shared in-place focus')
assert.match(dockSource, /windowActions\.activateToplevel/,
  'dock app/preview activation must retain the shared exact-window activation controller')

const dragSource = read('DockWorkspaceDrag.qml')
assert.match(dragSource, /workspaceMoveWouldChange\(members, destination\.identity\)/)
assert.match(dragSource, /moveCapturedToplevels\(members, hoveredIdentity, true\)/)

const actionsSource = read('DockWindowActions.qml')
assert.doesNotMatch(actionsSource, /settings\.(windowWorkspacePins|workspaceMonitorPins)/,
  'session pins must never be persisted in settings')

console.log('CM-04 central session pin guards, activation and reconciliation tests: PASS')
