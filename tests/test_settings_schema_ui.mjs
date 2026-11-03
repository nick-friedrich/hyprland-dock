import assert from 'node:assert/strict';
import { read, loadModel, hostHarness, plain } from './host_harness.mjs';

const settings = JSON.parse(read('config/settings-schema.json')).settings;
const keys = Object.keys(settings);
assert.equal(keys.length, 62);
const ui = Object.fromEntries(keys.map(key => [key, settings[key].ui]));
const allowedSections = new Set(['appearance', 'layout', 'behavior', 'sidebar-widgets', 'apps']);
const allowedVisibility = new Set(['normal', 'conditional', 'advanced', 'hidden', 'in-place']);
for (const key of keys) {
  const row = ui[key];
  assert.ok(row && typeof row === 'object', key + ': missing ui');
  assert.ok(allowedSections.has(row.section), key + ': missing canonical section');
  assert.ok(row.group && typeof row.group === 'string', key + ': missing group');
  assert.ok(Number.isInteger(row.order), key + ': missing order');
  assert.ok(row.label && row.help && row.control, key + ': missing visible metadata');
  assert.ok(['classic', 'sidebar', 'all'].includes(row.surface), key + ': invalid surface');
  assert.ok(allowedVisibility.has(row.visibility), key + ': invalid visibility');
  if (['hidden', 'in-place'].includes(row.visibility))
    assert.ok(row.reason, key + ': hidden/in-place setting must explain its editor');
  for (const required of Object.keys(row.requires || {}))
    assert.ok(keys.includes(required), key + ': invalid requires key ' + required);
  if (row.pairedWith) {
    assert.ok(keys.includes(row.pairedWith), key + ': invalid pair');
    assert.equal(ui[row.pairedWith].pairedWith, key, key + ': asymmetric pair');
  }
}
const classic = keys.filter(key => ui[key].surface === 'classic');
const metadata = loadModel('DockModel');
assert.deepEqual(plain(metadata.inactiveClassicSettings(true)).sort(), classic.slice().sort());
assert.deepEqual(plain(metadata.inactiveClassicSettings(false)), []);
assert.ok(classic.includes('dockHerdrIndicators'), 'Herdr terminal icon state is classic-only');
assert.ok(classic.includes('dockT3Indicators'), 'T3 dock icon state is classic-only');
assert.equal(ui.dockT3Indicators.surface, 'classic');
assert.equal(ui.dockT3Indicators.group, 'attention-on-the-dock');
assert.ok(!classic.includes('dockClaudeIndicators'), 'Claude Desktop state also drives the sidebar window row');
assert.equal(ui.dockClaudeIndicators.surface, 'all');
assert.equal(ui.dockClaudeIndicators.group, 'attention');
const host = hostHarness({ presentationMode: 'sidebar' });
assert.deepEqual(plain(host.control.statusData().presentation.inactiveClassicSettings).sort(),
                 classic.slice().sort(), 'the real host projection must use the same inventory');
const grouped = Object.entries(ui).filter(([, row]) => row.feature && row.feature.keys);
assert.deepEqual(grouped.map(([key]) => key).sort(),
                 ['browserProfileBadgesEnabled', 'launcherBadgeMode', 'sidebarWidgets']);
for (const [owner, row] of grouped) {
  assert.ok(row.feature.keys.includes(owner));
  for (const key of row.feature.keys)
    assert.ok(keys.includes(key), 'feature aggregate references non-canonical key ' + key);
}
assert.equal(ui.sidebarBrowserTabsEnabled.section, 'apps');
assert.equal(ui.sidebarInlineSoloWorkspace.section, 'layout');
assert.equal(ui.workspaceMonitorOrder.group, 'displays');
assert.equal(ui.dragHoverNavigationEnabled.section, 'behavior');
assert.equal(ui.dragHoverNavigationEnabled.group, 'windows');
assert.equal(ui.dragHoverNavigationEnabled.surface, 'all');
assert.equal(ui.dragHoverNavigationEnabled.control, 'toggle');
assert.equal(ui.dragHoverDelayMs.section, 'behavior');
assert.equal(ui.dragHoverDelayMs.group, 'windows');
assert.equal(ui.dragHoverDelayMs.surface, 'all');
assert.equal(ui.dragHoverDelayMs.control, 'slider');
assert.equal(ui.dragHoverDelayMs.unit, 'ms');
assert.deepEqual(plain(ui.dragHoverDelayMs.requires),
                 { dragHoverNavigationEnabled: true });
assert.equal(settings.dragHoverNavigationEnabled.type, 'boolean');
assert.equal(settings.dragHoverDelayMs.type, 'integer');
assert.equal(settings.dragHoverDelayMs.minimum, 100);
assert.equal(settings.dragHoverDelayMs.maximum, 2000);
assert.equal(settings.dragHoverDelayMs.effectiveStep, 100);
assert.ok(!classic.includes('dragHoverNavigationEnabled'),
  'external drag navigation applies to both presentations');
assert.ok(!classic.includes('dragHoverDelayMs'),
  'the drag hover delay applies to both presentations');
assert.equal(ui.position.visibility, 'hidden');
assert.equal(ui.sidebarMonitor.visibility, 'hidden');
assert.equal(ui.sidebarWidgetCollapsed.visibility, 'in-place');
assert.equal(ui.controlCommand.visibility, 'advanced');
assert.equal(ui.controlCommand.commit, 'explicit');
assert.equal(ui.margin.uiMaximum, 64);
assert.deepEqual(ui.clickAction.destructiveOptions, ['close']);
const widgetModel = loadModel('DockSidebarWidgetModel');
const rows = plain(widgetModel.registeredRows({
  'herdr.agents': {id:'herdr.agents', label:'Coding agents',
                  description:'Show agent sessions', feature:'herdr', acquire() {} }
}));
assert.equal(rows[0].feature, 'herdr');
assert.equal(rows[0].description, 'Show agent sessions');
console.log('Settings metadata: 62 schema keys, paired controls, host classic projection and shortcuts OK');
