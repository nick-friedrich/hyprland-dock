pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel

Item {
  id: root

  required property var workspaceIds
  required property var workspaces
  required property var hyprToplevels
  required property var workspaceWindowCounts
  required property bool workspaceCountsReady
  required property int workspaceStateRevision
  required property int focusedWorkspaceId
  required property bool vertical
  required property int slotSize
  required property int iconSize
  required property string position
  property bool animationsEnabled: true
  // External content-drag hover: each flat strip cell is a workspace-only
  // target keyed by its canonical workspace identity.
  property var navigation: null
  property QtObject navigationOwner: null
  signal workspaceRequested(int workspaceId, bool pullToMonitor)

  function workspaceForId(id) {
    var values = workspaces || []
    for (var i = 0; i < values.length; ++i) {
      if (Number(values[i] ? values[i].id : -1) === Number(id))
        return values[i]
    }
    return null
  }

  // Flat strip hover target: workspace-only, keyed by canonical identity, and
  // eligible only for a cell the presentation currently renders.
  function externalDragDescriptor(workspaceId, present) {
    if (!root.navigation || present !== true) return null
    var identity = "id:" + Number(workspaceId)
    return {key: "workspace:" + identity, kind: "workspace",
      workspaceIdentity: identity, anchor: null, priority: 0}
  }

  readonly property int cellSize: Math.max(32, Math.round(iconSize * 0.75))
  readonly property var workspacePresentationItems: (workspaceIds || []).map(function(id) {
    return { identity: String(id), workspaceId: Number(id) }
  })

  DockPresentationModel {
    id: workspacePresentationModel
    sourceItems: root.workspacePresentationItems
    keyProperty: "identity"
    animationsEnabled: root.animationsEnabled
  }

  width: vertical ? slotSize + 6 : workspaceGrid.implicitWidth + 8
  height: vertical ? workspaceGrid.implicitHeight + 8 : slotSize + 6
  readonly property point workspaceGridOrigin: DockModel.workspaceGridPosition(
    position, width, height, iconSize,
    workspaceGrid.implicitWidth, workspaceGrid.implicitHeight)

  Rectangle {
    x: workspaceGrid.x - 4
    y: workspaceGrid.y - 4
    width: workspaceGrid.implicitWidth + 8
    height: workspaceGrid.implicitHeight + 8
    radius: Math.max(12, Style.cornerRadius)
    color: Util.alpha(Color.background, 0.5)
    border.width: 1
    border.color: Util.alpha(Color.foreground, 0.14)
  }

  Grid {
    id: workspaceGrid

    x: root.workspaceGridOrigin.x
    y: root.workspaceGridOrigin.y
    columns: root.vertical ? 1 : Math.max(1, workspacePresentationModel.entries.length)
    rows: root.vertical ? Math.max(1, workspacePresentationModel.entries.length) : 1
    spacing: 2

    Repeater {
      model: workspacePresentationModel.model

      DockAnimatedSlot {
        id: workspaceSlot
        required property var modelData
        required property int index
        present: modelData.present
        animateEntrance: modelData.animateEntrance
        animationsEnabled: root.animationsEnabled
        exitRevision: modelData.exitRevision
        naturalWidth: root.cellSize
        naturalHeight: root.cellSize
        trailingGap: 0
        onExitFinished: revision => workspacePresentationModel.completeRemoval(
          modelData.token, revision)

      Item {
        id: workspaceCell

        readonly property var entry: workspaceSlot.modelData.item
        readonly property int workspaceId: entry.workspaceId
        readonly property var workspace: root.workspaceForId(workspaceId)
        readonly property int count: {
          var revision = root.workspaceStateRevision
          return DockModel.workspaceWindowCount(
            workspaceCell.workspaceId, root.hyprToplevels, root.workspaces,
            root.workspaceWindowCounts, root.workspaceCountsReady)
        }
        readonly property bool occupied: count > 0
        readonly property bool focused: root.focusedWorkspaceId === workspaceId

        width: root.cellSize
        height: root.cellSize
        opacity: focused || occupied ? 1 : 0.5
        Behavior on opacity {
          enabled: root.animationsEnabled
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        Rectangle {
          anchors.fill: parent
          radius: Math.max(9, Style.cornerRadius)
          opacity: workspaceCell.focused ? 1 : 0
          color: Util.alpha(Color.accent, 0.18)
          Behavior on opacity {
            enabled: root.animationsEnabled
            NumberAnimation { duration: 160 }
          }
        }

        Button {
          anchors.fill: parent
          radius: Math.max(9, Style.cornerRadius)
          focusable: true
          fontSize: Math.max(Style.font.body, root.iconSize * 0.32)
          text: workspaceCell.workspaceId === 10 ? "0" : String(workspaceCell.workspaceId)
          tooltipText: "Workspace " + workspaceCell.workspaceId
            + (workspaceCell.count === 0
              ? " — empty"
              : " — " + workspaceCell.count
                + (workspaceCell.count === 1 ? " window" : " windows"))
          selected: false
          bordered: false
          foreground: workspaceCell.focused ? Color.accent : Color.menu.text
          background: "transparent"
          accent: Color.accent
          horizontalPadding: 4
          verticalPadding: 3
          enabled: workspaceSlot.modelData.present
          onClicked: root.workspaceRequested(workspaceCell.workspaceId, false)
        }

        TapHandler {
          enabled: workspaceSlot.modelData.present
          acceptedButtons: Qt.LeftButton
          acceptedModifiers: Qt.ControlModifier
          grabPermissions: PointerHandler.CanTakeOverFromItems
            | PointerHandler.CanTakeOverFromHandlersOfDifferentType
          onTapped: root.workspaceRequested(workspaceCell.workspaceId, true)
        }

        DockExternalDragArea {
          id: workspaceCellDragArea

          anchors.fill: parent
          navigation: root.navigation
          owner: root.navigationOwner
          navigationEnabled: !!root.navigation && workspaceSlot.modelData.present
          targetDescriptor: root.externalDragDescriptor(workspaceCell.workspaceId,
            workspaceSlot.modelData.present)
        }

        Rectangle {
          opacity: workspaceCell.focused ? 1 : 0
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 1
          width: 4
          height: 4
          radius: 2
          color: Color.accent
          Behavior on opacity {
            enabled: root.animationsEnabled
            NumberAnimation { duration: 160 }
          }
        }
      }
      }
    }
  }
}
