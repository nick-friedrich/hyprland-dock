import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'

// Task 4 (classic dock) target policy. The classic components import Quickshell
// and create popups, so they cannot be instantiated by the offscreen QML
// runner. This harness executes the real QML method bodies with substituted
// compositor/transport state, exactly like tests/test_grouped_actions.mjs, and
// additionally evaluates the real binding expressions that select targets.
// It does not qualify rendering, focus dispatch, or the native drag route.

const read = name => fs.readFileSync(new URL(`../components/${name}`, import.meta.url), 'utf8')
function model(name, imports = {}) {
  const scope = vm.createContext(imports)
  vm.runInContext(read(name).replace(/^\.(pragma|import).*$/gm, ''), scope)
  return scope
}
function methods(file, properties) {
  const scope = vm.createContext(properties)
  scope.root = scope
  const bodies = read(file).match(/^  function [\s\S]*?^  }/gm) || []
  vm.runInContext(bodies.join('\n'), scope, { filename: file })
  return scope
}
const DockModel = model('DockModel.js')
const DockWindowModel = model('DockWindowModel.js', { DockModel })
const PreviewModel = model('DockWindowPreviewModel.js', { DockWindowModel })

let launches = 0
let closes = 0
let minimizes = 0
let pulls = 0
const actions = {
  // Real DockWindowActions resolves the address from a live handle, so a dead
  // toplevel yields no address and therefore no target.
  addressFor(toplevel) {
    return toplevel && toplevel.alive !== false && toplevel.address
      ? toplevel.address : ''
  },
  isAlive(toplevel) { return !!toplevel && toplevel.alive !== false },
  launch() { launches++ },
  closeToplevels() { closes++; return true },
  minimizeRestoreToplevels() { minimizes++; return true },
  pullToplevelToMonitorWorkspace() { pulls++; return true }
}

// --- DockItem: one window / preview / workspace fallback ---------------------
const item = methods('DockItem.qml', {
  windowActions: actions, presentationActive: true, presentationVisible: true,
  workspaceInputSuppressed: false, runningCount: 0, runningToplevels: [],
  showPreviews: true, presentationId: 'chrome', navigation: {},
  workspaceActivationTarget: '', localWorkspaceIdentity: '',
  contextMenu: { visible: false }
})
item.representedWorkspaceIdentity = ''
item.externalEligible = false
assert.equal(item.externalDragTarget(), null, 'zero-window launcher is not a target')

item.runningCount = 1
item.runningToplevels = [{ address: '0x10' }]
item.externalEligible = true
let target = item.externalDragTarget()
assert.equal(target.kind, 'window')
assert.equal(target.key, 'window:0x10')
assert.equal(target.toplevel, item.runningToplevels[0])
assert.ok(target.anchor && target.anchor.presentationId === 'chrome',
  'the icon is the preview/group anchor')
assert.equal(launches + closes + minimizes + pulls, 0,
  'resolving a hover target never launches, closes, minimizes or moves')

// A one-window icon stays a window target even when it has preview agents.
item.showPreviews = true
assert.equal(item.externalDragTarget().kind, 'window')

// Several windows with previews enabled: the existing preview owns selection.
item.runningCount = 3
item.runningToplevels = [{ address: '0x10' }, { address: '0x11' }, { address: '0x12' }]
target = item.externalDragTarget()
assert.equal(target.kind, 'preview')
assert.equal(target.key, 'preview:chrome')
assert.ok(target.anchor, 'the icon is the anchor')

// Preview disabled: reveal the represented workspace, never application-wide
// membership and never a focus-derived pick.
item.showPreviews = false
// The binding expression is asserted separately below; the method consumes
// the resolved identity, matching production call order.
item.representedWorkspaceIdentity = '3'
assert.equal(item.externalDragTarget().kind, 'workspace')
assert.equal(item.externalDragTarget().workspaceIdentity, '3')
assert.equal(item.externalDragTarget().key, 'workspace:3')

item.representedWorkspaceIdentity = 'id:7'
assert.equal(item.externalDragTarget().workspaceIdentity, 'id:7')
assert.equal(item.externalDragTarget().key, 'workspace:id:7')

// Unresolved workspace identity is ineligible for workspace-only navigation.
item.representedWorkspaceIdentity = ''
assert.equal(item.externalDragTarget(), null)
item.representedWorkspaceIdentity = 'name:Work'
assert.equal(item.externalDragTarget().workspaceIdentity, 'name:Work')

// Inactive, clipped or suppressed icons are never targets. externalEligible is
// the production binding over these inputs; its expression is asserted below.
item.externalEligible = false
assert.equal(item.externalDragTarget(), null, 'ineligible icons never resolve')
item.externalEligible = true
assert.ok(item.externalDragTarget(), 'restored eligibility resolves again')

const eligibility = read('DockItem.qml').match(
  /readonly property bool externalEligible:([\s\S]*?)\n\n/)
assert.ok(eligibility, 'DockItem keeps an explicit external eligibility rule')
function eligible(scope) {
  const context = vm.createContext(scope)
  context.root = context
  return vm.runInContext('(' + eligibility[1] + ')', context)
}
assert.equal(eligible({ navigation: {}, presentationActive: true,
  presentationVisible: true, workspaceInputSuppressed: false,
  contextMenu: { visible: false }, runningCount: 2 }), true)
for (const [key, value] of [['navigation', null], ['presentationActive', false],
  ['presentationVisible', false], ['workspaceInputSuppressed', true],
  ['runningCount', 0]]) {
  const state = { navigation: {}, presentationActive: true,
    presentationVisible: true, workspaceInputSuppressed: false,
    contextMenu: { visible: false }, runningCount: 2 }
  state[key] = value
  if (key === 'contextMenu') state.contextMenu = value
  assert.equal(eligible(state), false, key)
}
assert.equal(eligible({ navigation: {}, presentationActive: true,
  presentationVisible: true, workspaceInputSuppressed: false,
  contextMenu: { visible: true }, runningCount: 2 }), false,
  'an open context menu suppresses external navigation')

// --- The represented workspace binding -------------------------------------
function representedExpression() {
  const source = read('DockItem.qml')
  const block = source.match(
    /readonly property string representedWorkspaceIdentity: \{([\s\S]*?)\n  \}/)
  assert.ok(block, 'DockItem exposes the represented workspace identity')
  return block[1]
}
function represented(scope) {
  const context = vm.createContext(scope)
  context.root = context
  return vm.runInContext('(function () {' + representedExpression() + '})()', context)
}
assert.equal(represented({ workspaceActivationTarget: '4', localWorkspaceIdentity: 'id:9' }),
  '4', 'grouped cards use the owning card identity')
assert.equal(represented({ workspaceActivationTarget: '', localWorkspaceIdentity: 'id:9' }),
  'id:9', 'flat icons use their own workspace identity')
assert.equal(represented({ workspaceActivationTarget: '', localWorkspaceIdentity: '' }), '')

// --- DockWindowPreviewTile: exact live window ------------------------------
const tile = methods('DockWindowPreviewTile.qml', {
  windowActions: actions, navigation: {}, toplevel: { address: '0x21' }
})
tile.externalEligible = true
target = tile.externalDragTarget()
assert.equal(target.kind, 'window')
assert.equal(target.key, 'window:0x21')
assert.equal(target.toplevel, tile.toplevel)
assert.ok(target.anchor, 'the tile is the anchor')
tile.toplevel = { address: '0x21', alive: false }
assert.equal(tile.externalDragTarget(), null, 'a closed member fails closed')
tile.navigation = null
tile.toplevel = { address: '0x22' }
tile.externalEligible = false
assert.equal(tile.externalDragTarget(), null, 'no coordinator means no target')

// --- DockWorkspaceGroup: card header ---------------------------------------
const group = methods('DockWorkspaceGroup.qml', {
  navigation: {}, switchable: true, presentationVisible: true,
  workspaceIdentity: 'id:3', headerInputSuppressed: false
})
group.externalEligible = true
target = group.externalDragTarget()
assert.equal(target.kind, 'workspace')
assert.equal(target.key, 'workspace:id:3')
assert.equal(target.workspaceIdentity, 'id:3')
assert.ok(target.anchor, 'the card header is the anchor')
for (const [key, value] of [['switchable', false], ['presentationVisible', false],
  ['headerInputSuppressed', true], ['workspaceIdentity', '']]) {
  const previous = group[key]
  group[key] = value
  group.externalEligible = false
  assert.equal(group.externalDragTarget(), null, key)
  group[key] = previous
  group.externalEligible = true
}

// --- DockWorkspaceStrip: flat cell -----------------------------------------
const strip = methods('DockWorkspaceStrip.qml', { navigation: {} })
target = strip.externalDragDescriptor(4, true)
assert.equal(target.kind, 'workspace')
assert.equal(target.key, 'workspace:id:4')
assert.equal(target.workspaceIdentity, 'id:4')
assert.equal(strip.externalDragDescriptor(4, false), null,
  'a retained removal slot is not a target')
strip.navigation = null
assert.equal(strip.externalDragDescriptor(4, true), null)

// --- Dock: preview request routing and stale-anchor guard -------------------
// The vm global object is the production `root`; functions compare against it
// by identity, so owner-scoped routing must be called with that exact object.
function rootOf(scope) { return vm.runInContext('root', scope) }
function dockMethods(properties) {
  const scope = methods('Dock.qml', Object.assign({
    PreviewModel, shownPreviewRequests: []
  }, properties))
  scope.requestExternalPreview = scope.requestExternalPreview
  return scope
}
function previewDock(items, shown, anchor) {
  const dock = dockMethods({
    renderedItems: items,
    showPreviews: true,
    windowPreview: {
      requestDragPreview(anchorItem, desktopId, toplevels, entry) {
        dock.shownPreviewRequests.push({ anchorItem, desktopId, toplevels, entry })
        return true
      }
    },
    anchor: anchor
  })
  dock.showPreviews = shown
  return dock
}
const anchor = {
  presentationId: 'id:1/chrome', identityToplevel: null, desktopId: 'chrome',
  runningToplevels: [{}, {}], entry: { name: 'Chrome' }
}
const rendered = [{ presentationId: 'id:1/chrome', identityToplevel: null, desktopId: 'chrome' }]
let dock = previewDock(rendered, true, anchor)
let owner = rootOf(dock)
assert.equal(dock.requestExternalPreview(owner, 'preview:id:1/chrome', anchor), true)
assert.equal(dock.shownPreviewRequests.length, 1)
assert.equal(dock.shownPreviewRequests[0].anchorItem, anchor)
assert.equal(dock.shownPreviewRequests[0].toplevels, anchor.runningToplevels)
assert.equal(dock.shownPreviewRequests[0].entry, anchor.entry)

// Another dock owner never opens this dock's popup.
assert.equal(dock.requestExternalPreview({}, 'preview:id:1/chrome', anchor), false)
// A key that does not describe the anchor is stale.
assert.equal(dock.requestExternalPreview(owner, 'preview:id:2/chrome', anchor), false)
// A retained removal slot is no longer in the rendered set.
dock = previewDock([{ presentationId: 'id:2/chrome', identityToplevel: null }], true, anchor)
owner = rootOf(dock)
assert.equal(dock.requestExternalPreview(owner, 'preview:id:1/chrome', anchor), false)
// Live previews disabled: the icon resolves a workspace target instead.
dock = previewDock(rendered, false, anchor)
owner = rootOf(dock)
assert.equal(dock.requestExternalPreview(owner, 'preview:id:1/chrome', anchor), false)
// A sibling icon with the same presentation id but another identity window is
// not this anchor's target.
const identityWindow = {}
const otherAnchor = Object.assign({}, anchor, { identityToplevel: identityWindow })
dock = previewDock([{ presentationId: 'id:1/chrome',
  identityToplevel: identityWindow, desktopId: 'chrome' }], true, otherAnchor)
owner = rootOf(dock)
assert.equal(dock.requestExternalPreview(owner, 'preview:id:1/chrome', otherAnchor), true)
assert.equal(dock.shownPreviewRequests.length, 1)

// --- DockWindowPreview: drag request opens immediately ---------------------
const preview = methods('DockWindowPreview.qml', {
  PreviewModel,
  ActivityModel: { presentation: () => ({ rows: [], total: 0 }) },
  ToplevelManager: { toplevels: { values: [] } },
  visible: false,
  anchorItem: null,
  anchorHovered: false,
  visibleItems: [],
  presentationId: '',
  identityToplevel: null,
  desktopId: '',
  members: [],
  agentRows: [],
  herdrOnly: false,
  herdrCounters: [],
  dragSession: false,
  externalDragActive: false,
  externalDragGrace: false,
  clipItem: null,
  originOnly: false,
  windowOverrideSource: '',
  applicationEntry: null,
  herdrLabel: '',
  herdrProduct: 'Herdr',
  herdrFocusHint: '',
  openTimer: { running: false, stop() { this.running = false }, restart() { this.running = true } },
  closeTimer: { running: false, stop() { this.running = false }, restart() { this.running = true } },
  handoffTimer: { running: false, stop() { this.running = false }, restart() { this.running = true } },
  anchor: { window: null },
  Qt: { callLater: fn => fn() },
  reanchor() {}
})
const previewAnchor = {
  presentationId: 'multi', identityToplevel: null, desktopId: 'multi',
  previewActivities: [], previewAgents: [], previewHerdrOnly: false,
  previewHerdrLabel: '', previewHerdrProduct: 'Herdr',
  previewHerdrCounters: [], windowOverrideSource: '', originOnly: false
}
const members = [{ title: 'A' }, { title: 'B' }]
// Compositor membership is substituted; the session policy still runs.
preview.liveMembers = values => values
assert.equal(preview.requestDragPreview(previewAnchor, 'multi', members, { name: 'Multi' }), true)
assert.equal(preview.dragSession, true)
assert.equal(preview.visible, true, 'the dwell already elapsed; no second 220 ms delay')
assert.equal(preview.openTimer.running, false, 'the ordinary open timer is not used')
assert.equal(preview.members.length, 2)
assert.equal(preview.presentationId, 'multi')

// An ineligible drag request leaves no drag session behind.
const preview2 = methods('DockWindowPreview.qml', {
  PreviewModel,
  ActivityModel: { presentation: () => ({ rows: [], total: 0 }) },
  ToplevelManager: { toplevels: { values: [] } },
  visible: false, anchorItem: null, anchorHovered: false, visibleItems: [],
  presentationId: '', identityToplevel: null, desktopId: '', members: [],
  agentRows: [], herdrOnly: false, herdrCounters: [], dragSession: false,
  externalDragActive: false, externalDragGrace: false, clipItem: null,
  originOnly: false, windowOverrideSource: '', applicationEntry: null,
  herdrLabel: '', herdrProduct: 'Herdr', herdrFocusHint: '',
  openTimer: { running: false, stop() {}, restart() { this.running = true } },
  closeTimer: { running: false, stop() {}, restart() { this.running = true } },
  handoffTimer: { running: false, stop() {}, restart() {} },
  anchor: { window: null },
  Qt: { callLater: fn => fn() }, reanchor() {}
})
preview2.liveMembers = values => values
assert.equal(preview2.requestDragPreview(previewAnchor, 'multi', [], {}), false,
  'a stale single-window group does not open a drag preview')
assert.equal(preview2.dragSession, false)

// --- Real binding expressions ---------------------------------------------
const previewSource = read('DockWindowPreview.qml')
const showExpression = previewSource.match(
  /readonly property bool showWindowPreviews:\n    ([^\n]+)/)
assert.ok(showExpression, 'DockWindowPreview keeps an explicit tile-visibility rule')
function showWindowPreviews(scope) {
  const context = vm.createContext(scope)
  context.root = context
  return vm.runInContext('(' + showExpression[1] + ')', context)
}
assert.equal(showWindowPreviews({ members: [{}, {}], herdrOnly: false, dragSession: false }), true)
assert.equal(showWindowPreviews({ members: [{}, {}], herdrOnly: true, dragSession: false }), false,
  'ordinary agent-only presentation suppresses window tiles')
assert.equal(showWindowPreviews({ members: [{}, {}], herdrOnly: true, dragSession: true }), true,
  'a drag session still exposes exact tiles')
assert.equal(showWindowPreviews({ members: [{}], herdrOnly: false, dragSession: true }), false)

// --- Structural contract --------------------------------------------------
const dockSource = read('Dock.qml')
const itemSource = read('DockItem.qml')
const groupSource = read('DockWorkspaceGroup.qml')
const stripSource = read('DockWorkspaceStrip.qml')
const tileSource = read('DockWindowPreviewTile.qml')

assert.match(dockSource, /kind: "reveal"/, 'the classic dock owns reveal holds')
assert.match(dockSource, /passive: true/, 'the enclosing dock hold is passive')
assert.match(dockSource, /id: revealStripDrag/)
assert.match(dockSource, /id: dockSurfaceDrag/)
assert.match(dockSource, /externalDragNavigation\.heldFor\(root\)|heldFor\(root\)/,
  'visibility uses the coordinator owner hold')
assert.match(dockSource, /externalDragHeld === true/)
assert.match(dockSource, /externalDragNavigation\.cancelOwner\(root\)/,
  'surface destruction releases drag state')
assert.match(dockSource, /root\.requestExternalPreview\(owner, key, anchor\)/)
assert.doesNotMatch(dockSource, /getData|mimeData|hasUrls|hasText/,
  'navigation never reads drag payloads')
assert.equal((dockSource.match(/DockWindowPreview\s*\{/g) || []).length, 1,
  'one preview popup')

for (const source of [itemSource, groupSource, stripSource, tileSource]) {
  assert.match(source, /DockExternalDragArea\s*\{/)
  assert.doesNotMatch(source, /getData|mimeData|hasUrls|hasText/)
}
assert.match(itemSource, /kind: "preview"/)
assert.match(itemSource, /kind: "workspace"/)
assert.match(tileSource, /anchors\.rightMargin: closeButton\.width \+ 10/,
  'destructive tile controls stay outside the drag target')

console.log('external drag classic target policy: OK')
