import assert from 'node:assert/strict'
import {hostHarness, plain, loadModel} from './host_harness.mjs'
import {qmlMethods} from './sidebar_interaction_fixture.mjs'

const {host, request, writes} = hostHarness({})
host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
host.sidebarState = {mappedScreens: host.connectedScreens, interactionBusy: false}
host.settings = {...host.settings,
  presentationModeByMonitor: {'DP-1': 'sidebar', 'HDMI-A-1': 'classic'}}
host.focusedHyprlandMonitor = {name: 'DP-2'}
let reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.deepEqual(reply.data.modeSwitch, {connector: 'DP-2', from: 'classic', to: 'sidebar'})
assert.deepEqual(plain(host.settings.presentationModeByMonitor), {
  'DP-1': 'sidebar', 'DP-2': 'sidebar', 'HDMI-A-1': 'classic'
})
assert.equal(writes.length, 1)
assert.equal(reply.data.persisted, true)

reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.equal(reply.data.modeSwitch.to, 'classic')
assert.equal(host.settings.presentationModeByMonitor['DP-1'], 'sidebar')
assert.equal(host.settings.presentationModeByMonitor['DP-2'], 'classic')
assert.equal(writes.length, 2)

host.focusedHyprlandMonitor = {name: 'DP-1'}
reply = request('mode.toggle')
assert.equal(reply.ok, true)
assert.equal(host.settings.presentationModeByMonitor['DP-1'], 'classic')
assert.equal(host.settings.presentationModeByMonitor['DP-2'], 'classic')
assert.equal(host.settings.presentationModeByMonitor['HDMI-A-1'], 'classic')
assert.equal(writes.length, 3)

host.focusedHyprlandMonitor = null
reply = request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_RUNTIME_NOT_FOUND')
assert.equal(writes.length, 3, 'missing focus must never select a fallback screen')

host.focusedHyprlandMonitor = {name: 'DP-404'}
reply = request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_STALE')
assert.equal(writes.length, 3, 'disconnected output must not mutate state')

// A hotplug can update Hyprland before Quickshell removes the old screen.
host.focusedHyprlandMonitor = {name: 'DP-2'}
host.hyprMonitors = [{name: 'DP-1', x: 0}]
reply = request('mode.toggle')
assert.equal(reply.error.code, 'E_STALE')
assert.equal(writes.length, 3, 'stale Quickshell screen must not be targeted')
host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
reply = request('mode.toggle')
assert.equal(reply.ok, true, 'reconnected monitor can toggle again')
assert.equal(reply.data.modeSwitch.connector, 'DP-2')
assert.equal(writes.length, 4)

reply = request('mode.toggle', {connector: 'DP-1'})
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_USAGE')
assert.equal(writes.length, 4, 'IPC cannot inject the monitor target')

const pending = hostHarness({})
pending.host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
pending.host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
pending.host.sidebarState = {mappedScreens: pending.host.connectedScreens, interactionBusy: false}
pending.host.focusedHyprlandMonitor = {name: 'DP-1'}
pending.fault.defer = true
reply = pending.request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_BUSY')
assert.equal(reply.data.applied, true)
assert.equal(reply.data.persisted, false)
assert.equal(pending.writes.length, 1)
reply = pending.request('mode.toggle')
assert.equal(reply.error.code, 'E_BUSY')
assert.equal(reply.data.modeSwitch, undefined, 'rejected intent must not claim a switch')
assert.equal(pending.writes.length, 1, 'repeated shortcut is rejected while saving')
pending.host.settingsSaveFailed(3)
assert.match(pending.host.modeGestureDisplayFor('DP-1'), /Unsaved preferences/)
assert.equal(pending.host.modeGestureDisplayFor('DP-2'), '',
  'late persistence failure must stay scoped to the originating monitor')

const failed = hostHarness({})
failed.host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
failed.host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
failed.host.sidebarState = {mappedScreens: failed.host.connectedScreens, interactionBusy: false}
failed.host.focusedHyprlandMonitor = {name: 'DP-1'}
failed.fault.save = true
reply = failed.request('mode.toggle')
assert.equal(reply.ok, false)
assert.equal(reply.error.code, 'E_PERSISTENCE')
assert.equal(reply.data.persisted, false)
assert.match(failed.host.modeGestureDisplayFor('DP-1'), /Unsaved preferences/)
assert.equal(failed.host.modeGestureDisplayFor('DP-2'), '',
  'shortcut save failure must not show on other monitors')

// Historical switch behavior: malformed/disconnected entries normalize away,
 // rather than blocking unrelated monitor operations. Raw expected values still
 // participate in the writer's stale-state comparison.
const legacy = hostHarness({presentationModeByMonitor: {
  'OLD-DP': 'unknown-mode', 'HDMI-A-1': 'classic'
}})
legacy.host.connectedScreens = [{name: 'DP-1'}]
legacy.host.hyprMonitors = [{name: 'DP-1', x: 0}]
legacy.host.focusedHyprlandMonitor = {name: 'DP-1'}
reply = legacy.request('mode.toggle')
assert.equal(reply.ok, true)
assert.deepEqual(plain(legacy.host.settings.presentationModeByMonitor), {
  'HDMI-A-1': 'classic', 'DP-1': 'sidebar'
})
assert.equal(legacy.writes.length, 1)

for (const malformed of [null, []]) {
  const invalid = hostHarness({presentationModeByMonitor: malformed})
  invalid.host.connectedScreens = [{name: 'DP-1'}]
  invalid.host.hyprMonitors = [{name: 'DP-1', x: 0}]
  invalid.host.focusedHyprlandMonitor = {name: 'DP-1'}
  reply = invalid.request('mode.toggle')
  assert.equal(reply.ok, true, 'invalid map must use the historical empty fallback')
  assert.deepEqual(plain(invalid.host.settings.presentationModeByMonitor), {'DP-1': 'sidebar'})
  assert.equal(invalid.writes.length, 1)
}
// A sidebar inherited from the global default may be intentionally unmapped
// by the legacy sidebarMonitor pin. The first toggle must reveal it, not dock it.
const pinned = hostHarness({presentationMode: 'sidebar', sidebarMonitor: 'DP-1'})
pinned.host.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
pinned.host.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
pinned.host.focusedHyprlandMonitor = {name: 'DP-2'}
assert.equal(pinned.host.currentPresentation().entries.find(e => e.connector === 'DP-2').mapped, false)
reply = pinned.request('mode.toggle')
assert.equal(reply.ok, true)
assert.deepEqual(reply.data.modeSwitch, {connector: 'DP-2', from: 'unmapped', to: 'sidebar'})
assert.deepEqual(plain(pinned.host.settings.presentationModeByMonitor), {'DP-2': 'sidebar'})
assert.equal(pinned.host.settings.sidebarMonitor, 'DP-1', 'legacy pin is unchanged')
assert.deepEqual(plain(pinned.host.currentPresentation().sidebarScreens.map(s => s.name).sort()),
  ['DP-1', 'DP-2'])
reply = pinned.request('mode.toggle')
assert.equal(reply.ok, true)
assert.deepEqual(reply.data.modeSwitch, {connector: 'DP-2', from: 'sidebar', to: 'classic'})
assert.equal(pinned.host.currentPresentation().entries.find(e => e.connector === 'DP-1').mode, 'sidebar')
assert.equal(pinned.writes.length, 2)

const solo = hostHarness({})
solo.host.connectedScreens = [{name: 'eDP-1'}]
solo.host.hyprMonitors = [{name: 'eDP-1'}]
solo.host.focusedHyprlandMonitor = {name: 'eDP-1'}
assert.equal(solo.request('mode.toggle').data.modeSwitch.to, 'sidebar')
assert.equal(solo.request('mode.toggle').data.modeSwitch.to, 'classic')
assert.equal(solo.writes.length, 2)

// The sidebar controller executes membership reconciliation while one panel
// owns a row drag. A foreign panel entering/leaving must not abort that drag,
// but removal of the origin panel must still cancel it.
function membershipChange(previous, overrides, origin) {
  const screens = [{name: 'DP-1'}, {name: 'DP-2'}]
  const controller = qmlMethods('DockSidebarController.qml', {
    DockModel: loadModel('DockModel'),
    SidebarModel: loadModel('DockSidebarModel'),
    ScreenPresentationModel: loadModel('DockScreenPresentationModel'),
    screens, monitors: [{name: 'DP-1'}, {name: 'DP-2'}],
    mappedScreens: screens.filter(s => previous.includes(s.name)),
    selectedScreen: screens[0], registry: {nextToken: 1, entries: []}, toplevels: [],
    settings: {presentationMode: 'classic', presentationModeByMonitor: overrides,
      sidebarMonitor: '', workspaceMonitorOrder: []},
    dragSession: {connector: origin}, interactionBusy: true, resizeActive: false,
    refreshPending: false
  })
  let cancellations = 0
  controller.rowDragIsCurrent = () => true
  controller.cancelRowDrag = () => { cancellations++; controller.dragSession = null }
  controller.syncWidgets = () => {}
  controller.refreshBody()
  return {controller, cancellations}
}
let membership = membershipChange(['DP-1'],
  {'DP-1': 'sidebar', 'DP-2': 'sidebar'}, 'DP-1')
assert.equal(membership.cancellations, 0, 'adding DP-2 must not cancel DP-1 drag')
assert.equal(membership.controller.dragSession.connector, 'DP-1')
assert.deepEqual(plain(membership.controller.mappedScreens.map(s => s.name)), ['DP-1', 'DP-2'])
assert.equal(membership.controller.refreshPending, true, 'busy projection stays deferred')

membership = membershipChange(['DP-1', 'DP-2'],
  {'DP-1': 'sidebar', 'DP-2': 'classic'}, 'DP-1')
assert.equal(membership.cancellations, 0, 'removing DP-2 must not cancel DP-1 drag')
assert.equal(membership.controller.dragSession.connector, 'DP-1')

membership = membershipChange(['DP-1', 'DP-2'],
  {'DP-1': 'classic', 'DP-2': 'sidebar'}, 'DP-1')
assert.equal(membership.cancellations, 1, 'removing the origin sidebar must cancel its drag')
assert.equal(membership.controller.dragSession, null)
console.log('focused monitor mode toggle and sidebar membership isolation: PASS')
