import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "DockWindowPreviewModel.js" as PreviewModel

Item {
  id: root

  required property var toplevel
  required property var windowActions
  required property var applicationEntry
  required property bool captureEnabled
  property string desktopId: ""
  property string windowOverrideSource: ""
  property var iconOverrides: ({})
  property int iconReloadRevision: 0
  property int previewWidth: 216
  property int previewHeight: 122
  property bool compactActivityLayout: false
  property url fallbackArtwork: ""
  property bool captureStopped: false
  // External content-drag hover: this exact live window is the destination.
  // Destructive controls (the close button) stay outside the drag region,
  // matching the existing click surface.
  property var navigation: null
  property QtObject navigationOwner: null
  readonly property var externalDragArea: tileDragArea
  readonly property bool externalEligible: !!root.navigation && !!root.toplevel
    && !!root.windowActions && root.windowActions.isAlive(root.toplevel)
  readonly property var externalTarget: root.externalDragTarget()

  function externalDragTarget() {
    if (!root.externalEligible) return null
    var address = String(root.windowActions.addressFor(root.toplevel) || "")
    if (!address) return null
    return {key: "window:" + address, kind: "window", toplevel: root.toplevel,
      anchor: root, priority: 0}
  }
  signal activateRequested(var toplevel, bool pullToMonitorWorkspace)
  signal closeRequested(var toplevel)

  readonly property var windowState: root.windowActions
    ? root.windowActions.windowState(root.toplevel) : ({})
  readonly property string titleText: {
    var title = root.toplevel ? String(root.toplevel.title || "").trim() : ""
    if (title) return title
    var appId = root.toplevel ? String(root.toplevel.appId || "").trim() : ""
    if (appId) return appId
    return root.applicationEntry && root.applicationEntry.name
      ? String(root.applicationEntry.name) : "Window"
  }
  readonly property string statusText: PreviewModel.previewStatus(windowState)

  implicitWidth: 232
  implicitHeight: 176

  Accessible.role: Accessible.Button
  Accessible.name: root.titleText + ", " + root.statusText
  Accessible.description: "Focus or restore this application window"
  Accessible.onPressAction: root.activateRequested(root.toplevel, false)

  BorderSurface {
    anchors.fill: parent
    radius: root.compactActivityLayout
      ? Style.space(8) : Style.cornerRadius
    color: Color.menu.background
    borderSpec: Border.surfaceSpec(
      "menu", "border",
      root.compactActivityLayout
        ? Util.alpha(Color.menu.border, 0.38) : Color.menu.border,
      root.compactActivityLayout
        ? Style.spacing.hairline : Math.max(1, Style.space(1)))
  }

  Rectangle {
    id: previewFrame

    x: root.compactActivityLayout ? 2 : 8
    y: root.compactActivityLayout ? 2 : 8
    width: parent.width - (root.compactActivityLayout ? 4 : 16)
    height: root.previewHeight
    radius: root.compactActivityLayout ? Style.space(7)
      : Math.max(4, Style.cornerRadius - 2)
    color: Color.background
    clip: true

    ScreencopyView {
      id: preview

      anchors.centerIn: parent
      captureSource: root.captureEnabled ? root.toplevel : null
      live: false
      paintCursor: false
      constraintSize: Qt.size(root.previewWidth, root.previewHeight)
      width: hasContent && !root.captureStopped
        ? Math.min(parent.width, Math.max(1, implicitWidth)) : 0
      height: hasContent && !root.captureStopped
        ? Math.min(parent.height, Math.max(1, implicitHeight)) : 0
      visible: hasContent && !root.captureStopped

      onCaptureSourceChanged: {
        root.captureStopped = false
        if (!captureSource || !root.captureEnabled) return
        Qt.callLater(() => {
          if (preview.captureSource && root.captureEnabled)
            preview.captureFrame()
        })
      }
      onStopped: root.captureStopped = true
    }

    Item {
      anchors.fill: parent
      visible: root.captureStopped || !preview.hasContent

      Image {
        anchors.fill: parent
        visible: root.fallbackArtwork !== ""
        source: root.fallbackArtwork
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
      }

      Text {
        anchors.centerIn: parent
        visible: root.fallbackArtwork === ""
        text: "Preview unavailable"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  DockAppIcon {
    id: appIcon

    visible: !root.compactActivityLayout
    x: 10
    y: previewFrame.y + previewFrame.height + 10
    width: 26
    height: 26
    desktopId: root.desktopId
    desktopIcon: root.applicationEntry && root.applicationEntry.icon
      ? root.applicationEntry.icon : ""
    iconOverrides: root.iconOverrides
    windowOverrideSource: root.windowOverrideSource
    reloadRevision: root.iconReloadRevision
  }

  Rectangle {
    visible: root.compactActivityLayout
    x: 2
    y: previewFrame.y + previewFrame.height
    width: parent.width - 4
    height: Style.spacing.hairline
    color: Util.alpha(Color.menu.text, 0.12)
  }

  Item {
    id: metadata

    x: root.compactActivityLayout ? Style.space(12)
      : appIcon.x + appIcon.width + 8
    y: previewFrame.y + previewFrame.height
    width: parent.width - x - closeButton.width
      - (root.compactActivityLayout ? Style.space(10) : 18)
    height: root.compactActivityLayout
      ? parent.height - y : 38

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: root.compactActivityLayout ? undefined : parent.top
      anchors.verticalCenter: root.compactActivityLayout
        ? parent.verticalCenter : undefined
      text: root.titleText
      color: Color.menu.text
      font.family: Style.font.family
      font.pixelSize: root.compactActivityLayout
        ? Style.font.subtitle : Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    Text {
      visible: !root.compactActivityLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      text: root.statusText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      maximumLineCount: 1
    }
  }

  Rectangle {
    id: closeButton

    width: root.compactActivityLayout ? Style.space(28) : 30
    height: width
    radius: 15
    x: parent.width - width - 8
    y: root.compactActivityLayout
      ? previewFrame.y + previewFrame.height
        + (parent.height - previewFrame.y - previewFrame.height - height) / 2
      : previewFrame.y + previewFrame.height + 9
    color: closeMouse.containsMouse
      ? Color.menu.selectedBackground : "transparent"
    z: 2

    Accessible.role: Accessible.Button
    Accessible.name: "Close " + root.titleText
    Accessible.onPressAction: root.closeRequested(root.toplevel)

    DockLucideIcon {
      anchors.centerIn: parent
      width: 16
      height: 16
      iconName: "x"
      tint: closeMouse.containsMouse
        ? Color.menu.selectedText : Color.menu.text
    }

    MouseArea {
      id: closeMouse

      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.closeRequested(root.toplevel)
    }
  }

  MouseArea {
    anchors.fill: parent
    anchors.rightMargin: closeButton.width + 10
    cursorShape: Qt.PointingHandCursor
    onClicked: mouse => {
      var keys = mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier
        | Qt.AltModifier | Qt.MetaModifier)
      root.activateRequested(root.toplevel, keys === Qt.ControlModifier)
    }
  }

  DockExternalDragArea {
    id: tileDragArea

    anchors.fill: parent
    anchors.rightMargin: closeButton.width + 10
    navigation: root.navigation
    owner: root.navigationOwner
    targetDescriptor: root.externalTarget
    navigationEnabled: root.externalEligible
  }

  Component.onDestruction: preview.captureSource = null
}
