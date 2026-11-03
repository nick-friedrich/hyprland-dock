pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Wayland._BackgroundEffect
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "DockModel.js" as DockModel
import "DockSidebarWidgetModel.js" as WidgetModel
import "DockSidebarInteractionModel.js" as InteractionModel

PanelWindow {
  id: root
  required property var host
  required property var controller
  readonly property var viewport: sidebarViewport
  readonly property var resizeHandle: resizeHandle
  readonly property var contextMenu: sidebarContext
  readonly property var widgetArea: sidebarWidgets
  readonly property var widgetManageControl: widgetManage
  readonly property var footerControl: pinnedStrip.visible ? pinnedStrip.firstFocusControl : launcher
  readonly property var widgetManager: widgetManagerPopup
  readonly property var collapseControl: collapseButton
  property var menuTarget: null
  property var menuAnchor: null
  property var menuMembers: []
  property var menuEntry: null
  readonly property string preferenceFeedback: root.modeDragError !== ""
    ? root.modeDragError
    : !host ? "" : host.settingsWriteState === "error"
    ? (host.modeMenuWriteConnector ? "" : DockModel.persistenceFeedback(host.settingsWriteError))
    : host.settingsWriteState === "saving" ? "Saving preferences" : controller.mutationFeedback
  // Host-owned, per-connector gesture feedback for this panel's output. The
  // host keys it by connector, so a stale switch on another monitor can never
  // display here. Drag persistence failures stay host-wide; menu failures
  // remain on their source connector. Derived:
  // the host clears it on save/reload and on the next gesture.
  readonly property string modeDragError: !host || !screen ? ""
    : host.modeGestureDisplayFor(screen.name)
  property string presentationMode: DockModel.normalizeSetting(
    "presentationMode", host ? host.settings.presentationMode : "sidebar")
  // Press-time mode-switch token for this panel's connector, injected by the
  // screen owner so a gesture commits against the state it started from.
  property var modeGestureToken: null
  readonly property string sidebarEdge: DockModel.normalizeSetting(
    "sidebarEdge", host ? host.settings.sidebarEdge : "left")
  // Mirrors the existing interface-animation preference; owned by the panel so
  // neither drag surface nor preview re-reads settings on its own.
  readonly property bool animationsEnabled: controller
    && controller.settings.interfaceAnimationsEnabled !== false
  readonly property string badgeScopeOwner: "smartdock-sidebar:" + String(screen && screen.name || "")
  // Per-panel collapse; other mirrored panels keep their own override.
  readonly property bool panelCollapsed: controller.collapsedFor(screen)
  // Official Lucide panel icons; edge does not flip these names.
  readonly property string collapseIcon: root.panelCollapsed
    ? "panel-left-open" : "panel-left-close"
  // Match viewport inner pad + resize-edge allowance on both sides so the
  // expanded header shares the monitor/workspace card edges symmetrically.
  readonly property real panelInnerPad: Style.space(6)
  readonly property real resizeEdgeAllowance: 8
  readonly property real expandedHeaderLeftInset: root.panelInnerPad
    + (!root.panelCollapsed ? root.resizeEdgeAllowance : 0)
  readonly property real expandedHeaderRightInset: root.panelInnerPad
    + (!root.panelCollapsed ? root.resizeEdgeAllowance : 0)
  readonly property var pinStrip: pinnedStrip
  readonly property var pinStripAdd: pinnedStrip.addPinButton
  // Per-output clamp of the shared expanded-width preference.
  readonly property var panelGeometry: controller.geometryFor(screen)
  objectName: "smartdock-sidebar"
  // Never bind PanelWindow.visible: Quickshell already ties it to screen, and a
  // second binding (even screen!==null or geometry.mapped) loops through
  // width/exclusiveZone and damages the first ListView heading.
  implicitWidth: Math.round(panelGeometry.width)
  anchors.top: true
  anchors.bottom: true
  anchors.left: controller.edge === "left"
  anchors.right: controller.edge === "right"
  // The handle lives inside this total width. Reserve that persistent width once.
  exclusiveZone: panelGeometry.mapped ? implicitWidth : 0
  WlrLayershell.namespace: "smartdock-sidebar"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  color: "transparent"
  // Scoped compositor blur behind this panel only (ext-background-effect-v1).
  // Requires Hyprland protocol support; no desktop-wide layerrule / config edits.
  // Region comes from Quickshell; PendingRegion is the attached property type.
  BackgroundEffect.blurRegion: Region {
    item: root.contentItem
  }

  function focusBeforeFooter() {
    return sidebarWidgets.sectionVisible ? sidebarWidgets.focusLastControl() : sidebarViewport.focusLastRow()
  }
  function syncBadges() {
    if (root.host && root.host.badgeTracker) root.host.badgeTracker.syncWorkspaceScopes(
      root.badgeScopeOwner,
      root.visible ? root.controller.projectionFor(root.panelCollapsed).badgeItems : [])
  }

  // Exactly one host-owned write per completed background gesture, through the
  // sole settings writer and scoped to this panel's connector. A stale, busy or
  // disconnected gesture is surfaced but never retried silently; an accepted
  // write clears feedback and lets the host's own saving/persistence state take
  // over.
  function commitModeSwitch(position, gestureToken) {
    if (!host || position !== "bottom" || !root.screen) return
    host.commitMonitorModeGesture(root.screen.name, "classic", gestureToken)
  }

  // The panel-level surface owns header, margin, pin-shelf and utility gaps;
  // the middle-region surface owns only residual blank space. Only one can be
  // pressed at a time, so feedback and the silhouette follow the live one.
  readonly property var activeModeDrag: positionDragSurface.gestureActive
    ? positionDragSurface
    : viewportDragSurface.gestureActive ? viewportDragSurface : null
  readonly property bool modeDragArmed: activeModeDrag !== null && activeModeDrag.armed
  readonly property string modeDragDestinationEdge: activeModeDrag !== null
    ? activeModeDrag.destinationEdge : ""
  // Destination geometry for the classic dock the sidebar would switch to,
  // mirroring Dock.qml's dockBackground sizing and bottom margin.
  readonly property bool classicPreviewGrouped: DockModel.normalizeSetting(
    "workspaceLayout", host ? host.settings.workspaceLayout : "") === "grouped"
  readonly property real classicPreviewBand: DockModel.classicBandExtent(
    DockModel.normalizeSetting("iconSize", host ? host.settings.iconSize : undefined),
    classicPreviewGrouped)
  readonly property real classicPreviewMargin: host && host.settings.margin !== undefined
    ? host.settings.margin : 10

  function syncInteractionBusy() {
    root.controller.interactionBusy = sidebarContext.visible || sidebarContext.iconDialogOpen
      || picker.visible || pinnedStrip.overflowOpen || root.controller.resizeActive
      || root.controller.rowDragActive || root.controller.widgetPopupId !== ""
      || !!root.controller.widgetDragId || !!(root.host && root.host.iconDialogActive)
  }

  function closeSurfaces() {
    sidebarContext.closeAll()
    picker.visible = false
    if (root.pinStrip) root.pinStrip.close()
    sidebarViewport.cancelInputs("surface-close")
    root.controller.cancelResize("surface-close")
    // A dying or hidden panel must not carry a half-finished mode gesture.
    positionDragSurface.cancelGesture("surface-close")
    viewportDragSurface.cancelGesture("surface-close")
    if (root.widgetManager) root.widgetManager.close()
    if (root.widgetArea) {
      if (root.widgetArea.dragWidgetId) root.widgetArea.finishDrag(0, 0, true)
      root.widgetArea.closePopup()
    }
    // A disappearing mirror must not release another panel's widget session.
    root.syncInteractionBusy()
    if (root.host && root.host.badgeTracker) root.host.badgeTracker.syncWorkspaceScopes(root.badgeScopeOwner, [])
  }

  function openContext(target, anchorItem) {
    if (root.controller.interactionBusy || !anchorItem) return false
    var row = target && target.key ? (root.controller.rowsByKey[target.key] || target) : target
    if (!root.controller.targetIsCurrent(row || target)) return false
    // Nested Herdr rows have no app/window menu.
    if (row && (row.kind === "herdr-agent" || row.kind === "herdr-state"))
      return false
    // Tab rows have no app menu of their own; reuse the owning window.
    if (row && row.kind === "browser-tab") {
      var parent = row.windowKey ? root.controller.rowsByKey[row.windowKey] : null
      if (!parent || parent.kind !== "window") return false
      row = parent
      target = root.controller.captureTarget(parent.key) || parent
      if (!root.controller.targetIsCurrent(target)) return false
    }
    root.menuTarget = row || target
    root.menuAnchor = anchorItem
    root.menuMembers = InteractionModel.contextMenuMembers(root.menuTarget, anchorItem)
    root.menuEntry = anchorItem.entry || (root.menuTarget.item && root.menuTarget.item.entry) || null
    sidebarContext.open()
    return true
  }

  function openWidgetManager(anchor) {
    return root.widgetManager ? root.widgetManager.openFor(anchor) : false
  }

  property Item pickerAnchorItem: null
  Timer {
    id: refreshContextTimer
    interval: 0
    repeat: false
    onTriggered: root.refreshContext()
  }

  function openPinPicker(anchor) {
    if (root.controller.interactionBusy && !picker.visible) return false
    var candidate = anchor && anchor.visible ? anchor : null
    if (!candidate || !candidate.width)
      candidate = (root.pinStripAdd && root.pinStripAdd.visible) ? root.pinStripAdd : launcher
    if (!candidate) return false
    root.pickerAnchorItem = candidate
    picker.open()
    return true
  }

  function refreshContext() {
    if (!sidebarContext.visible && !sidebarContext.iconDialogOpen) {
      root.refreshPickerAnchor()
      return
    }
    if (!root.menuAnchor || !root.menuTarget) {
      sidebarContext.closeAll()
      root.refreshPickerAnchor()
      return
    }
    var stripOwned = root.menuAnchor.pinStripOwned === true
    if (stripOwned) {
      // Pin shelf lives outside the viewport; do not treat it as a scrolled row.
      if (!root.menuAnchor.visible || root.menuAnchor.rowKey !== root.menuTarget.key
          || !root.controller.targetIsCurrent(root.menuTarget))
        sidebarContext.closeAll()
      else
        sidebarContext.updatePopupAnchors()
      root.refreshPickerAnchor()
      return
    }
    var point = root.menuAnchor ? sidebarViewport.mapFromItem(root.menuAnchor, 0, 0) : null
    if (!root.menuAnchor || !root.menuAnchor.visible || root.menuAnchor.rowKey !== root.menuTarget.key
        || !root.controller.targetIsCurrent(root.menuTarget) || !point
        || point.y + root.menuAnchor.height <= 0 || point.y >= sidebarViewport.height) {
      sidebarContext.closeAll()
    } else {
      sidebarContext.updatePopupAnchors()
    }
    root.refreshPickerAnchor()
  }

  function refreshPickerAnchor() {
    if (!picker.visible) return
    var anchor = root.pickerAnchorItem
    var footer = anchor === root.pinStripAdd || anchor === launcher
      || !!(anchor && anchor.pinStripOwned === true)
    var point = null
    if (anchor && anchor.visible && !footer)
      point = sidebarViewport.mapFromItem(anchor, 0, 0)
    var decision = InteractionModel.pickerAnchorDecision(anchor, {
      footer: footer,
      visible: !!(anchor && anchor.visible),
      width: anchor ? anchor.width : 0,
      y: point ? point.y : 0,
      height: anchor ? anchor.height : 0,
      viewportHeight: sidebarViewport.height
    })
    if (decision.action === "dismiss") {
      picker.visible = false
      return
    }
    if (picker.anchor && typeof picker.anchor.updateAnchor === "function")
      picker.anchor.updateAnchor()
  }

  // Ghostty-like translucent tint (background-opacity 0.85). Text/icons stay
  // opaque because only the fill alpha is reduced, not Item.opacity.
  // Omarchy package omarchy 4.0.3-1 (no Git revision; inspected 2026-09-18):
  // qs.Ui BorderSurface/Button/PanelActionButton and qs.Commons Color/Style/
  // Border/Util; first-party BorderSurface usage in plugins/panels/tailscale.
  // Theme-reactive card fills for expanded section chrome (phase 4).
  readonly property QtObject sidebarAppearance: QtObject {
    readonly property color monitorFill: Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.foreground, 0.035))
    readonly property color workspaceFill: Qt.darker(Commons.Color.background, 1.04)
    readonly property color workspaceHoverFill: Qt.tint(workspaceFill, Util.alpha(Commons.Color.foreground, 0.09))
    readonly property color activeWorkspaceBorder: Util.alpha(Commons.Color.accent, 0.50)
    readonly property real cardRadius: Math.min(3, Style.cornerRadius)
  }

  Ui.BorderSurface {
    id: surface
    anchors.fill: parent
    color: Util.alpha(Commons.Color.background, 0.85)
    borderSpec: Border.none()
    clip: true
    // Empty-background gesture: drag downward to switch back to the bottom
    // dock mode. Rows, cards, buttons and strips above keep their own input;
    // only genuinely empty background reaches this surface.
    DockPositionDragSurface {
      id: positionDragSurface

      anchors.fill: parent
      dockPosition: root.sidebarEdge
      requestedPosition: root.sidebarEdge
      switchThreshold: 48
      presentationMode: root.presentationMode
      gestureToken: root.modeGestureToken
      sidebarEdge: root.sidebarEdge
      animationsEnabled: root.animationsEnabled
      interactionAllowed: !root.controller.interactionBusy
      onPositionRequested: (position, expectedPosition, gestureToken) =>
        root.commitModeSwitch(position, gestureToken)
    }
    // Subtle desktop-facing divider instead of a full bright panel outline.
    Rectangle {
      width: 1
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.right: root.controller.edge === "left" ? parent.right : undefined
      anchors.left: root.controller.edge === "right" ? parent.left : undefined
      color: Util.alpha(Commons.Color.foreground, 0.10)
    }
    Column {
      id: controls
      x: root.panelCollapsed ? Style.space(6) : root.expandedHeaderLeftInset
      width: Math.max(0, surface.width - (root.panelCollapsed
        ? Style.space(12)
        : (root.expandedHeaderLeftInset + root.expandedHeaderRightInset)))
      y: Style.space(0)
      spacing: Style.space(2)
      Item {
        id: headerBar
        width: parent.width
        height: Style.space(44)
        HoverHandler { cursorShape: Qt.ArrowCursor }
        Row {
          id: brandRow
          visible: !root.panelCollapsed
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: widgetManage.left
          anchors.rightMargin: Style.space(8)
          spacing: 0
          Accessible.role: Accessible.StaticText
          Accessible.name: "Dockrail"
          Text {
            id: brandDock
            width: Math.min(implicitWidth, brandRow.width)
            text: "Dock"
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: Math.max(0, brandRow.width - brandDock.width)
            text: "rail"
            textFormat: Text.PlainText
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
        }
        // Collapse stays centered in rail even when overflow is present; overflow
        // sits immediately left of the collapse control without shifting it.
        // Collapse keeps rail centering via explicit x: conditional anchor
        // attach/detach (horizontalCenter vs right) sticks at a stale offset
        // across hide/show + collapse toggles and never recovers. A pure
        // value binding re-centers on every width/mode change.
        Ui.Button {
          id: collapseButton
          anchors.verticalCenter: parent.verticalCenter
          x: root.panelCollapsed
            ? Math.round((parent.width - width) / 2)
            : parent.width - width
          width: Style.space(30)
          height: Style.space(30)
          iconText: ""
          tooltipText: (root.panelCollapsed ? "Expand sidebar" : "Collapse to icon rail")
            + (root.preferenceFeedback ? " · " + root.preferenceFeedback : "")
          Accessible.role: Accessible.Button
          Accessible.name: tooltipText
          focusable: true
          enabled: !root.controller.interactionBusy
          onClicked: root.controller.requestCollapse(root.screen)
          // Summon anchor for keyboard/IPC/CLI Settings in both expanded and rail modes.
          Component.onCompleted: if (root.host)
            root.host.registerSettingsAnchor(collapseButton,root.screen ? root.screen.name : "", "sidebar")
          Component.onDestruction: if (root.host) root.host.unregisterSettingsAnchor(collapseButton)
          DockLucideIcon {
            anchors.centerIn: parent
            width: 14
            height: 14
            iconName: root.collapseIcon
            iconSize: 14
            tint: Commons.Color.foreground
          }
        }
        Ui.Button {
          id: settingsGear
          visible: !root.panelCollapsed
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: collapseButton.left
          anchors.rightMargin: Style.space(8)
          width: visible ? Style.space(30) : 0
          height: Style.space(30)
          tooltipText: "Dockrail Settings"
          Accessible.name: tooltipText
          focusable: visible
          enabled: !root.controller.interactionBusy
          onClicked: if (root.host) root.host.openSettings(settingsGear, root.screen ? root.screen.name : "")
          Component.onCompleted: if (root.host)
            root.host.registerSettingsAnchor(settingsGear, root.screen ? root.screen.name : "", "sidebar")
          Component.onDestruction: if (root.host) root.host.unregisterSettingsAnchor(settingsGear)
          DockLucideIcon {
            anchors.centerIn: parent
            width: 14; height: 14
            iconName: "settings"
            iconSize: 14
            tint: Commons.Color.foreground
          }
        }
        Ui.Button {
          id: widgetManage
          visible: !root.panelCollapsed
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: settingsGear.left
          anchors.rightMargin: Style.space(8)
          width: visible ? Style.space(30) : 0
          height: Style.space(30)
          iconText: ""
          tooltipText: "Add or manage Widgets"
          Accessible.role: Accessible.Button
          Accessible.name: tooltipText
          focusable: visible
          enabled: !root.controller.interactionBusy
          onClicked: root.openWidgetManager(widgetManage)
          DockLucideIcon {
            anchors.centerIn: parent
            width: 14
            height: 14
            iconName: "layout-grid"
            iconSize: 14
            tint: Commons.Color.foreground
            visible: widgetManage.visible
          }
        }
      }
      Ui.Button {
        id: railSettingsGear
        visible: root.panelCollapsed
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(30)
        height: Style.space(30)
        tooltipText: "Dockrail Settings"
        Accessible.name: tooltipText
        focusable: visible
        enabled: !root.controller.interactionBusy
        onClicked: if (root.host) root.host.openSettings(railSettingsGear, root.screen ? root.screen.name : "")
        Component.onCompleted: if (root.host)
          root.host.registerSettingsAnchor(railSettingsGear, root.screen ? root.screen.name : "", "sidebar")
        Component.onDestruction: if (root.host) root.host.unregisterSettingsAnchor(railSettingsGear)
        DockLucideIcon {
          anchors.centerIn: parent
          width: 14; height: 14
          iconName: "settings"
          iconSize: 14
          tint: Commons.Color.foreground
        }
      }
      Text {
        width: parent.width
        visible: root.preferenceFeedback !== "" && !root.panelCollapsed
        text: root.preferenceFeedback
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Commons.Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
    Item {
      id: middleRegion
      objectName: "sidebar-middle-region"
      anchors.top: controls.bottom
      anchors.topMargin: Style.space(6)
      anchors.bottom: pinnedStrip.top
      anchors.bottomMargin: root.panelCollapsed ? 0 : Style.space(8)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6) + (!root.panelCollapsed ? root.resizeEdgeAllowance : 0)
      anchors.rightMargin: Style.space(6) + (!root.panelCollapsed ? root.resizeEdgeAllowance : 0)
      readonly property var split: WidgetModel.sidebarSplitLayout({
        availableHeight: Math.max(0, height),
        hierarchyContentHeight: sidebarViewport.naturalContentHeight,
        widgetHeaderHeight: sidebarWidgets.naturalWidgetHeaderHeight,
        widgetContentHeight: sidebarWidgets.naturalWidgetContentHeight,
        presentedWidgetCount: sidebarWidgets.presentedWidgetCount,
        rail: root.panelCollapsed,
        minHierarchyHeight: InteractionModel.sidebarRowMetrics({kind:"monitor"}, false,
          sidebarViewport.rowHeight, Style.space, false).height + 2 * sidebarViewport.rowHeight,
        minWidgetHeight: sidebarWidgets.naturalWidgetHeaderHeight + Style.space(34),
        requestedSplitPx: null
      })
      DockSidebarViewport {
        id: sidebarViewport
        width: parent.width
        height: middleRegion.split.hierarchyHeight
        controller: root.controller
        appearance: root.sidebarAppearance
        panelConnector: String(root.screen && root.screen.name || "")
        navigationOwner: root
        panelCollapsed: root.panelCollapsed
        presentationVisible: root.visible
        tabForwardTarget: sidebarWidgets.sectionVisible ? sidebarWidgets.manageControl : root.footerControl
        onContextRequested: (target, anchorItem) => root.openContext(target, anchorItem)
        onDismissContextRequested: sidebarContext.dismiss()
      }
      DockSidebarWidgetArea {
        id: sidebarWidgets
        y: sidebarViewport.height
        width: parent.width
        height: middleRegion.split.widgetHeight
        appearance: root.sidebarAppearance
        controller: root.controller
        panel: root
        viewport: sidebarViewport
        windowRowHeight: sidebarViewport.rowHeight
      }
      DockPositionDragSurface {
        id: viewportDragSurface
        y: middleRegion.split.hierarchyHeight + middleRegion.split.widgetHeight
        width: parent.width
        height: middleRegion.split.blankHeight
        visible: width > 0 && height > 0
        dockPosition: root.sidebarEdge
        requestedPosition: root.sidebarEdge
        switchThreshold: 48
        presentationMode: root.presentationMode
        gestureToken: root.modeGestureToken
        sidebarEdge: root.sidebarEdge
        animationsEnabled: root.animationsEnabled
        interactionAllowed: visible && !root.controller.interactionBusy
        onPositionRequested: (position, expectedPosition, gestureToken) =>
          root.commitModeSwitch(position, gestureToken)
      }
    }
    DockSidebarWidgetManager {
      id: widgetManagerPopup
      controller: root.controller
      panel: root
      viewport: sidebarViewport
    }

    // The ListView owns every pixel its delegates and widget tail cover; only
    // the blank tail below the last row is background. This surface sits above
    // the list and covers exactly that region, so a press on a row or on the
    // scrolling content still belongs to the list.

    DockSidebarPinnedStrip {
      id: pinnedStrip
      controller: root.controller
      panel: root
      appearance: root.sidebarAppearance
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: utilities.top
      // No blank pinned gap in rail — strip height and margin both collapse.
      anchors.bottomMargin: root.panelCollapsed ? 0 : Style.space(8)
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10) + (!root.panelCollapsed && root.controller.edge === "left" ? 8 : 0)
    }
    Row {
      id: utilities
      x: root.panelCollapsed ? Style.space(6) : Style.space(10)
      width: Math.max(0, surface.width - (root.panelCollapsed ? Style.space(12) : Style.space(20)))
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      spacing: Style.space(6)
      Item {
        id: launcher
        width: Math.max(0, parent.width - trashButton.width
          - (trashButton.visible ? parent.spacing : 0))
        height: Style.space(36)
        focus: true
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: "Applications"
        Ui.BorderSurface {
          anchors.fill: parent
          radius: root.sidebarAppearance.cardRadius
          color: launcherPress.pressed
            ? Style.pressedFillFor(Commons.Color.foreground, Commons.Color.accent)
            : (launcherHover.hovered || launcher.activeFocus)
              ? root.sidebarAppearance.workspaceHoverFill
              : Qt.tint(root.sidebarAppearance.workspaceFill, Style.normalFill)
          borderSpec: launcher.activeFocus
            ? Border.controlSpec("focus", Commons.Color.foreground, Commons.Color.accent)
            : Border.none()
          enabled: false
        }
        DockLucideIcon {
          id: launcherIcon
          anchors.verticalCenter: parent.verticalCenter
          x: root.panelCollapsed ? (parent.width - width) / 2 : Style.space(11)
          width: 21
          height: 21
          iconName: "layout-grid"
          iconSize: 21
          tint: Util.alpha(Commons.Color.foreground, 0.82)
        }
        Text {
          visible: !root.panelCollapsed
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: launcherIcon.right
          anchors.leftMargin: Style.space(11)
          anchors.right: launcherChevron.left
          anchors.rightMargin: Style.space(6)
          text: "Applications"
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        DockLucideIcon {
          id: launcherChevron
          visible: !root.panelCollapsed
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          anchors.rightMargin: Style.space(11)
          width: 14
          height: 14
          iconName: "chevron-right"
          iconSize: 14
          tint: Commons.Color.foreground
        }
        HoverHandler { id: launcherHover }
        TapHandler {
          id: launcherPress
          acceptedButtons: Qt.LeftButton
          onTapped: {
            launcher.forceActiveFocus(Qt.MouseFocusReason)
            var command = DockModel.normalizeSetting("controlCommand", root.controller.settings.controlCommand)
            if (command) Quickshell.execDetached(["sh", "-lc", command])
          }
        }
        TapHandler {
          acceptedButtons: Qt.RightButton
          onTapped: {
            launcher.forceActiveFocus(Qt.MouseFocusReason)
            // Pin picker only — never run the desktop launcher on right-click.
            root.openPinPicker(launcher)
          }
        }
        Keys.onPressed: function(event) {
          if (!pinnedStrip.visible && (event.key === Qt.Key_Backtab
              || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier)))) {
            event.accepted = root.focusBeforeFooter()
            return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            var command = DockModel.normalizeSetting("controlCommand", root.controller.settings.controlCommand)
            if (command) Quickshell.execDetached(["sh", "-lc", command])
            event.accepted = true
          }
        }
        DockToolTip {
          anchorItem: launcher
          position: "bottom"
          requestedVisible: launcherHover.hovered && !root.controller.rowDragActive
          text: "Launch applications; right-click to add a pinned application"
          fontFamily: Style.font.family
          fontSize: Style.font.bodySmall
        }
      }
      Ui.Button {
        id: trashButton
        visible: root.host.showTrash
        width: visible ? Style.space(36) : 0
        height: visible ? Style.space(36) : 0
        text: ""
        iconText: ""
        horizontalPadding: 0
        tooltipText: "Open Trash"
        Accessible.role: Accessible.Button
        Accessible.name: "Open Trash"
        focusable: visible
        onClicked: root.host.openTrash()
        DockLucideIcon {
          anchors.verticalCenter: parent.verticalCenter
          anchors.horizontalCenter: parent.horizontalCenter
          width: 14
          height: 14
          iconName: "trash-2"
          iconSize: 14
          tint: Commons.Color.foreground
          visible: trashButton.visible
        }
      }
    }
  }

  DockSidebarResizeHandle {
    id: resizeHandle
    controller: root.controller
    screen: root.screen
    panelWidth: root.width
    screenX: root.screen ? Number(root.screen.x || 0) : 0
    screenWidth: root.screen ? Number(root.screen.width || 0) : 0
    affordanceColor: Util.alpha(Commons.Color.foreground, 0.28)
    animationsEnabled: root.controller.settings.interfaceAnimationsEnabled !== false
    width: 8
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.right: root.controller.edge === "left" ? parent.right : undefined
    anchors.left: root.controller.edge === "right" ? parent.left : undefined
    z: 20
  }

  Shortcut {
    sequence: "Escape"
    enabled: root.visible && root.controller.resizeActive
    onActivated: root.controller.cancelResize("escape")
  }

  // Destination silhouette for this panel's only mode destination: the classic
  // bottom dock. Inert, non-reserving and owned by this Quickshell process.
  DockModeDragPreview {
    requestedVisible: root.modeDragArmed
    edge: root.modeDragDestinationEdge
    bandExtent: root.classicPreviewBand
    edgeInset: root.classicPreviewMargin
    animationsEnabled: root.animationsEnabled
    screen: root.screen
  }

  DockContextMenu {
    id: sidebarContext
    anchorItem: root.menuAnchor
    position: root.controller.edge
    autoHide: false
    pinnedItem: root.menuTarget ? (root.controller.settings.pinned || []).map(DockModel.normalizedId)
      .indexOf(DockModel.normalizedId(root.menuTarget.desktopId)) >= 0 : false
    runningToplevels: root.menuMembers
    windowActions: root.host.windowActions
    originOnly: true
    sidebarMode: true
    workspaceContext: root.menuTarget && root.menuTarget.kind === "workspace" ? root.menuTarget : null
    externalTargetValidator: function() {
      return root.controller.targetIsCurrent(root.menuTarget)
    }
    interfaceAnimationsEnabled: root.controller.settings.interfaceAnimationsEnabled !== false
    onOpenNewWindow: {
      if (root.menuEntry && typeof root.menuEntry.execute === "function") root.menuEntry.execute()
    }
    onVisibleChanged: root.syncInteractionBusy()
    onIconDialogOpenChanged: root.syncInteractionBusy()
    onSettingsRequested: if (root.host) root.host.openSettings(root.panelCollapsed ? railSettingsGear : settingsGear,
      root.screen ? root.screen.name : "")
    onKeyboardDismissed: root.controller.releaseNavigationFocus()
  }
  Connections {
    target: sidebarViewport.listView
    function onContentYChanged() { root.refreshContext() }
  }

  DockAppPicker {
    id: picker
    anchorItem: root.pickerAnchorItem || root.pinStripAdd || launcher
    position: root.controller.edge
    pinned: root.controller.settings.pinned || []
    iconOverrides: root.controller.settings.iconOverrides || ({})
    iconReloadRevision: root.host.iconReloadRevision
    onApplicationSelected: desktopId => root.host.pinApplication(desktopId)
    onVisibleChanged: {
      root.syncInteractionBusy()
      if (visible) root.controller.closeWidgetPopup()
      if (!visible) root.pickerAnchorItem = null
    }
  }
  Connections {
    target: root.pickerAnchorItem
    ignoreUnknownSignals: true
    function onVisibleChanged() { root.refreshPickerAnchor() }
    function onWidthChanged() { root.refreshPickerAnchor() }
  }
  Connections {
    target: pinnedStrip
    function onOverflowOpenChanged() {
      root.syncInteractionBusy()
    }
  }
  Connections {
    target: root.controller
    function onRefreshed() { root.syncBadges(); root.refreshContext() }
    function onPinPickerRequested(anchor) { root.openPinPicker(anchor) }
    function onToplevelsChanged() { refreshContextTimer.restart() }
    function onHyprToplevelsChanged() { refreshContextTimer.restart() }
    function onScopeRevisionChanged() { refreshContextTimer.restart() }
    function onWorkspacesChanged() { refreshContextTimer.restart() }
    function onMonitorsChanged() { refreshContextTimer.restart() }
    function onMinimizedOriginsChanged() { refreshContextTimer.restart() }
    function onSettingsChanged() {
      refreshContextTimer.restart()
    }
    function onSurfaceInvalidated() { root.closeSurfaces() }
    // An idle/cancelled widget completion can clear the shared busy flag.
    // Keep the editor's reservation without changing the controller's owners.
    function onInteractionBusyChanged() {
      if (!root.controller.interactionBusy
          && (sidebarContext.iconDialogOpen || (root.host && root.host.iconDialogActive)))
        root.syncInteractionBusy()
    }
  }
  Connections {
    target: root.host
    function onIconDialogActiveChanged() { root.syncInteractionBusy() }
  }
  onVisibleChanged: { root.syncBadges(); if (!visible) root.closeSurfaces() }
  onPanelCollapsedChanged: root.syncBadges()
  onWidthChanged: refreshContextTimer.restart()
  onHeightChanged: refreshContextTimer.restart()
  Component.onCompleted: root.syncBadges()
  Component.onDestruction: root.closeSurfaces()
}
