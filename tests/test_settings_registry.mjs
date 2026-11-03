import assert from 'node:assert/strict'
import { loadModel, read, plain, hostHarness } from './host_harness.mjs'
const model=loadModel('DockSettingsRegistry')
const metadata=JSON.parse(read('config/settings-schema.json'))
const all=plain(model.registry(metadata))
assert.deepEqual(all.map(s=>s.id),['appearance','layout','behavior','sidebar-widgets','features','apps'])
const homes=all.flatMap(s=>s.rows.map(row=>row.key))
// FDM-1040 froze 58; FDM-1051 slice 3 adds dockT3Indicators and Claude Desktop
// adds dockClaudeIndicators (behavior/attention, shared with dock and sidebar).
// External drag adds dragHoverNavigationEnabled and dragHoverDelayMs.
assert.equal(homes.length,62)
assert.equal(new Set(homes).size,62)
const variants=[
 [1,'flat'],[1,'grouped'],[2,'flat'],[2,'grouped']
]
for(const [n,layout] of variants){
 const groups=plain(model.layoutGroups(metadata,n,layout))
 assert.deepEqual(groups.map(g=>g.id),['displays','sidebar','classic-size-position','classic-hiding','classic-arrange-apps'])
 const keys=groups.flatMap(g=>g.rows.map(row=>row.key))
 assert.ok(keys.includes('presentationModeByMonitor'))
 assert.ok(keys.includes('sidebarInlineSoloWorkspace'))
 assert.ok(keys.includes('workspaceLayout'))
 assert.equal(keys.includes('workspaceMonitorOrder'),n>=2)
 assert.equal(keys.includes('workspaceMonitorScope'),n>=2&&layout==='grouped')
 assert.equal(keys.includes('windowScope'),layout==='flat')
 assert.equal(keys.includes('sortByWorkspace'),layout==='flat')
 assert.equal(keys.includes('groupWindows'),false)
 assert.equal(keys.includes('position'),false)
}
assert.equal(model.openingSection({classicScreens:[]},''),'sidebar-widgets')
assert.equal(model.openingSection({classicScreens:['DP-1']},''),'appearance')
assert.equal(model.openingSection({classicScreens:['DP-1']},'layout'),'layout')
assert.equal(model.monitorChoice({presentationModeByMonitor:{'DP-1':'sidebar'}},'DP-1'),'sidebar')
assert.equal(model.monitorChoice({presentationModeByMonitor:{}},'HDMI-A-1'),'default')
const original={presentationModeByMonitor:{'DP-1':'classic','HDMI-A-1':'sidebar'}}
assert.deepEqual(plain(model.copyWithMode(original,'DP-1','sidebar')),{'DP-1':'sidebar','HDMI-A-1':'sidebar'})
assert.deepEqual(plain(model.copyWithMode(original,'DP-1','default')),{'HDMI-A-1':'sidebar'})
assert.deepEqual(original.presentationModeByMonitor,{'DP-1':'classic','HDMI-A-1':'sidebar'})
assert.equal(model.status('saving',false,'loaded'),'Saving')
assert.equal(model.status('error',false,'loaded'),'Not saved')
assert.equal(model.status('saved',true,'loaded'),'Saved')
assert.equal(model.status('idle',true,'invalid'),'Read-only')
const h=hostHarness({ iconSize:48, presentationMode:'classic' })
const a=h.host.saveSettingIntent('iconSize',58,48)
assert.equal(a.accepted,true)
assert.equal(h.host.settings.iconSize,58)
assert.equal(h.request('config.get',{key:'iconSize'}).data.settings.iconSize,58)
const stale=h.host.saveSettingIntent('iconSize',68,48)
assert.equal(stale.reply.error.code,'E_STALE')
const p=h.host.saveSettingsIntent({autoHide:true,reserveSpace:false},
 {autoHide:h.host.settings.autoHide,reserveSpace:h.host.settings.reserveSpace})
assert.equal(p.accepted,true)
assert.equal(h.host.settings.autoHide,true)
assert.equal(h.host.settingsPersisted,true)
console.log('Settings registry, monitor layouts, canonical keys and production writer passed')
