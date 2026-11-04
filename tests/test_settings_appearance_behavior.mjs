import assert from 'node:assert/strict'
import {loadModel,read,hostHarness,plain} from './host_harness.mjs'

const pair=loadModel('DockSettingsPairModel')
const registry=loadModel('DockSettingsRegistry')
const metadata=JSON.parse(read('config/settings-schema.json'))
const groups=['icons','hover-glow','dock-surface','workspace-badges','motion']
const appearance=plain(registry.sectionRows(metadata,'appearance'))
  .filter(row=>row.ui.visibility==='normal')
assert.deepEqual([...new Set(appearance.map(row=>row.ui.group))],groups)
assert.equal(appearance.filter(row=>row.ui.pairedWith).length,5)
assert.equal(registry.sectionRows(metadata,'behavior').find(row=>row.key==='groupWindows').ui.visibility,'hidden')
assert.equal(registry.editability(
  metadata.settings.hoverGlowOpacity.ui, {hoverGlowEnabled:false},1).enabled,false)
assert.equal(registry.editability(
  metadata.settings.hoverGlowOpacity.ui, {hoverGlowEnabled:true},1).enabled,true)
assert.equal(registry.editability(
  metadata.settings.dragHoverDelayMs.ui, {dragHoverNavigationEnabled:false},1).enabled,false,
  'drag hover delay is dimmed while external drag navigation is off')
assert.equal(registry.editability(
  metadata.settings.dragHoverDelayMs.ui, {dragHoverNavigationEnabled:true},1).enabled,true)
assert.equal(metadata.settings.dragHoverNavigationEnabled.ui.surface,'all')
assert.equal(metadata.settings.dragHoverDelayMs.ui.surface,'all')
const sidebarHost=hostHarness({presentationMode:'sidebar'})
const sidebarEffective=sidebarHost.request('config.get',{effective:true}).data.settings
assert.equal(sidebarEffective.dragHoverNavigationEnabled,true,
  'drag navigation stays applicable on a sidebar-only desktop')
assert.equal(sidebarEffective.dragHoverDelayMs,500)
assert.equal(sidebarEffective.showPreviews,false,
  'preview applicability is unchanged by the drag controls')
assert.match(read('components/DockSettingsGeneralSection.qml'),/modelData\.rows\.every/,
  'Behavior card applicability derives from mixed row surfaces')
assert.deepEqual(plain(pair.colorOptions()).map(x=>x.value).slice(0,2),['default','@accent'])
assert.equal(pair.validHex('#aBcDEF'),true)
assert.equal(pair.validHex('#12345678'),true)
assert.equal(pair.validHex('@accent'),false)
assert.equal(pair.validHex('red'),false)
const h=hostHarness({presentationMode:'classic'})
for (const [key, enabledKey, value] of [
  ['backgroundColor','backgroundColorEnabled','#8899AA'],
  ['borderColor','borderColorEnabled','@accent'],
  ['workspaceBadgeBackgroundColor','workspaceBadgeBackgroundColorEnabled','#112233'],
  ['workspaceBadgeTextColor','workspaceBadgeTextColorEnabled','@foreground'],
  ['borderWidth','borderWidthEnabled',4]
]) {
  const expected=pair.pairExpected(key,enabledKey,h.host.settings[key],h.host.settings[enabledKey])
  const patch=pair.pairPatch(key,enabledKey,value,true)
  const before=h.writes.length
  const applied=h.host.saveSettingsIntent(patch,expected)
  assert.equal(applied.accepted,true,key+': expected atomic host acceptance')
  assert.equal(h.writes.length,before+1,key+': exactly one writer transaction')
  assert.equal(h.host.settings[key],value)
  assert.equal(h.host.settings[enabledKey],true)
  const stale=h.host.saveSettingsIntent(pair.pairPatch(key,enabledKey,'#112233',false),expected)
  assert.equal(stale.reply.error.code,'E_STALE',key+': stale pair rejected')
  const beforeDefault=h.writes.length
  const reset=h.host.saveSettingsIntent(pair.pairPatch(key,enabledKey,value,false),
    pair.pairExpected(key,enabledKey,value,true))
  assert.equal(reset.accepted,true)
  assert.equal(h.writes.length,beforeDefault+1,key+': Theme default is one patch')
  assert.equal(h.host.settings[enabledKey],false)
  assert.equal(h.host.settings[key],value,'Theme default preserves the requested color/width')
}
const row=read('components/DockSettingsRow.qml')
const section=read('components/DockSettingsGeneralSection.qml')
const pairQml=read('components/DockSettingsPairedRow.qml')
const shell=read('components/DockSettingsPanel.qml')
assert.match(row,/destructiveOptions/, 'native click dropdown marks destructive choices')
assert.match(section,/DockSettingsRow/, 'ordinary rows use the canonical schema control')
assert.match(section,/DockSettingsPairedRow/, 'paired values have one visible editor')
assert.match(pairQml,/saveSettingsIntent\(patch,expected\)/, 'paired control uses the host writer')
assert.match(pairQml,/interval: 400/, 'keyboard slider edits debounce')
assert.match(shell,/id: appearanceSection/)
assert.match(shell,/id: behaviorSection/)
assert.match(section,/Color\.foreground/, 'help text uses semantic foreground in light and dark themes')

function rgb(hex) {return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255)}
function luminance(rgbValue) {
  const c=rgbValue.map(x=>x<=0.04045?x/12.92:((x+0.055)/1.055)**2.4)
  return 0.2126*c[0]+0.7152*c[1]+0.0722*c[2]
}
function contrastRatio(fg,bg,opacity) {
  const a=rgb(fg),b=rgb(bg)
  const blended=a.map((x,i)=>opacity*x+(1-opacity)*b[i])
  const levels=[luminance(blended),luminance(b)]
  return (Math.max(...levels)+0.05)/(Math.min(...levels)+0.05)
}
// Omarchy quattro 4601078 (themes/*/colors.toml), using the dimmest
// 90%-opacity hint foreground on the Settings card background.
for (const theme of [
  {name:'Catppuccin Latte',foreground:'#4c4f69',background:'#eff1f5'},
  {name:'Catppuccin',foreground:'#cdd6f4',background:'#1e1e2e'}
]) {
  assert.ok(contrastRatio(theme.foreground,theme.background,0.9)>=4.5,
    theme.name+': hint text must meet 4.5:1 contrast')
}
assert.match(section,/opacity:0\.9/, 'semantic classic chip hint is readable in light/dark palettes')
assert.match(pairQml,/Ui\.TextField/, 'paired color hex uses native Omarchy text control')
assert.match(pairQml,/Ui\.SearchableDropdown/, 'theme color choices use native searchable dropdown')


assert.equal(registry.displayValue(metadata.settings.hoverGlowOpacity.ui,0.72),'72%')
assert.equal(registry.displayValue(metadata.settings.hoverGlowOpacity.ui,0.7),'70%')
assert.equal(registry.displayValue(metadata.settings.magnification.ui,1.2),'1.20×')
assert.equal(registry.displayValue(metadata.settings.hoverGlowRadius.ui,25),'25px')
assert.match(read('components/DockSettingsRow.qml'),/Registry\.displayValue\(root\.ui, root\.shown\)/,
  'requested versus rendered help reflects schema displayScale')
// Behavior card contract: Pointer, Windows, Attention, Attention on the dock.
const behaviorGroups=plain(registry.sectionRows(metadata,'behavior'))
  .filter(row=>row.ui.visibility==='normal')
const byGroup={}
for (const row of behaviorGroups)
  byGroup[row.ui.group]=Math.min(byGroup[row.ui.group] ?? Infinity,row.ui.order)
assert.deepEqual(Object.keys(byGroup).sort((a,b)=>byGroup[a]-byGroup[b]),
  ['pointer','windows','attention','attention-on-the-dock'])
// Paired reset is one atomic patch carrying both defaults.
for (const [key, enabledKey] of [['backgroundColor','backgroundColorEnabled'],['borderWidth','borderWidthEnabled']]) {
  const h2=hostHarness({presentationMode:'classic'})
  const cur=h2.host.settings[key], curFlag=h2.host.settings[enabledKey]
  const patch=pair.pairPatch(key,enabledKey,
    key==='borderWidth' ? 2 : '',false)
  const reset=h2.host.saveSettingsIntent(patch,
    pair.pairExpected(key,enabledKey,cur,curFlag))
  assert.equal(reset.accepted,true,key+': atomic reset accepted')
  assert.equal(h2.host.settings[key],key==='borderWidth' ? 2 : '')
  assert.equal(h2.host.settings[enabledKey],false)
}
console.log('SET-04 schema sections, dependencies and stale-safe atomic paired writes passed')
