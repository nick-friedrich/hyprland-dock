pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "DockSettingsRegistry.js" as Registry

// Sections are built entirely from SET-02 group, order, control and requires metadata.
Item {
  id: root
  required property var host
  required property var metadata
  property string section: "appearance"
  property bool panelActive: false
  property int cursor: 0
  property bool cursorActive: false
  property int navigationRevision: 0
  readonly property bool classicUsed: (host.currentPresentation().classicScreens || []).length > 0
  readonly property var rows: Registry.sectionRows(metadata,section).filter(function(row) {
    return row.ui.visibility === "normal"
  })
  readonly property var groupOrder: section === "appearance"
    ? ["icons","hover-glow","dock-surface","workspace-badges","motion"]
    : ["pointer","windows","attention","attention-on-the-dock"]
  readonly property var groups: groupOrder.map(function(id) {
    return {id:id, rows:root.rows.filter(function(row){return row.ui.group === id})}
  })
  readonly property var targets: {
    navigationRevision
    var values=[]
    for (var i=0;i<cards.count;++i) {
      var card=cards.itemAt(i)
      if (!card) continue
      for (var j=0;j<card.fields.count;++j) {
        var entry=card.fields.itemAt(j)
        if (!entry) continue
        var selected=entry.paired ? entry.pairedControl
          : (entry.modelData.ui.control === "app-list" ? entry.listControl : entry.normalControl)
        if (selected && selected.visible) values.push(selected)
      }
    }
    return values
  }
  readonly property var selectedTarget: targets.length ? targets[Math.min(cursor,targets.length-1)] : null
  readonly property bool editorFocused: targets.some(function(target) {return target.textFocused || target.recoveryFocused})
  readonly property bool popupOpen: targets.some(function(target) {return target.popupOpen})
  signal changed()
  signal focusSettings()
  signal focusSections()
  signal reveal(var item)
  implicitHeight: stack.implicitHeight
  width: parent ? parent.width : 470
  function focusTarget(index) {
    cursor=Math.max(0,Math.min(targets.length-1,index))
    cursorActive=true
    if (selectedTarget) reveal(selectedTarget)
  }
  function moveCursor(delta) {focusTarget(cursor+delta)}
  function adjust(delta) {if(selectedTarget && selectedTarget.adjust) selectedTarget.adjust(delta)}
  function activate() {if(selectedTarget && selectedTarget.activate) selectedTarget.activate()}
  function reorderSelected(delta) {}
  function dismissEditor() {return !!(selectedTarget && selectedTarget.dismissEditor && selectedTarget.dismissEditor())}
  function copyCommand() {return selectedTarget && selectedTarget.command ? selectedTarget.command() : ""}
  function cancelPending() {targets.forEach(function(item){if(item.cancelPending)item.cancelPending()})}
  function hovered(item) {var at=targets.indexOf(item);if(at>=0){focusTarget(at);focusSettings()}}
  Column {
    id: stack
    width: parent.width
    spacing: Style.space(14)
    Text {
      text: root.section === "appearance" ? "Appearance" : "Behavior"
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      color: Commons.Color.foreground
    }
    Repeater {
      id: cards
      onItemAdded: root.navigationRevision++
      onItemRemoved: root.navigationRevision++
      model: root.groups
      delegate: Ui.BorderSurface {
        id: card
        required property var modelData
        readonly property bool classicCard: root.section === "appearance"
          ? modelData.id !== "motion"
          : modelData.rows.every(function(row) {return row.ui.surface === "classic"})
        property alias fields: fields
        width: stack.width
        height: cardBody.implicitHeight + Style.space(24)
        color: Qt.tint(Commons.Color.background,Util.alpha(Commons.Color.foreground,0.035))
        borderSpec: Border.surfaceSpec("popups","border",Util.alpha(Commons.Color.foreground,0.15),1)
        radius: Style.cornerRadius
        Column {
          id:cardBody
          x:Style.space(12);y:Style.space(12)
          width:parent.width-Style.space(24)
          spacing:Style.space(12)
          Row {
            width:parent.width
            spacing:Style.space(8)
            DockLucideIcon {
              id: cardIcon
              width: Style.space(16)
              height: width
              iconSize: width
              iconName: ({icons:"app-window", "hover-glow":"sparkles", "dock-surface":"panel-bottom",
                "workspace-badges":"layout-grid", motion:"move", pointer:"mouse-pointer-click",
                windows:"app-window", attention:"circle-alert", "attention-on-the-dock":"bot"})[card.modelData.id]
              tint: Commons.Color.foreground
            }
            Text {
              text: ({
                "icons":"Icons","hover-glow":"Hover glow","dock-surface":"Dock surface",
                "workspace-badges":"Workspace badges","motion":"Motion",
                "pointer":"Pointer","windows":"Windows","attention":"Attention",
                "attention-on-the-dock":"Attention on the dock"
              })[card.modelData.id] || card.modelData.id
              font.bold:true
              font.family:Style.font.family
              font.pixelSize:Style.font.body
              color:Commons.Color.foreground
              width:parent.width-Style.space(138)-cardIcon.width-parent.spacing
            }
            Text {
              width:Style.space(130)
              horizontalAlignment:Text.AlignRight
              text:card.classicCard ? (root.classicUsed ? "Classic dock" : "Classic dock · Not in use") : "Dock and sidebar"
              wrapMode:Text.WordWrap
              color:Commons.Color.foreground
              opacity:0.9
              font.family:Style.font.family
              font.pixelSize:Style.font.caption
            }
          }
          Repeater {
            id:fields
            onItemAdded:root.navigationRevision++
            onItemRemoved:root.navigationRevision++
            model:card.modelData.rows
            delegate:Column {
              id:entry
              required property var modelData
              readonly property bool paired: modelData.ui.pairedWith !== undefined
              property alias normalControl:normal
              property alias pairedControl:pairedEditor
              property alias listControl:appList
              width:cardBody.width
              spacing:Style.space(5)
              DockSettingsRow {
                id:normal
                visible:!entry.paired && entry.modelData.ui.control!=="app-list"
                width:parent.width
                row:entry.modelData
                host:root.host
                monitorCount:(root.host.connectedScreens || []).length
                hasCursor:root.cursorActive&&root.selectedTarget===this
                feedbackActive:root.panelActive&&visible
                onHovered:root.hovered(this)
                onEdited:root.changed()
                onFocusSections:root.focusSections()
                function command(){return Registry.cliCommand(key,current)}
              }
              DockSettingsPairedRow {
                id:pairedEditor
                visible:entry.paired
                width:parent.width
                row:entry.modelData
                host:root.host
                hasCursor:root.cursorActive&&root.selectedTarget===this
                feedbackActive:root.panelActive&&visible
                onHovered:root.hovered(this)
                onEdited:root.changed()
                onFocusSections:root.focusSections()
              }
              Column {
                id: appList
                visible:entry.modelData.ui.control==="app-list"
                width:parent.width
                spacing:Style.space(8)
                // Keyboard parity: the cursor lands here, left/right picks the
                // grouped app, Enter ungroups it. Mouse users click directly.
                property int selectedGroup: 0
                property bool hasCursor: root.cursorActive && root.selectedTarget === this
                readonly property bool popupOpen: false
                readonly property bool textFocused: false
                readonly property string key: "workspaceGroups"
                readonly property var grouped: root.host.settings.workspaceGroups || []
                readonly property bool editable: root.host.settingsLoadState !== "invalid"
                  && root.host.settingsWriteState !== "saving"
                  && root.host.settingsReloadPending !== true && root.host.settingsLoaded !== false
                function ungroupAt(index) {
                  if (!editable) return false
                  var pair = grouped[index]
                  if (!pair) return false
                  var result = Registry.writeOutcome(root.host.ungroupWorkspaceApplication(
                    pair.desktopId, pair.workspace))
                  if (result.accepted) root.changed()
                  return result.accepted
                }
                function adjust(delta) {
                  if (!grouped.length) return
                  selectedGroup = Math.max(0, Math.min(grouped.length - 1, selectedGroup + delta))
                }
                function activate() { ungroupAt(selectedGroup) }
                function dismissEditor() { return false }
                function cancelPending() { selectedGroup = 0 }
                HoverHandler { onHoveredChanged: if (hovered) root.hovered(appList) }
                Text {text:entry.modelData.ui.label; color:appList.hasCursor ? Commons.Color.accent : Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.body;font.bold:true}
                Repeater {
                  model:appList.grouped
                  delegate:Row {
                    required property var modelData
                    required property int index
                    spacing:Style.space(8)
                    Text {
                      text: parent.modelData.desktopId + " · " + parent.modelData.workspace
                      width:cardBody.width-Style.space(110)
                      elide:Text.ElideRight
                      color:appList.hasCursor && appList.selectedGroup === parent.index ? Commons.Color.accent : Commons.Color.foreground
                    }
                    Ui.Button {
                      text:"Ungroup"
                      focusable:true
                      Accessible.name:"Ungroup " + parent.modelData.desktopId + " from " + parent.modelData.workspace
                      enabled:appList.editable
                      onClicked: appList.ungroupAt(parent.index)
                    }
                  }
                }
                Text {visible:appList.grouped.length===0;text:"No grouped apps. Right-click an app and choose Group Windows.";wrapMode:Text.WordWrap;color:Commons.Color.foreground;font.family:Style.font.family;font.pixelSize:Style.font.caption}
              }
            }
          }
        }
      }
    }
  }
}
