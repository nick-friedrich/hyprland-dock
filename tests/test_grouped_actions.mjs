import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

const read = name => fs.readFileSync(new URL(`../components/${name}`, import.meta.url), 'utf8')
function model(name, imports = {}) {
  const scope = vm.createContext(imports)
  vm.runInContext(read(name).replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}
const DockModel = model('DockModel.js')
const DockWindowModel = model('DockWindowModel.js', { DockModel })
const PreviewModel = model('DockWindowPreviewModel.js', { DockWindowModel })
// Execute the real QML method bodies; only compositor transport is substituted.
function methods(file, properties) {
  const scope = vm.createContext(properties)
  scope.root = scope
  const bodies = read(file).match(/^  function [\s\S]*?^  }/gm) || []
  vm.runInContext(bodies.join('\n'), scope, { filename: file })
  return scope
}
const windows = [{}, {}]
const handles = windows.map((wayland, i) => ({ wayland, address: String(i + 1),
  lastIpcObject: { workspace: { name: 'special:smartdock-minimized' }, monitor: 0 } }))
const requests = []
const batches = []
const actions = methods('DockWindowActions.qml', {
  DockModel, DockWindowModel,
  minimizedOrigins: {}, minimizedWorkspace: 'special:smartdock-minimized',
  windowWorkspacePins: {}, workspaceMonitorPins: {},
  activeToplevel: windows[0],
  ToplevelManager: { toplevels: { values: windows } },
  Quickshell: { execDetached: command => batches.push(command) },
  Hyprland: { toplevels: { values: handles }, focusedWorkspace: { id: 3 },
    workspaces: { values: [
      { id: 4, name: '4', monitorID: 1 },
      { id: 5, name: '5', monitorID: 1 },
      { id: 7, name: '7', monitorID: 0 },
      { id: 9, name: '9', monitorID: 1 }
    ] },
    monitors: { values: [
      { id: 0, name: 'DP-1', activeWorkspace: { id: 7 } },
      { id: 1, name: 'DP-2', activeWorkspace: { id: 9 } }
    ] },
    usingLua: false, dispatch: request => requests.push(request) }
})
const item = methods('DockItem.qml', { DockModel, DockWindowModel, PreviewModel, windowActions: actions,
  originOnly: true, runningToplevels: windows, runningCount: 2, lastActivatedToplevel: -1 })

Object.assign(item, { entry: { name: 'Google Chrome' }, desktopId: 'google-chrome',
  browserProfileEntry: { name: 'Work' }, focused: false, runningCount: 1,
  sticky: false, minimizedCount: 0 })
assert.equal(item.tooltipLabel(), 'Google Chrome - Work — running application')
item.browserProfileEntry = { name: '' }
assert.equal(item.tooltipLabel(), 'Google Chrome — running application')
const preview = methods('DockWindowPreview.qml', { windowActions: actions, originOnly: true })

let previewRequests = 0
item.showPreviews = true
item.previewActivities = []
item.previewAgents = [{ id: 'agent-a' }]
item.previewRequested = () => { previewRequests++ }
assert.equal(item.hasPreviewContent(), true,
  'one window and one agent is preview-eligible')
assert.equal(item.dispatchApplicationAction('previews'), true,
  'configured previews click opens for one agent')
assert.equal(previewRequests, 1)
item.previewAgents = []
assert.equal(item.hasPreviewContent(), false)
assert.equal(item.dispatchApplicationAction('previews'), false)

const agentRow = {
  id: 'real-agent-id', indicatorKey: 'window\0server\0internal-agent-id',
  toplevel: windows[0]
}
let activatedAgentTarget = null
preview.herdrAgentActions = {
  captureAgentTarget(toplevel, agent) {
    assert.equal(toplevel, windows[0])
    assert.equal(agent.id, 'real-agent-id')
    assert.equal(agent.indicatorKey, 'window\0server\0internal-agent-id')
    return { agentId: agent.id, toplevel }
  },
  activateHerdrTarget(target) {
    activatedAgentTarget = target
    return true
  }
}
preview.dismissImmediately = () => {}
const exactAgentTarget = preview.captureAgentTarget(agentRow)
agentRow.id = 'replacement-agent-id'
assert.equal(preview.activateAgentTarget(exactAgentTarget), true)
assert.equal(activatedAgentTarget.agentId, 'real-agent-id',
  'preview activates the press/open-time target, not the current row')
const menu = methods('DockContextMenu.qml', { windowActions: actions, originOnly: true,
  selectedToplevel: windows[0], selectedMinimized: true })
menu.dismiss = () => {}
for (const origin of [undefined, { workspace: 'name:bad,dispatch' }]) {
  actions.minimizedOrigins = origin ? { '0x1': origin, '0x2': origin } : {}
  requests.length = 0
  for (const run of [
    () => actions.activateToplevel(windows[0], true),
    () => actions.focusToplevels(windows, true),
    () => actions.cycleToplevels(windows, 1, windows[0], true),
    () => actions.minimizeRestoreToplevels(windows, true),
    () => item.dispatchApplicationAction('focus-or-launch'),
    () => item.dispatchApplicationAction('cycle-windows', { direction: 1 }),
    () => item.dispatchApplicationAction('minimize-restore'),
    () => preview.activateToplevel(windows[0]),
    () => menu.minimizeRestoreSelected()
  ]) assert.equal(run(), false)
  assert.equal(requests.length, 0, 'grouped routes must never dispatch without a valid origin')
}
assert.equal(actions.activateToplevel(windows[0]), false, 'invalid flat origin remains rejected')
assert.equal(requests.length, 0)
actions.minimizedOrigins = {}
assert.equal(actions.activateToplevel(windows[0]), true)
assert.equal(requests.pop(), 'movetoworkspace 3,address:0x1')
actions.minimizedOrigins = { '0x1': { workspace: 'name:Design work', monitor: '0' } }
assert.equal(actions.restoreToplevel(windows[0], true), true)
assert.equal(requests.pop(), 'movetoworkspace name:Design work,address:0x1')
handles[0].lastIpcObject.workspace = {}
requests.length = 0
assert.equal(actions.minimizeToplevel(windows[0], true), false)
assert.equal(requests.length, 0)
assert.equal(Object.keys(actions.minimizedOrigins).length, 0, 'no guessed minimize origin')
assert.equal(actions.minimizeToplevel(windows[0]), true)
assert.equal(actions.minimizedOrigins['0x1'].workspace, '3')

const dropCards = [{ id: 'drop-1' }, { id: 'drop-3' }]
const cards = [
  { active: true, present: true, workspaceIdentity: 'id:1', headerWidth: 30,
    dropCard: dropCards[0] },
  { active: true, present: true, workspaceIdentity: 'id:3', headerWidth: 45,
    dropCard: dropCards[1] }
]
const revealed = []
const hyprland = actions.Hyprland
const dock = methods('Dock.qml', {
  grouped: true, activeCardIdentity: 'id:3',
  workspaceCards: { count: cards.length, itemAt: i => cards[i] },
  groupedLayout: { ensureVisible: (card, width) => revealed.push([card, width]) },
  DockModel, DockWindowModel, Hyprland: hyprland, windowActions: actions,
  dockHyprMonitor: { id: 0, name: 'DP-1' }
})
dock.revealActiveWorkspace()
assert.deepEqual(revealed, [[dropCards[1], 45]],
  'workspace switch reveals only the globally focused actual card header when multiple cards are active')

// Unmodified clicks focus in place; Ctrl+click keeps workspace-to-monitor pull.
preview.dismissImmediately = () => {}
item.applicationActions = DockModel.normalizeApplicationActionConfig({
  clickAction: 'focus-or-launch', middleClickAction: 'focus-or-launch',
  scrollAction: 'cycle-windows' })
item.activationMonitor = 'id:0'
preview.activationMonitor = 'id:0'
item.runningToplevels = [windows[0]]
item.runningCount = 1
actions.minimizedOrigins = {}
function expectRequests(actual, expected, label) {
  assert.deepEqual(actual, expected, label)
}
function clearSubmissions() {
  requests.length = 0
  batches.length = 0
}
function expectSequence(steps, usingLua, label) {
  if (usingLua) {
    expectRequests(requests, [
      `function() ${steps.map(step => `hl.dispatch(${step})`).join('; ')} end`
    ], label)
    expectRequests(batches, [], `${label} does not spawn hyprctl`)
  } else {
    expectRequests(requests, [], `${label} does not race IPC sockets`)
    expectRequests(batches.map(command => Array.from(command)), [[
      'hyprctl', '--batch', steps.map(step => `dispatch ${step}`).join('; ')
    ]], label)
  }
}
// External drag hover uses the same in-place focus path as ordinary activation.
for (const usingLua of [false, true]) {
  hyprland.usingLua = usingLua
  const restore = 'movetoworkspace name:Design work,address:0x1'
  const luaRestore = 'hl.dsp.window.move({ window = "address:0x1", workspace = "name:Design work", follow = true })'
  const focus = usingLua
    ? 'hl.dsp.focus({ window = "address:0x1" })' : 'focuswindow address:0x1'
  handles[0].lastIpcObject = { workspace: { name: 'special:smartdock-minimized' }, monitor: 0 }
  actions.minimizedOrigins = { '0x1': { workspace: 'name:Design work', monitor: '0' } }
  clearSubmissions()
  assert.equal(actions.focusToplevelInPlace(windows[0]), true)
  expectRequests(requests, [usingLua ? luaRestore : restore, focus],
    `hover restores then focuses explicitly (${usingLua ? 'lua' : 'legacy'})`)
  expectRequests(batches, [], 'hover never batches or relocates a monitor')
}
hyprland.usingLua = false
handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
actions.minimizedOrigins = {}
clearSubmissions()
assert.equal(actions.focusToplevelInPlace(windows[0]), true)
expectRequests(requests, ['focuswindow address:0x1'],
  'hover focuses a normal window where it currently lives')
assert.doesNotMatch(requests.join(' '), /moveworkspace|movecurrentworkspace/i,
  'hover never pulls a destination to another monitor')
handles[0].lastIpcObject = { workspace: { name: 'special:smartdock-minimized' }, monitor: 0 }
actions.minimizedOrigins = { '0x1': { workspace: 'name:bad,dispatch', monitor: '0' } }
clearSubmissions()
assert.equal(actions.focusToplevelInPlace(windows[0]), false,
  'a stale/invalid minimized origin fails closed')
expectRequests(requests, [], 'no restore or focus dispatch after a stale origin')
clearSubmissions()
assert.equal(actions.focusToplevelInPlace({}), false, 'a dead toplevel is not focusable')
expectRequests(requests, [])

hyprland.usingLua = true
handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
actions.minimizedOrigins = {}
clearSubmissions()
assert.equal(item.dispatchPointerAction('left', {}), true)
expectRequests(requests, [
  'hl.dsp.focus({ window = "address:0x1" })'
], 'unmodified icon activation focuses in place')
clearSubmissions()
assert.equal(item.dispatchPointerAction('left', { control: true }), true)
expectRequests(requests, [
  'hl.dsp.window.move({ window = "address:0x1", workspace = "7", follow = false })',
  'hl.dsp.focus({ window = "address:0x1" })'
], 'Ctrl+click moves only the focused window to the dock monitor workspace')
for (const usingLua of [false, true]) {
  hyprland.usingLua = usingLua
  const moveWorkspace = target => usingLua
    ? `hl.dsp.workspace.move({ workspace = "${target}", monitor = "0" })`
    : `moveworkspacetomonitor ${target} 0`
  const focusWorkspace = target => usingLua
    ? `hl.dsp.focus({ workspace = "${target}" })`
    : `workspace ${target}`
  const moveCurrentWorkspace = usingLua
    ? 'hl.dsp.workspace.move({ monitor = "0" })'
    : 'movecurrentworkspacetomonitor 0'
  const focusWindow = address => usingLua
    ? `hl.dsp.focus({ window = "address:${address}" })`
    : `focuswindow address:${address}`
  const restoreWindow = (address, workspace) => usingLua
    ? `hl.dsp.window.move({ window = "address:${address}", workspace = "${workspace}", follow = true })`
    : `movetoworkspace ${workspace},address:${address}`
  function expectInPlace(request, label) {
    expectRequests(requests, Array.isArray(request) ? request : [request], label)
    expectRequests(batches, [], `${label} does not spawn hyprctl`)
  }
  // Ctrl on a window pulls only that window onto the dock monitor's live
  // workspace (id:7 here); the window's old workspace never moves.
  const moveWindowToDock = usingLua
    ? 'hl.dsp.window.move({ window = "address:0x1", workspace = "7", follow = false })'
    : 'movetoworkspacesilent 7,address:0x1'
  const focusDockWorkspace = usingLua
    ? 'hl.dsp.focus({ workspace = "7" })'
    : 'workspace 7'

  clearSubmissions()
  dock.focusWorkspaceOnDockMonitor('name:Design work')
  expectSequence(usingLua
    ? [focusWorkspace('name:Design work'), moveWorkspace('name:Design work'),
        focusWorkspace('name:Design work')]
    : [focusWorkspace('name:Design work'), moveCurrentWorkspace,
        focusWorkspace('name:Design work')], usingLua,
    `workspace switch order (${usingLua ? 'lua' : 'legacy'})`)

  const previousMonitor = dock.dockHyprMonitor
  dock.dockHyprMonitor = null
  clearSubmissions()
  dock.focusWorkspaceOnDockMonitor('name:Design work')
  expectRequests(requests, [],
    `workspace switch emits nothing without monitor (${usingLua ? 'lua' : 'legacy'})`)
  expectRequests(batches, [],
    `workspace switch spawns nothing without monitor (${usingLua ? 'lua' : 'legacy'})`)
  dock.dockHyprMonitor = previousMonitor

  clearSubmissions()
  assert.equal(actions.focusWorkspaceInPlace('9'), true)
  expectInPlace(focusWorkspace('9'),
    `plain header click focuses the workspace in place (${usingLua ? 'lua' : 'legacy'})`)

  clearSubmissions()
  dock.focusWorkspaceOnDockMonitor('9')
  expectSequence([focusWorkspace('9'), moveWorkspace('9'),
    focusWorkspace('9')], usingLua,
    `Ctrl header click pulls the workspace to the dock monitor (${usingLua ? 'lua' : 'legacy'})`)

  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
  actions.minimizedOrigins = {}
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', {}), true)
  expectInPlace(focusWindow('0x1'),
    `ordinary icon activation focuses in place (${usingLua ? 'lua' : 'legacy'})`)

  clearSubmissions()
  assert.equal(item.dispatchPointerAction('middle', {}), true)
  expectInPlace(focusWindow('0x1'),
    `ordinary middle click focuses in place (${usingLua ? 'lua' : 'legacy'})`)

  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', { control: true }), true)
  expectInPlace([moveWindowToDock, focusWindow('0x1')],
    `Ctrl+click icon activation moves only the window to the dock monitor workspace (${usingLua ? 'lua' : 'legacy'})`)

  item.workspaceActivationTarget = 'name:Design work'
  handles[0].lastIpcObject = { monitor: 1 }
  actions.minimizedOrigins = {}
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', { control: true }), true)
  expectInPlace([moveWindowToDock, focusWindow('0x1')],
    `card-window Ctrl+click ignores the card workspace override and pulls to the monitor workspace (${usingLua ? 'lua' : 'legacy'})`)

  for (const cardTarget of [9, 'name:Design work']) {
    for (const modifiers of [undefined, null, {}, { control: false }]) {
      item.workspaceActivationTarget = cardTarget
      handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
      actions.minimizedOrigins = {}
      clearSubmissions()
      assert.equal(item.dispatchPointerAction('left', modifiers), true)
      expectInPlace(focusWindow('0x1'),
        `card-window plain click focuses in place for ${String(cardTarget)} with ${JSON.stringify(modifiers)} (${usingLua ? 'lua' : 'legacy'})`)
    }
  }
  item.workspaceActivationTarget = ''
  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }

  clearSubmissions()
  assert.equal(item.dispatchPointerAction('middle', { control: true }), true)
  expectInPlace(focusWindow('0x1'),
    `Ctrl+middle click keeps plain focus without monitor routing (${usingLua ? 'lua' : 'legacy'})`)

  // Non-left inputs still carry the card workspace override, so Ctrl+middle
  // on a card window keeps its previous workspace-pull behavior.
  item.workspaceActivationTarget = 'name:Design work'
  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
  actions.minimizedOrigins = {}
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('middle', { control: true }), true)
  expectSequence(usingLua
    ? [focusWorkspace('name:Design work'), moveWorkspace('name:Design work'),
        focusWorkspace('name:Design work'), focusWindow('0x1')]
    : [focusWorkspace('name:Design work'), moveCurrentWorkspace,
        focusWorkspace('name:Design work'), focusWindow('0x1')], usingLua,
    `card-window Ctrl+middle keeps the card workspace override (${usingLua ? 'lua' : 'legacy'})`)
  item.workspaceActivationTarget = ''
  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }

  clearSubmissions()
  assert.equal(preview.activateToplevel(windows[0]), true)
  expectInPlace(focusWindow('0x1'),
    `ordinary preview activation focuses in place (${usingLua ? 'lua' : 'legacy'})`)

  clearSubmissions()
  assert.equal(preview.activateToplevel(windows[0], true), true)
  expectInPlace([moveWindowToDock, focusWindow('0x1')],
    `Ctrl+click preview activation moves only that window (${usingLua ? 'lua' : 'legacy'})`)

  actions.activeToplevel = windows[0]
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', {}), true)
  expectInPlace(focusWindow('0x1'),
    `active-other-monitor icon activation focuses in place (${usingLua ? 'lua' : 'legacy'})`)

  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', { control: true }), true)
  expectInPlace([moveWindowToDock, focusWindow('0x1')],
    `Ctrl+click active-other-monitor icon activation moves only the window (${usingLua ? 'lua' : 'legacy'})`)

  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', {}), true)
  expectInPlace(restoreWindow('0x1', '4'),
    `unmodified minimized icon restore omits monitor routing (${usingLua ? 'lua' : 'legacy'})`)

  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('left', { control: true }), true)
  expectSequence([focusDockWorkspace, restoreWindow('0x1', '7'),
    focusWindow('0x1')], usingLua,
    `Ctrl+click minimized icon activation restores on the dock monitor workspace (${usingLua ? 'lua' : 'legacy'})`)

  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  clearSubmissions()
  assert.equal(preview.activateToplevel(windows[0]), true)
  expectInPlace(restoreWindow('0x1', '4'),
    `unmodified minimized preview restore omits monitor routing (${usingLua ? 'lua' : 'legacy'})`)

  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  clearSubmissions()
  assert.equal(preview.activateToplevel(windows[0], true), true)
  expectSequence([focusDockWorkspace, restoreWindow('0x1', '7'),
    focusWindow('0x1')], usingLua,
    `Ctrl+click minimized preview activation restores on the dock monitor workspace (${usingLua ? 'lua' : 'legacy'})`)

  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  handles[1].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  actions.minimizedOrigins = {
    '0x1': { workspace: '4', monitor: 'id:1' },
    '0x2': { workspace: '5', monitor: 'id:1' }
  }
  actions.activeToplevel = windows[0]
  item.runningToplevels = windows
  item.runningCount = 2
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('scroll', {}, { direction: 1 }), true)
  expectSequence([focusWorkspace('5'), moveWorkspace('5'),
    focusWorkspace('5'), restoreWindow('0x2', '5'), focusWindow('0x2')], usingLua,
    `minimized scroll cycle keeps dock monitor routing (${usingLua ? 'lua' : 'legacy'})`)
  assert.equal(actions.minimizedOrigins['0x2'], undefined,
    'successful scroll restore forgets the minimized origin')

  handles[0].lastIpcObject = { workspace: { id: 8 }, monitor: 1 }
  handles[1].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
  actions.minimizedOrigins = {}
  actions.activeToplevel = windows[0]
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('scroll', {}, { direction: 1 }), true)
  expectSequence([focusWorkspace('9'), moveWorkspace('9'),
    focusWorkspace('9'), focusWindow('0x2')], usingLua,
    `ordinary scroll cycle keeps dock monitor routing (${usingLua ? 'lua' : 'legacy'})`)

  for (const modifiers of [{ control: true }, { shift: true }, { alt: true },
    { meta: true }, { control: true, shift: true }]) {
    clearSubmissions()
    assert.equal(item.dispatchPointerAction('scroll', modifiers, { direction: 1 }), false)
    expectRequests(requests, [], 'modified scrolling does not dispatch')
    expectRequests(batches, [], 'modified scrolling does not spawn hyprctl')
  }
  item.applicationActions.scrollAction = 'none'
  clearSubmissions()
  assert.equal(item.dispatchPointerAction('scroll', {}, { direction: 1 }), false)
  expectRequests(requests, [], 'disabled scrolling does not dispatch')
  expectRequests(batches, [], 'disabled scrolling does not spawn hyprctl')
  item.applicationActions.scrollAction = 'cycle-windows'

  // Context-menu / minimize-restore paths omit activationMonitor and keep old restore.
  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  clearSubmissions()
  assert.equal(actions.restoreToplevel(windows[0], true), true)
  expectRequests(requests, [restoreWindow('0x1', '4')],
    `explicit restore omits monitor routing (${usingLua ? 'lua' : 'legacy'})`)
  expectRequests(batches, [],
    `explicit restore stays a single IPC request (${usingLua ? 'lua' : 'legacy'})`)

  item.runningToplevels = [windows[0]]
  item.runningCount = 1
}

// pullToplevelToMonitorWorkspace: Ctrl on a window moves only that window to
// the activating monitor's live workspace (id:7 on id:0 here). The window's
// old workspace never moves.
for (const usingLua of [false, true]) {
  hyprland.usingLua = usingLua
  const tag = usingLua ? 'lua' : 'legacy'
  const pullMove = usingLua
    ? 'hl.dsp.window.move({ window = "address:0x1", workspace = "7", follow = false })'
    : 'movetoworkspacesilent 7,address:0x1'
  const pullFocusWorkspace = usingLua
    ? 'hl.dsp.focus({ workspace = "7" })' : 'workspace 7'
  const pullRestore = usingLua
    ? 'hl.dsp.window.move({ window = "address:0x1", workspace = "7", follow = true })'
    : 'movetoworkspace 7,address:0x1'
  const pullFocusWindow = usingLua
    ? 'hl.dsp.focus({ window = "address:0x1" })' : 'focuswindow address:0x1'

  // Already on the target workspace: focus only, no move.
  handles[0].lastIpcObject = { workspace: { id: 7 }, monitor: 0 }
  actions.minimizedOrigins = {}
  actions.windowWorkspacePins = {}
  clearSubmissions()
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, 'id:0'), true)
  expectRequests(requests, [pullFocusWindow],
    `pull with the window already home focuses only (${tag})`)
  expectRequests(batches, [],
    `pull with the window already home spawns nothing (${tag})`)

  // Normal move: silent window move, then focus.
  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
  clearSubmissions()
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, 'id:0'), true)
  expectRequests(requests, [pullMove, pullFocusWindow],
    `pull moves only the window to the monitor workspace (${tag})`)
  expectRequests(batches, [], `pull does not spawn hyprctl (${tag})`)

  // Minimized: the origin is rewritten to the destination, then restored there.
  handles[0].lastIpcObject = {
    workspace: { name: 'special:smartdock-minimized' }, monitor: 1 }
  actions.minimizedOrigins = { '0x1': { workspace: '4', monitor: 'id:1' } }
  clearSubmissions()
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, 'id:0'), true)
  if (usingLua) {
    expectRequests(requests, [
      `function() ${[pullFocusWorkspace, pullRestore, pullFocusWindow]
        .map(step => `hl.dispatch(${step})`).join('; ')} end`
    ], `pull restores a minimized window on the monitor workspace (${tag})`)
    expectRequests(batches, [],
      `pull restore does not spawn hyprctl (${tag})`)
  } else {
    expectRequests(requests, [],
      `pull restore does not race IPC sockets (${tag})`)
    expectRequests(batches.map(command => Array.from(command)), [[
      'hyprctl', '--batch', [pullFocusWorkspace, pullRestore, pullFocusWindow]
        .map(step => `dispatch ${step}`).join('; ')
    ]], `pull restores a minimized window on the monitor workspace (${tag})`)
  }

  // Pin-refused: a pinned window never moves and never focuses.
  handles[0].lastIpcObject = { workspace: { id: 9 }, monitor: 1 }
  actions.minimizedOrigins = {}
  actions.windowWorkspacePins = {}
  assert.equal(actions.pinWindowToWorkspace(windows[0]), true)
  clearSubmissions()
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, 'id:0'), false)
  expectRequests(requests, [], `pin-refused pull dispatches nothing (${tag})`)
  expectRequests(batches, [], `pin-refused pull spawns nothing (${tag})`)
  actions.windowWorkspacePins = {}

  // Unknown monitor: no destination, no dispatch.
  clearSubmissions()
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, 'id:99'), false)
  assert.equal(actions.pullToplevelToMonitorWorkspace(windows[0], true, ''), false)
  expectRequests(requests, [],
    `pull to an unknown monitor dispatches nothing (${tag})`)
  expectRequests(batches, [],
    `pull to an unknown monitor spawns nothing (${tag})`)
}

// Ctrl-click with no running windows still launches.
const savedEntry = item.entry
const launched = []
item.entry = { name: 'Google Chrome', execute: () => launched.push('launched') }
item.runningToplevels = []
item.runningCount = 0
clearSubmissions()
assert.equal(item.dispatchPointerAction('left', { control: true }), true)
assert.deepEqual(launched, ['launched'], 'Ctrl+click with no windows launches')
expectRequests(requests, [], 'launch dispatches nothing')
expectRequests(batches, [], 'launch spawns nothing')
item.entry = savedEntry
item.runningToplevels = [windows[0]]
item.runningCount = 1

// Ctrl-click routing contract: plain header/strip clicks focus in place,
// Ctrl pulls the workspace; Ctrl on a window pulls only that window.
const dockQml = read('Dock.qml')
assert.match(dockQml, /onActivated: pullToMonitor =>/)
assert.match(dockQml, /root\.windowActions\.focusWorkspaceInPlace\(target\)/)
assert.match(dockQml, /onWorkspaceRequested: \(workspaceId, pullToMonitor\) =>/)
assert.match(dockQml, /readonly property int pinnedIconGap/)
assert.match(dockQml, /spacing: Math\.max\(0, root\.pinnedIconGap - \(root\.itemSize - root\.iconSize\)\)/)
const groupSource = read('DockWorkspaceGroup.qml')
assert.match(groupSource, /signal activated\(bool pullToMonitor\)/)
assert.match(groupSource, /acceptedModifiers: Qt\.NoModifier/)
assert.match(groupSource, /acceptedModifiers: Qt\.ControlModifier/)
assert.match(groupSource, /root\.activated\(false\)/)
assert.match(groupSource, /root\.activated\(true\)/)
assert.match(groupSource, /font\.pixelSize: Style\.font\.body/)
assert.match(groupSource, /font\.weight: Font\.DemiBold/)
const stripSource = read('DockWorkspaceStrip.qml')
assert.match(stripSource, /signal workspaceRequested\(int workspaceId, bool pullToMonitor\)/)
assert.match(stripSource, /workspaceRequested\(workspaceCell\.workspaceId, false\)/)
assert.match(stripSource, /workspaceRequested\(workspaceCell\.workspaceId, true\)/)
const previewSource = read('DockWindowPreview.qml')
assert.match(previewSource,
  /pullToplevelToMonitorWorkspace\(\s*toplevel, root\.originOnly, root\.activationMonitor\)/)
const itemSource = read('DockItem.qml')
assert.match(itemSource,
  /pullToplevelToMonitorWorkspace\(\s*root\.runningToplevels\[root\.lastActivatedToplevel\]/)
assert.doesNotMatch(itemSource, /keys\.control === true \|\| \(input !== "left"/,
  'Ctrl+left no longer injects a workspace pull; it moves only the window')
assert.equal(read('Dock.qml').includes('indexOf(modelData)'), false)
assert.equal(read('Dock.qml').includes('workspaceScopeKey(root.screen.name, modelData.presentationId)'), true)
// Fullscreen presentation is scoped by workspace-card identity. Global
// launchers and fallback windows remain neutral, and drag snapshots freeze it.
const fullscreenDockSource = read('Dock.qml')
const aOwner = {}, aSibling = {}, bOwner = {}, bSibling = {}, neutralWindow = {}
const fullscreenGroups = [
  { identity: 'id:1', items: [{ toplevels: [aSibling, aOwner] }] },
  { identity: 'id:2', items: [{ toplevels: [bSibling, bOwner] }] },
  { identity: 'id:3', items: [{ toplevels: [neutralWindow] }] }
]
const fullscreenHandles = [
  { wayland: aOwner, lastIpcObject: { fullscreen: 1, fullscreenClient: 0 } },
  { wayland: aSibling, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } },
  { wayland: bOwner, lastIpcObject: { fullscreen: 1, fullscreenClient: 1 } },
  { wayland: bSibling, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } },
  { wayland: neutralWindow, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } }
]
const cardOwners = DockModel.workspaceFullscreenOwners(
  fullscreenGroups, fullscreenHandles, null, [])
assert.equal(cardOwners['id:1'], aOwner)
assert.equal(cardOwners['id:2'], bOwner)
assert.equal(cardOwners['id:3'], undefined)
function cardPresentation(identity, toplevels) {
  const owner = cardOwners[identity]
  return DockModel.fullscreenIconPresentation(
    owner !== undefined, owner !== undefined && toplevels.includes(owner), false)
}
const emphasizedPresentation = cardPresentation('id:1', [aOwner])
const siblingPresentation = cardPresentation('id:1', [aSibling])
const neutralCardPresentation = cardPresentation('id:3', [neutralWindow])
assert.equal(emphasizedPresentation.scale, 1.15)
assert.equal(emphasizedPresentation.opacity, 1)
assert.equal(siblingPresentation.scale, 0.9)
assert.equal(siblingPresentation.opacity, 0.45)
assert.equal(neutralCardPresentation.scale, 1)
assert.equal(neutralCardPresentation.opacity, 1)
assert.ok(fullscreenDockSource.includes(
  'root.workspaceFullscreenOwners[workspaceCard.modelData.identity]'),
  'grouped card delegate must read only its local owner')
assert.ok(fullscreenDockSource.includes(
  'return windowActions.isMinimized(toplevel)'),
  'grouped ownership must reuse DockWindowActions.isMinimized()')
assert.ok(fullscreenDockSource.includes(
  'readonly property bool groupedFullscreenModeActive:'),
  'grouped padding must react to any card owner')
assert.ok(fullscreenDockSource.includes(
  'workspaceDragActive ? dragWorkspaceFullscreenOwners : liveWorkspaceFullscreenOwners'),
  'workspace drag must freeze the per-card fullscreen snapshot')
assert.ok(fullscreenDockSource.includes(
  'root.dragWorkspaceFullscreenOwners = root.liveWorkspaceFullscreenOwners'),
  'drag preparation must capture the per-card fullscreen snapshot')
assert.ok(fullscreenDockSource.includes(`model: root.groupedRequested ? root.workspacePresentation.globalLaunchers : []
          AppIcon {
            y: 2
            fullscreenModeActive: false
            fullscreenEmphasized: false
          }`), 'global launchers stay neutral')
assert.ok(fullscreenDockSource.includes(`model: root.groupedRequested ? root.workspacePresentation.fallbackItems : []
            AppIcon {
              fullscreenModeActive: false
              fullscreenEmphasized: false
            }`), 'fallback icons stay neutral')

// Evaluate the production marker bindings: grouped magnification must not push
// the focus underline outside the compact surface, even with zero edge margin.
const markerBlock = read('DockItem.qml').split('id: applicationStateIndicator')[1].split('\n    }')[0]
function markerBinding(name, fallback, scope) {
  const expression = markerBlock.match(new RegExp(`^      ${name}: (.+)$`, 'm'))?.[1]
  return expression ? vm.runInNewContext(expression, scope) : fallback
}
for (const iconSize of [24, 31, 64, 96]) for (const position of ['top', 'bottom']) {
  const slot = { originOnly: true }
  const iconContainer = { x: 7, y: 10, opacity: 0.4 }
  const geometry = DockModel.applicationStateIndicatorGeometry(position, iconSize, iconSize, true, true)
  const scope = { root: slot, iconContainer, indicatorGeometry: geometry }
  const markerParent = markerBinding('parent', iconContainer, scope)
  const markerY = markerBinding('y', geometry.y, scope)
  for (const magnification of [1, 2]) {
    const scale = markerParent === iconContainer ? magnification : 1
    const origin = position === 'bottom' ? iconSize : 0
    const top = markerParent === iconContainer
      ? iconContainer.y + origin + (markerY - origin) * scale : markerY
    // Actual source surface height; the item has six extra cross-axis pixels.
    const backgroundHeight = vm.runInNewContext(read('Dock.qml').split('id: dockBackground')[1].match(/height: root.vertical \? parent.height : (.+)/)[1],
      { root: { iconSize, grouped: true } })
    const itemHeight = iconSize + 20
    assert.ok(top + (backgroundHeight - itemHeight) / 2 >= 0, 'top marker fits compact surface')
    assert.ok(top + geometry.height * scale <= (backgroundHeight + itemHeight) / 2,
      'bottom marker fits compact surface')
  }
  assert.equal(markerBinding('opacity', 1, scope), 0.4, 'reparented marker retains fullscreen opacity')
}
// Trailing whitespace stays compact, while fullscreen emphasis still fits at
// maximum magnification. Evaluate the host binding rather than a copied formula.
const paddingExpression = read('Dock.qml').split('id: groupedLayout')[1]
  .match(/contentPadding: ([\s\S]*?)\n        foreground:/)[1]
const paddingFor = root => vm.runInNewContext(paddingExpression, { root, DockModel })
assert.ok(paddingFor({ iconSize: 24, magnification: 1.2, groupedFullscreenModeActive: false }) <= 4,
  'default grouped spacing must not add redundant viewport padding')
assert.ok(paddingFor({ iconSize: 24, magnification: 2, groupedFullscreenModeActive: false }) + 7 >= 12 + 8,
  'global launcher hover tile fits its slot inset plus viewport allowance')
const largeOwnerScale = DockModel.fullscreenIconPresentation(true, true, false).scale * 2
const largeOwnerOverhang = 96 * (largeOwnerScale - 1) / 2
assert.ok(paddingFor({ iconSize: 96, magnification: 2, groupedFullscreenModeActive: true }) + 13 >= largeOwnerOverhang,
  'fullscreen artwork fits the trailing card inset plus viewport allowance')
const inactiveOnlyHandles = [
  { wayland: aOwner, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } },
  { wayland: aSibling, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } },
  { wayland: bOwner, lastIpcObject: { fullscreen: 1, fullscreenClient: 0 } },
  { wayland: bSibling, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } },
  { wayland: neutralWindow, lastIpcObject: { fullscreen: 0, fullscreenClient: 0 } }
]
const noOwnerHandles = inactiveOnlyHandles.map(handle => ({
  wayland: handle.wayland,
  lastIpcObject: { fullscreen: 0, fullscreenClient: handle.lastIpcObject.fullscreenClient }
}))
const inactiveOwners = DockModel.workspaceFullscreenOwners(
  fullscreenGroups, inactiveOnlyHandles, aSibling, [])
assert.equal(inactiveOwners['id:2'], bOwner)
assert.equal(inactiveOwners['id:1'], undefined)
const noOwners = DockModel.workspaceFullscreenOwners(
  fullscreenGroups, noOwnerHandles, aSibling, [])
const oneOwnerPadding = paddingFor({
  iconSize: 96, magnification: 2,
  groupedFullscreenModeActive: Object.keys(inactiveOwners).length > 0
})
const twoOwnerPadding = paddingFor({
  iconSize: 96, magnification: 2,
  groupedFullscreenModeActive: Object.keys(cardOwners).length > 0
})
const clearedPadding = paddingFor({
  iconSize: 96, magnification: 2,
  groupedFullscreenModeActive: Object.keys(noOwners).length > 0
})
const normalPadding = paddingFor({
  iconSize: 96, magnification: 2, groupedFullscreenModeActive: false
})
assert.ok(oneOwnerPadding > clearedPadding,
  'inactive-card owner reserves fullscreen padding')
assert.equal(oneOwnerPadding, twoOwnerPadding,
  'multiple owners reserve the same padding as one owner')
assert.equal(clearedPadding, normalPadding,
  'padding returns to normal after the final owner clears')

console.log('grouped action routes and compact geometry: PASS')

// Execute the geometry bindings from QML. This catches trimming the logical
// layout with the surface, which silently reintroduces the trailing gap.
function binding(block, name, scope) {
  const expression = block.match(new RegExp(`^( *)${name}: ([^\\n]*(?:\\n\\1 +[^\\n]+)*)`, 'm'))?.[2]
  assert.ok(expression, `missing binding ${name}`)
  return vm.runInNewContext(expression, scope)
}
const dockSource = read('Dock.qml')
const backgroundSource = dockSource.split('id: dockBackground')[1]
const layoutSource = dockSource.split('id: dockLayout')[1]
const groupedSource = dockSource.split('id: groupedLayout')[1]
function dockGeometry(options = {}) {
  const root = { iconSize: 24, magnification: 1.2, groupedFullscreenModeActive: false,
    grouped: true, vertical: false, fullLength: false, showTrash: false,
    screen: { width: 1920 }, ...options }
  const groupedLayout = { contentPadding: paddingFor(root) }
  groupedLayout.desiredWidth = binding(read('DockWorkspaceLayout.qml'),
    'readonly property real desiredWidth', { content: { implicitWidth: 300 }, ...groupedLayout })
  Object.assign(root, { itemSize: root.iconSize + (root.grouped ? 14 : 22),
    mainPadding: root.grouped ? 8 : 16, appMainExtent: groupedLayout.desiredWidth,
    trailingMainExtent: root.showTrash ? 70 : root.grouped ? 0 : 90, crossExtent: 200 })
  const scope = { root, groupedLayout, ...root }
  root.compactMainExtent = binding(dockSource, 'readonly property int compactMainExtent', scope)
  // Bind any surface geometry properties in source order, as QML dependencies.
  for (const name of ['groupedSurfaceTrim', 'groupedSurfaceGutter', 'compactGroupedSurface', 'compactPanelExtent']) {
    const declaration = `readonly property ${name === 'compactGroupedSurface' ? 'bool' : 'int'} ${name}`
    if (dockSource.includes(declaration)) {
      root[name] = binding(dockSource, declaration, { ...scope, ...root })
    }
  }
  const panelWidth = root.fullLength ? root.screen.width
    : binding(dockSource, 'implicitWidth', { ...scope, ...root })
  const parent = { width: panelWidth }
  const inputSource = dockSource.split('id: interactionArea')[1]
  const interactionArea = { width: binding(inputSource, 'width', { root, parent }) }
  interactionArea.x = binding(inputSource, 'x', { parent, ...interactionArea })
  const surfaceWidth = binding(backgroundSource, 'width', { root, parent, interactionArea })
  const surfaceX = binding(backgroundSource, 'x', { root, parent, interactionArea, width: surfaceWidth })
  const layoutWidth = layoutSource.trimStart().startsWith('anchors.fill: parent') ? surfaceWidth
    : binding(layoutSource, 'width', { root, parent: { width: surfaceWidth } })
  const dockLayout = { width: layoutWidth, height: 200 }
  for (const name of ['leadingEnd', 'trailingStart', 'centeredAppStart', 'appStart'])
    dockLayout[name] = binding(layoutSource, `readonly property real ${name}`, { root, ...dockLayout })
  const viewportX = binding(groupedSource, 'x', { dockLayout })
  const viewportWidth = binding(groupedSource, 'width', { dockLayout, x: viewportX,
    desiredWidth: groupedLayout.desiredWidth })
  return { root, panelWidth, interactionArea, surfaceWidth, surfaceX, layoutWidth, viewportX, viewportWidth,
    visibleRight: surfaceX + viewportX + groupedLayout.contentPadding + 300,
    desiredWidth: groupedLayout.desiredWidth }
}
for (const iconSize of [24, 31, 64, 96]) for (const magnification of [1, 1.2, 2])
  for (const groupedFullscreenModeActive of [false, true]) {
    const g = dockGeometry({ iconSize, magnification, groupedFullscreenModeActive })
    assert.equal(g.surfaceX + g.surfaceWidth - g.visibleRight, g.root.mainPadding,
      'visible right inset matches the leading padding')
    assert.equal(g.surfaceX * 2 + g.surfaceWidth, g.panelWidth, 'visible surface is centered')
    assert.equal(g.layoutWidth, g.root.compactMainExtent, 'logical layout retains its original width')
    assert.equal(g.viewportWidth, g.desiredWidth, 'magnification viewport is not reduced')
    assert.equal(g.panelWidth, 1920, 'workspace content does not resize the native panel')
    assert.equal(g.interactionArea.width, g.root.compactPanelExtent, 'transparent sides are click-through')
    assert.ok(g.surfaceX >= 0 && g.surfaceX + g.surfaceWidth <= g.panelWidth)
    assert.ok(g.surfaceX + g.viewportX + g.viewportWidth <= g.panelWidth, 'viewport fits outer panel')
    if (g.root.groupedSurfaceGutter > 0) {
      const dockLayout = { x: g.surfaceX, width: g.layoutWidth }
      const dockBackground = { x: g.surfaceX, width: g.surfaceWidth }
      const pointerParent = binding(dockSource.split('id: pointer')[1], 'parent',
        { root: g.root, dockLayout, dockBackground })
      const pointX = g.viewportX + g.viewportWidth - 1
      const pointer = { hovered: pointX < pointerParent.width,
        point: { position: { x: pointX, y: 30 } } }
      assert.ok(pointer.hovered, 'tracking covers transparent magnification allowance')
      assert.equal(binding(dockSource, 'readonly property real pointerPosition',
        { pointer, vertical: false }), pointX, 'control pointer retains logical origin')
      const appParentX = g.surfaceX + g.viewportX + paddingFor(g.root)
      const parent = { mapFromItem: (source, x, y) => ({ x: source.x + x - appParentX, y }) }
      assert.equal(binding(dockSource.split('component AppIcon:')[1], 'pointerPosition',
        { pointer, root: g.root, parent, dockLayout, dockBackground }),
      g.viewportWidth - paddingFor(g.root) - 1, 'app pointer mapping includes gutter exactly once')
    }
  }
for (const options of [{ grouped: false }, { showTrash: true },
  { fullLength: true }, { screen: { width: 200 } },
  { iconSize: 96, magnification: 2, screen: { width: 540 } }]) {
  const g = dockGeometry(options)
  assert.equal(g.surfaceX, g.interactionArea.x, 'untrimmed surface follows the input region')
  assert.equal(g.surfaceWidth, g.interactionArea.width)
  assert.ok(g.viewportWidth >= 0)
}

const verticalBackground = {}
assert.equal(binding(dockSource.split('id: pointer')[1], 'parent',
  { root: { vertical: true }, dockBackground: verticalBackground, dockLayout: {} }), verticalBackground,
'Vertical pointer parent is unchanged')
console.log('grouped visible surface and magnification bounds: PASS')
