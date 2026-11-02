import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import {hostHarness,loadModel,plain} from './host_harness.mjs'

// Execute the two production Settings methods without parsing child QML markup.
function settingsMethods(state) {
  const source = fs.readFileSync(new URL('../components/DockSettingsLayout.qml', import.meta.url), 'utf8')
  const methods = [...source.matchAll(/^  function (?:report|chooseMonitor)\([^]*?^  }/gm)]
    .map(match => match[0])
  assert.equal(methods.length, 2)
  const context = vm.createContext({console, ...state})
  context.root = context
  vm.runInContext(methods.join('\n'), context, {filename:'DockSettingsLayout.qml'})
  return context
}

const ScreenModel = loadModel('DockScreenPresentationModel')
const Registry = loadModel('DockSettingsRegistry')
const legacyMap = {'DISCONNECTED-1': 'garbage', 'DP-2': 'classic',
  'HDMI-A-1': 'sidebar'}

function fixture(value = legacyMap) {
  const harness = hostHarness({presentationModeByMonitor: value})
  const h = harness.host
  h.connectedScreens = [{name: 'DP-1'}, {name: 'DP-2'}]
  h.hyprMonitors = [{name: 'DP-1', x: 0}, {name: 'DP-2', x: 1920}]
  h.sidebarState = {mappedScreens: h.connectedScreens, interactionBusy: false}
  return harness
}
function token(host, connector = 'DP-1') {
  return ScreenModel.modeGestureToken(host.currentPresentation(),connector)
}
function expectOneWrite(result, mode) {
  assert.equal(result.writes.length, 1)
  assert.deepEqual(plain(result.host.settings.presentationModeByMonitor), {
    'DP-2': 'classic', 'HDMI-A-1': 'sidebar', 'DP-1': mode
  }, 'retain valid foreign/disconnected overrides and normalize only invalid entries')
}

// Menu -> host uses the same validated FileView write as the shortcut.
const menu = fixture()
assert.equal(menu.host.commitMonitorModeMenu('DP-1', 'sidebar', token(menu.host)), '')
expectOneWrite(menu, 'sidebar')

// Drag -> same shared host request (the gesture's captured output identity wins).
const drag = fixture()
const dragFeedback = drag.host.handlePositionRequest('DP-1', 'left', 'bottom', token(drag.host))
assert.equal(dragFeedback, '', 'successful drag returns no error feedback')
expectOneWrite(drag, 'sidebar')

// Settings -> actual DockSettingsLayout method, not a separately implemented writer.
const settings = fixture()
let notifications = 0
const layout = settingsMethods( {
  host: settings.host, Registry, writerBusy:false, feedback:'',
  changed() { notifications++ }
})
assert.equal(layout.chooseMonitor('DP-1','sidebar',token(settings.host)), true)
assert.equal(layout.feedback, '')
assert.equal(notifications,1)
expectOneWrite(settings, 'sidebar')

// Settings reset to inherited/default is likewise able to repair a junk legacy map.
const reset = fixture()
const resetLayout = settingsMethods( {
  host:reset.host,Registry,writerBusy:false,feedback:'',changed(){}
})
assert.equal(resetLayout.chooseMonitor('DP-2','default',token(reset.host,'DP-2')), true)
assert.equal(reset.writes.length,1)
assert.deepEqual(plain(reset.host.settings.presentationModeByMonitor), {
  'HDMI-A-1':'sidebar'
})

// Both null and array corrupted historical map types use the prior empty fallback.
for (const invalid of [null, []]) {
  const menuBad = fixture(invalid)
  assert.equal(menuBad.host.commitMonitorModeMenu('DP-1','sidebar',token(menuBad.host)), '')
  assert.equal(menuBad.writes.length,1)
  assert.deepEqual(plain(menuBad.host.settings.presentationModeByMonitor), {'DP-1':'sidebar'})

  const dragBad = fixture(invalid)
  assert.equal(dragBad.host.handlePositionRequest(
    'DP-1','left','bottom',token(dragBad.host)), '')
  assert.equal(dragBad.writes.length,1)

  const settingsBad = fixture(invalid)
  const layoutBad = settingsMethods({
    host:settingsBad.host,Registry,writerBusy:false,feedback:'',changed(){}
  })
  assert.equal(layoutBad.chooseMonitor('DP-1','sidebar',token(settingsBad.host)),true)
  assert.equal(settingsBad.writes.length,1)
}
console.log('menu, drag, Settings mode-switch regression coverage: PASS')
