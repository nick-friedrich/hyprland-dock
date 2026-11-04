import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel
import "DockBadgeModel.js" as BadgeModel
import "DockWindowModel.js" as DockWindowModel
import "DockWindowPreviewModel.js" as PreviewModel

Item {
  id: root

  required property string desktopId
  required property bool pinnedItem
  required property var runningToplevels
  required property bool focused
  required property var windowActions
  required property var hyprToplevels
  required property var badgeTracker
  required property string attentionBadge
  required property bool attentionBadgesEnabled
  required property bool urgentWindowAnimationEnabled
  required property bool primaryBadgeOwner
  required property bool dockShown
  required property bool fullscreenModeActive
  required property bool fullscreenEmphasized
  required property int itemIndex
  required property int slotSize
  required property int iconSize
  required property real magnification
  required property real magnificationRadius
  required property bool hoverGlowEnabled
  required property real hoverGlowOpacity
  required property real hoverGlowRadius
  required property real pointerPosition
  required property var applicationActions
  required property bool showPreviews
  required property color workspaceBadgeBackgroundColor
  required property color workspaceBadgeTextColor
  required property bool autoHide
  required property string position
  required property bool vertical
  required property bool previewActive
  required property bool interfaceAnimationsEnabled
  property var herdrSummary: ({
    count: 0, indicatorStatus: "", counters: [], rows: [],
    blockedTransitionRevision: 0
  })
  property int herdrWindowCount: 0
  property bool herdrReplacesAttention: false
  property var iconOverrides: ({})
  property string windowOverrideSource: ""
  property int iconReloadRevision: 0
  property DockWorkspaceDrag workspaceDrag: null
  property bool workspaceDragEnabled: false
  property bool workspaceGestureOwned: false
  property bool workspaceGestureConsumed: false
  readonly property bool workspaceDragActive: workspaceDrag !== null && workspaceDrag.active
  readonly property bool workspaceInputSuppressed: workspaceDragActive || workspaceGestureOwned
  property var browserProfileService: null
  property string browserProfileKey: ""
  property bool browserProfileBadgesEnabled: true
  property var previewActivities: []
  property var previewAgents: []
  property bool previewHerdrOnly: false
  property string previewHerdrLabel: ""
  property string previewHerdrProduct: "Herdr"
  property string previewHerdrFocusHint: "Click a row to focus its pane."
  property var previewHerdrCounters: []
  property var herdrAgentActions: null
  readonly property var browserProfileEntry: browserProfileKey && browserProfileService
    ? browserProfileService.profileFor(browserProfileKey) : null
  property bool presentationActive: true
  property bool originOnly: false
  // External content-drag hover. Dock.qml injects the host coordinator, this
  // dock surface as the owner, and the workspace identity this icon represents
  // (the owning card in grouped layout, the item's own workspace in flat
  // layout). The icon only describes its destination; the shared owners focus.
  property var navigation: null
  property QtObject navigationOwner: null
  property string localWorkspaceIdentity: ""
  property var externalTarget: null
  readonly property var externalDragArea: iconDragArea
  readonly property string representedWorkspaceIdentity: {
    var card = String(root.workspaceActivationTarget || "")
    return card !== "" ? card : String(root.localWorkspaceIdentity || "")
  }
  readonly property bool externalEligible: !!root.navigation
    && root.presentationActive && root.presentationVisible
    && !root.workspaceInputSuppressed
    && !(root.contextMenu && root.contextMenu.visible)
    && root.runningCount > 0

  property bool localUrgent: false
  property bool sticky: false
  property string attentionScopeKey: ""
  property string activationMonitor: ""
  property string workspaceActivationTarget: ""
  property bool presentationVisible: true
  property bool motionReady: false
  property bool launchPending: false
  readonly property var attentionScope: attentionScopeKey
    ? ({ localUrgent: localUrgent, primaryOwner: primaryBadgeOwner }) : null
  readonly property bool motionOwner: attentionScopeKey !== "" || primaryBadgeOwner

  function beginLaunchFeedback() {
    if (!root.pinnedItem || root.runningCount > 0) return
    root.launchPending = true
    launchFeedbackTimeout.restart()
    launchMotion.restart()
  }

  function clearLaunchFeedback() {
    root.launchPending = false
    launchFeedbackTimeout.stop()
    launchMotion.stop()
  }

  function hasPreviewContent() {
    return PreviewModel.hasPreviewContent(
      root.runningCount, root.previewActivities.length, root.previewAgents.length)
  }

  function dismissPopups() {
    contextMenu.closeAll()
    previewReleased(root)
  }

  // Hover resolution for a content drag. One live window activates that exact
  // toplevel; several windows open the existing preview after the dwell (the
  // preview owns exact tile selection); with previews disabled the icon reveals
  // the workspace it represents and never picks a window from focus history.
  function externalDragTarget() {
    if (!root.externalEligible) return null
    if (root.runningCount === 1) {
      var toplevel = root.runningToplevels[0]
      var address = root.windowActions
        ? String(root.windowActions.addressFor(toplevel) || "") : ""
      if (!address) return null
      return {key: "window:" + address, kind: "window", toplevel: toplevel,
        anchor: root, priority: 0}
    }
    if (root.showPreviews) {
      var presentation = String(root.presentationId || "")
      if (!presentation) return null
      return {key: "preview:" + presentation, kind: "preview",
        anchor: root, priority: 0}
    }
    var workspace = root.representedWorkspaceIdentity
    if (!workspace) return null
    return {key: "workspace:" + workspace, kind: "workspace",
      workspaceIdentity: workspace, anchor: root, priority: 0}
  }

  // A held token keeps its captured descriptor: focus/provider/workspace
  // revalidation at activation decides whether it is still valid, so unrelated
  // inventory refreshes cannot restart the dwell. A fresh drag entry forces a
  // recapture so a row exposed since the last visit is immediately eligible.
  function refreshExternalTarget(force) {
    if (force !== true && iconDragArea.token !== 0) return
    root.externalTarget = root.externalDragTarget()
  }

  function cancelWorkspaceDrag(reason) {
    if (root.workspaceDrag && root.workspaceDrag.sourceItem === root)
      root.workspaceDrag.cancel(reason)
  }

  function workspaceGrabChanged(transition, point) {
    if (transition === PointerDevice.GrabPassive
        || transition === PointerDevice.GrabExclusive)
      root.forceActiveFocus(Qt.MouseFocusReason)
    if (!root.workspaceDrag || root.workspaceDrag.sourceItem !== root) return
    if (transition === PointerDevice.UngrabExclusive) {
      root.workspaceDrag.finish(point.scenePosition)
    } else if (transition === PointerDevice.CancelGrabExclusive
        || transition === PointerDevice.CancelGrabPassive) {
      cancelWorkspaceDrag("grab cancelled")
    }
  }

  onWorkspaceDragActiveChanged: if (workspaceDragActive) {
    dismissPopups()
    wheelRemainder = 0
    lastWheelTimestamp = 0
  }
  onWorkspaceDragEnabledChanged: if (!workspaceDragEnabled) cancelWorkspaceDrag("drag disabled")
  onParentChanged: {
    cancelWorkspaceDrag("source reparented")
    if (typeof contextMenu !== "undefined" && contextMenu) contextMenu.closeAll()
  }

  function refreshPopupGeometry() {
    if (!presentationVisible) return
    tooltip.scheduleReanchor()
    contextMenu.updatePopupAnchors()
  }
  onPresentationVisibleChanged: {
    if (!presentationVisible) dismissPopups()
    root.refreshExternalTarget(false)
  }
  property int scopeRevision: 0
  property bool menuOpen: false
  function syncMenuOpen() {
    var open = contextMenu.visible || contextMenu.iconDialogOpen
    if (root.menuOpen === open) return
    root.menuOpen = open
    root.contextMenuVisibilityChanged(open)
  }
  onScopeRevisionChanged: if (originOnly && contextMenu.visible) contextMenu.dismiss()
  onVisibleChanged: if (!visible) {
    cancelWorkspaceDrag("source hidden")
    root.dismissPopups()
  }
  Component.onDestruction: {
    cancelWorkspaceDrag("source destroyed")
    if (menuOpen) {
      menuOpen = false
      root.contextMenuVisibilityChanged(false)
    }
    root.previewReleased(root)
  }
  property string presentationId: desktopId
  property var identityToplevel: null
  // Kept as an optional compatibility hook for preview controllers that use
  // the earlier FDM-814 name; the host's previewActive binding remains the
  // canonical source.
  property bool previewInteractionActive: false
  property real reorderOffset: 0
  property int lastActivatedToplevel: -1
  property real wheelRemainder: 0
  property double lastWheelTimestamp: 0
  signal dragStarted(int itemIndex)
  signal dragMoved(real mainPosition)
  signal dragFinished()
  signal addApplicationRequested()
  signal removeRequested(string desktopId)
  signal hideRequested(string desktopId)
  signal autoHideToggled(bool enabled)
  signal contextMenuVisibilityChanged(bool visible)
  signal previewRequested(var anchorItem, string desktopId, var toplevels, var applicationEntry)
  signal previewReleased(var anchorItem)
  signal previewDismissRequested()

  // Reading the model makes this binding update when Quickshell finishes its
  // asynchronous desktop-entry scan. Calling byId() alone is not reactive.
  readonly property var applications: DesktopEntries.applications.values || []
  readonly property var entry: {
    var modelRevision = applications.length
    return DesktopEntries.byId(desktopId)
  }
  readonly property var runningToplevel: runningToplevels.length > 0
    ? runningToplevels[0]
    : null
  readonly property int runningCount: runningToplevels.length
  readonly property string workspaceBadge: originOnly ? "" : DockModel.workspaceBadgeText(
    runningToplevels, hyprToplevels)
  readonly property int minimizedCount: contextMenu.minimizedCount
  readonly property int visibleWindowCount: contextMenu.visibleWindowCount
  readonly property bool allWindowsMinimized: runningCount > 0 && visibleWindowCount === 0
  readonly property real dragOffset: dragHandler.active
    ? vertical ? dragHandler.activeTranslation.y : dragHandler.activeTranslation.x
    : 0
  readonly property real itemCenter: (vertical ? y + height / 2 : x + width / 2)
    + dragOffset + reorderOffset
  readonly property real distance: Math.abs(pointerPosition - itemCenter)
  readonly property real influence: pointerPosition < -1000 || workspaceInputSuppressed
    ? 0
    : Math.exp(-(distance * distance) / (magnificationRadius * magnificationRadius))
  readonly property var fullscreenPresentation:
    DockModel.fullscreenIconPresentation(
      fullscreenModeActive, fullscreenEmphasized, mouse.hovered && !workspaceInputSuppressed)
  readonly property real iconScale: fullscreenPresentation.scale
    * (1 + (magnification - 1) * influence)
  readonly property var urgentBadgeState: badgeTracker
    ? badgeTracker.urgentStateFor(desktopId, motionOwner, attentionScopeKey)
    : ({ windowUrgent: false, primaryOwner: primaryBadgeOwner,
         windowUrgentRevision: 0 })
  readonly property bool windowUrgent: urgentBadgeState.windowUrgent === true
  readonly property int windowUrgentRevision:
    Number(urgentBadgeState.windowUrgentRevision || 0)
  readonly property bool attentionActive: !herdrReplacesAttention && badgeTracker
    ? badgeTracker.motionAttentionFor(desktopId, attentionScope) : false
  readonly property int herdrAgentCount: Math.max(0,
    Number(herdrSummary && herdrSummary.count) || 0)
  readonly property string herdrIndicatorStatus:
    String(herdrSummary && herdrSummary.indicatorStatus || "")
  readonly property int herdrBlockedTransitionRevision: Math.max(0,
    Number(herdrSummary && herdrSummary.blockedTransitionRevision) || 0)
  property int seenHerdrBlockedTransitionRevision: 0
  readonly property bool urgentMotionSuppressed: !presentationVisible || mouse.hovered
    || dragHandler.active || contextMenu.visible || workspaceInputSuppressed
    || previewActive || previewInteractionActive || !presentationActive

  function launch() {
    if (root.workspaceInputSuppressed) return
    if (root.pinnedItem && root.runningCount === 0)
      root.beginLaunchFeedback()
    if (entry)
      entry.execute()
    else
      Quickshell.execDetached(["gtk-launch", desktopId + ".desktop"])
  }

  function dispatchApplicationAction(action, options) {
    if (root.workspaceInputSuppressed) return false
    if (!DockModel.applicationActionCanRun(action, runningCount)) return false

    var request = options || ({})
    var activationMonitor = request.activationMonitor || ""
    switch (action) {
    case "cycle-windows":
      // Scrolling retains its monitor pull; Ctrl only gates click activation.
      return root.windowActions.cycleToplevels(
        root.runningToplevels, request.direction, root.windowActions.activeToplevel,
        root.originOnly, root.activationMonitor)
    case "minimize-restore":
      return root.windowActions.minimizeRestoreToplevels(root.runningToplevels, root.originOnly)
    case "previews":
      if (!root.showPreviews || !root.hasPreviewContent()) return false
      root.previewRequested(root, root.desktopId, root.runningToplevels, root.entry)
      return true
    case "close":
      return root.windowActions.closeToplevels(root.runningToplevels)
    case "focus-or-launch":
      if (root.runningCount > 0) {
        // Preserve the pre-FDM-815 left-click behavior exactly: repeated
        // clicks walk the group in model order and activate the next window.
        root.lastActivatedToplevel = DockModel.nextToplevelIndex(
          root.lastActivatedToplevel, root.runningCount)
        return root.windowActions.activateToplevel(
          root.runningToplevels[root.lastActivatedToplevel], root.originOnly,
          activationMonitor, undefined, request.workspaceTargetOverride)
      }
      root.launch()
      return true
    default:
      return false
    }
  }

  function dispatchPointerAction(input, modifiers, options) {
    var keys = modifiers || ({})
    var request = Object.assign({}, options || ({}))
    // Ctrl+left on a running app moves the window a plain click would focus
    // to this monitor's workspace; other inputs keep their monitor routing.
    if (input === "left" && keys.control === true) {
      var action = DockModel.resolveApplicationPointerAction(
        applicationActions, input, modifiers)
      if (action === "focus-or-launch" && root.runningCount > 0) {
        // Preserve the pre-FDM-815 left-click cycling order: repeated
        // Ctrl-clicks walk the group in model order and move each window.
        root.lastActivatedToplevel = DockModel.nextToplevelIndex(
          root.lastActivatedToplevel, root.runningCount)
        return root.windowActions.pullToplevelToMonitorWorkspace(
          root.runningToplevels[root.lastActivatedToplevel], root.originOnly,
          root.activationMonitor)
      }
    }
    var cardTarget = root.workspaceActivationTarget || ""
    // Left-click relocation requires explicit Ctrl; preserve other input actions.
    if (input !== "left" && cardTarget !== "") {
      request.activationMonitor = root.activationMonitor
      if (cardTarget !== "")
        request.workspaceTargetOverride = cardTarget
    }
    return dispatchApplicationAction(DockModel.resolveApplicationPointerAction(
      applicationActions, input, modifiers), request)
  }

  onRunningToplevelsChanged: {
    if (root.launchPending && root.runningCount > 0)
      root.clearLaunchFeedback()
    lastActivatedToplevel = -1
    wheelRemainder = 0
    lastWheelTimestamp = 0
    if (!root.hasPreviewContent())
      root.previewDismissRequested()
    root.refreshExternalTarget(false)
  }

  onShowPreviewsChanged: root.refreshExternalTarget(false)
  onExternalEligibleChanged: root.refreshExternalTarget(false)
  onWorkspaceActivationTargetChanged: root.refreshExternalTarget(false)
  onLocalWorkspaceIdentityChanged: root.refreshExternalTarget(false)

  onPresentationActiveChanged: {
    if (!presentationActive) {
      clearLaunchFeedback()
      cancelWorkspaceDrag("presentation removed")
      dismissPopups()
      attentionReminderTimer.stop()
      attentionMotion.stop()
    }
  }

  function primeUrgentMotion() {
    if (!badgeTracker || !motionOwner) return
    if (!attentionScopeKey) badgeTracker.ensureUrgentState(desktopId)
    var state = badgeTracker.urgentStateFor(desktopId, true, attentionScopeKey)
    badgeTracker.primeUrgentMotion(
      desktopId, Number(state.windowUrgentRevision || 0), attentionScopeKey)
  }

  function requestUrgentMotion(reminder) {
    if (!motionReady || !badgeTracker || !motionOwner) return
    if (urgentMotionSuppressed) attentionMotion.stop()
    var play = badgeTracker.requestUrgentMotion(desktopId, {
      revision: windowUrgentRevision,
      windowUrgent: windowUrgent,
      attentionActive: attentionActive,
      reminder: reminder === true,
      primaryOwner: true,
      badgesEnabled: attentionBadgesEnabled,
      animationEnabled: urgentWindowAnimationEnabled,
      dockShown: dockShown && presentationVisible,
      interactionActive: urgentMotionSuppressed,
      now: Date.now()
    }, attentionScopeKey)
    if (play && !urgentMotionSuppressed) attentionMotion.play()
  }

  function requestHerdrBlockedMotion() {
    var revision = root.herdrBlockedTransitionRevision
    if (revision <= root.seenHerdrBlockedTransitionRevision) return
    root.seenHerdrBlockedTransitionRevision = revision
    // Same suppression as urgent motion; a skipped transition is not replayed later.
    if (root.motionReady && root.urgentWindowAnimationEnabled
        && root.attentionBadgesEnabled && !root.urgentMotionSuppressed
        && !root.focused) attentionMotion.play()
  }

  Component.onCompleted: {
    primeUrgentMotion()
    seenHerdrBlockedTransitionRevision = herdrBlockedTransitionRevision
    motionReady = true
    requestUrgentMotion(false)
    root.refreshExternalTarget(false)
  }
  onAttentionActiveChanged: {
    if (attentionActive) {
      requestUrgentMotion(true)
      return
    }
    attentionReminderTimer.stop()
    attentionMotion.stop()
    requestUrgentMotion(false)
  }
  onWindowUrgentRevisionChanged: requestUrgentMotion()
  onWindowUrgentChanged: requestUrgentMotion()
  onDockShownChanged: requestUrgentMotion()
  onUrgentMotionSuppressedChanged: {
    if (urgentMotionSuppressed) attentionMotion.stop()
    requestUrgentMotion()
  }
  onUrgentWindowAnimationEnabledChanged: {
    if (!urgentWindowAnimationEnabled) {
      attentionReminderTimer.stop()
      attentionMotion.stop()
    }
    requestUrgentMotion()
  }
  onAttentionBadgesEnabledChanged: {
    if (!attentionBadgesEnabled) {
      attentionReminderTimer.stop()
      attentionMotion.stop()
    }
    requestUrgentMotion()
  }
  onHerdrBlockedTransitionRevisionChanged: requestHerdrBlockedMotion()
  onPinnedItemChanged: if (!pinnedItem) clearLaunchFeedback()

  Timer {
    id: attentionReminderTimer
    interval: 3000
    repeat: true
    running: root.motionReady && root.motionOwner && root.attentionActive
      && root.dockShown && root.presentationVisible
      && root.attentionBadgesEnabled
      && root.urgentWindowAnimationEnabled
    onTriggered: root.requestUrgentMotion(true)
  }

  Timer {
    id: launchFeedbackTimeout
    interval: 8000
    repeat: false
    onTriggered: root.clearLaunchFeedback()
  }

  width: vertical ? slotSize + 6 : slotSize
  height: vertical ? slotSize : slotSize + 6
  z: dragHandler.active ? 2 : 0
  transform: Translate {
    x: root.vertical ? 0 : root.dragOffset + root.reorderOffset
    y: root.vertical ? root.dragOffset + root.reorderOffset : 0
  }

  Behavior on reorderOffset {
    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
  }

  DockAttentionMotion {
    id: attentionMotion
    position: root.position
  }

  DockLaunchMotion {
    id: launchMotion
    position: root.position
    active: root.launchPending
    animationsEnabled: root.interfaceAnimationsEnabled
  }

  Item {
    id: iconContainer

    x: (root.width - root.iconSize) / 2
    y: (root.height - root.iconSize) / 2
    width: root.iconSize
    height: root.iconSize
    opacity: root.fullscreenPresentation.opacity
      * (root.workspaceDragActive && root.workspaceDrag.sourceItem === root ? 0.35 : 1)
    transformOrigin: root.position === "top"
      ? Item.Top
      : root.position === "left"
        ? Item.Left
        : root.position === "right" ? Item.Right : Item.Bottom
    scale: root.iconScale

    Behavior on scale {
      NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
    }

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Item {
      id: motionContent

      anchors.fill: parent
      transform: Translate {
        x: attentionMotion.xOffset + launchMotion.xOffset
        y: attentionMotion.yOffset + launchMotion.yOffset
      }

      RectangularShadow {
        id: hoverGlow

        anchors.fill: parent
        radius: Math.min(width, height) * 0.34
        blur: Math.max(8, root.iconSize * root.hoverGlowRadius / 100)
        spread: Math.max(1, root.iconSize * 0.06)
        offset: Qt.vector2d(0, 0)
        color: Color.accent
        opacity: root.hoverGlowEnabled && mouse.hovered && !root.workspaceInputSuppressed
          ? root.hoverGlowOpacity : 0
        z: -1

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }

      Rectangle {
        anchors.fill: parent
        anchors.margins: -4
        radius: Math.max(10, Style.cornerRadius)
        color: Util.alpha(Color.background, mouse.hovered && !root.workspaceInputSuppressed ? 0.36 : 0)
        Behavior on color { ColorAnimation { duration: 140 } }
      }

      DockAppIcon {
        id: applicationArtwork
        anchors.fill: parent
        opacity: root.allWindowsMinimized ? 0.56 : 1.0
        desktopId: root.desktopId
        desktopIcon: root.entry && root.entry.icon ? root.entry.icon : ""
        iconOverrides: root.iconOverrides
        windowOverrideSource: root.windowOverrideSource
        reloadRevision: root.iconReloadRevision
        profileKey: root.browserProfileKey
        profileName: root.browserProfileEntry ? String(root.browserProfileEntry.name || "") : ""
        profileAvatarPath: root.browserProfileEntry ? String(root.browserProfileEntry.avatarPath || "") : ""
        profileBadgesEnabled: root.browserProfileBadgesEnabled

        Behavior on opacity { NumberAnimation { duration: 140 } }
      }

      Rectangle {
        id: windowCountBadge
        objectName: "dock-corner-count-badge"

        visible: root.runningCount > 1 && !herdrStatusMark.visible
        width: Math.max(16, windowCountText.implicitWidth + 8)
        height: 16
        radius: height / 2
        x: iconContainer.width - width + 5
        y: -5
        color: Color.accent
        border.width: Style.normalBorderWidth
        border.color: Color.background
        z: 3

        Text {
          id: windowCountText
          objectName: "dock-corner-count-text"

          anchors.centerIn: parent
          text: root.runningCount > 99 ? "99+" : String(root.runningCount)
          color: Color.background
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      DockApplicationBadge {
        objectName: "dock-attention-badge"
        severity: root.herdrReplacesAttention ? "none" : root.attentionBadge
        x: iconContainer.width - width + 3
        y: -3 + (windowCountBadge.visible ? 16 : 0)
          + (herdrStatusMark.visible ? herdrStatusMark.height : 0)
      }

      DockHerdrStatusMark {
        id: herdrStatusMark
        objectName: "dock-herdr-status-mark"
        status: root.herdrIndicatorStatus
        size: Math.round(Math.min(26, Math.max(16, root.iconSize * 0.84)))
        ringColor: Color.background
        animationsEnabled: root.interfaceAnimationsEnabled
        x: iconContainer.width - width + Math.round(width * 0.3)
        y: -Math.round(height * 0.3)
        z: 4
      }

      Rectangle {
        visible: root.sticky
        width: 10
        height: 10
        radius: 2
        x: -3
        y: iconContainer.height - height + 3
        color: Color.background
        border.width: 2
        border.color: Color.accent
      }

      Rectangle {
        id: minimizedCountBadge

        visible: root.minimizedCount > 0
        width: Math.max(22, minimizedCountText.implicitWidth + 8)
        height: 16
        radius: Math.min(height / 2, Style.cornerRadius)
        x: -5
        y: -5
        color: Color.muted
        border.color: Color.background
        border.width: Style.normalBorderWidth
        z: 3

        Text {
          id: minimizedCountText

          anchors.centerIn: parent
          text: "m" + (root.minimizedCount > 99 ? "99+" : String(root.minimizedCount))
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Rectangle {
        id: workspaceBadge

        visible: root.workspaceBadge !== ""
        width: Math.max(16, workspaceBadgeText.implicitWidth + 8)
        height: 16
        radius: Math.min(height / 2, Style.cornerRadius)
        x: -5
        y: iconContainer.height - height + 5
        color: root.workspaceBadgeBackgroundColor
        border.width: 0
        z: 3

        Text {
          id: workspaceBadgeText

          anchors.centerIn: parent
          text: root.workspaceBadge
          color: root.workspaceBadgeTextColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    // Keep the persistent running/focus indicator anchored to the dock slot;
    // only the application artwork/badges receive the transient nudge offset.
    DockApplicationStateIndicator {
      id: applicationStateIndicator

      // Grouped cards keep the marker on the slot, within the compact edge inset.
      // Flat/vertical docks retain their existing magnified marker presentation.
      parent: root.originOnly ? root : iconContainer
      x: indicatorGeometry.x + (root.originOnly ? iconContainer.x : 0)
      y: indicatorGeometry.y + (root.originOnly ? iconContainer.y : 0)
      opacity: root.originOnly ? iconContainer.opacity : 1
      position: root.position
      iconWidth: iconContainer.width
      iconHeight: iconContainer.height
      running: root.runningCount > 0
      focused: root.focused
      // Workspace pills leave ~8px below the icon; keep the marker inside them.
      edgeGap: root.originOnly ? 2 : 7
      runningColor: Color.foreground
      focusedColor: Color.accent
    }
  }

  DockToolTip {
    id: tooltip
    anchorItem: root
    position: root.position
    requestedVisible: root.presentationVisible && mouse.hovered && !contextMenu.visible && !root.previewActive && !dragHandler.active && root.reorderOffset === 0 && !root.workspaceInputSuppressed
    text: root.tooltipLabel()
    fontFamily: Style.font.family
    fontSize: Style.font.body
  }

  function tooltipLabel() {
    var name = root.entry ? root.entry.name : root.desktopId
    var profileName = root.browserProfileEntry
      ? String(root.browserProfileEntry.name || "").trim() : ""
    if (profileName) name += " - " + profileName
    var state = root.focused ? "focused application"
      : root.runningCount > 0 ? "running application" : ""
    var label = state ? name + " — " + state : name
    if (root.sticky) label += " (sticky on this monitor)"
    if (root.minimizedCount > 0) {
      var word = root.runningCount === 1 ? "window" : "windows"
      return label + " (" + root.runningCount + " " + word
        + ", " + root.minimizedCount + " minimized)"
    }
    if (root.runningCount > 1)
      return label + " (" + root.runningCount + " windows)"
    return label
  }

  function accessibleLabel() {
    var name = root.entry ? root.entry.name : root.desktopId
    var profileName = root.browserProfileEntry
      ? String(root.browserProfileEntry.name || "").trim() : ""
    if (profileName) name += " - " + profileName
    if (root.runningCount > 0)
      name += " · " + root.runningCount + (root.runningCount === 1 ? " window" : " windows")
    if (root.herdrAgentCount > 0) {
      var noun = root.previewHerdrProduct === "T3 Code" ? "thread"
        : root.previewHerdrProduct === "Claude" ? "session" : "agent"
      name += " · " + root.herdrAgentCount
        + (root.herdrAgentCount === 1 ? " " + noun : " " + noun + "s")
    }
    var counters = root.herdrSummary && Array.isArray(root.herdrSummary.counters)
      ? root.herdrSummary.counters : []
    for (var i = 0; i < counters.length; ++i) {
      var count = Math.max(0, Number(counters[i].count) || 0)
      if (count === 0) continue
      var status = String(counters[i].status || "")
      if (status === "blocked") name += " · " + count + " needs input"
      else if (status === "working") name += " · " + count + " working"
      else if (status === "done") name += " · " + count + " done"
    }
    return name
  }

  Accessible.role: Accessible.Button
  Accessible.name: accessibleLabel()

  // Nonvisual native drag region over the icon slot. It is deliberately outside
  // the tap/drag handlers: hovering never opens a menu, launches, or clicks.
  DockExternalDragArea {
    id: iconDragArea

    anchors.fill: parent
    navigation: root.navigation
    owner: root.navigationOwner
    targetDescriptor: root.externalTarget
    navigationEnabled: root.externalEligible
  }
  Connections {
    target: iconDragArea
    function onContainsDragChanged() {
      if (iconDragArea.containsDrag) root.refreshExternalTarget(true)
    }
  }

  HoverHandler {
    id: mouse
    cursorShape: Qt.PointingHandCursor
    onHoveredChanged: {
      if (hovered) {
        if (root.showPreviews && root.hasPreviewContent()
            && !contextMenu.visible && !dragHandler.active && !root.workspaceInputSuppressed)
          root.previewRequested(root, root.desktopId,
            root.runningToplevels, root.entry)
      } else if (root.previewActive || root.hasPreviewContent()) {
        root.previewReleased(root)
      }
    }
  }

  TapHandler {
    enabled: root.presentationActive && !root.workspaceInputSuppressed
    acceptedButtons: Qt.LeftButton
    acceptedModifiers: Qt.NoModifier
    onTapped: {
      if (root.workspaceGestureConsumed) {
        root.workspaceGestureConsumed = false
        return
      }
      root.dispatchPointerAction("left", {})
    }
  }

  TapHandler {
    enabled: root.presentationActive && !root.workspaceInputSuppressed
    acceptedButtons: Qt.LeftButton
    acceptedModifiers: Qt.ControlModifier
    onTapped: root.dispatchPointerAction("left", { control: true })
  }

  TapHandler {
    enabled: root.presentationActive && !root.workspaceInputSuppressed
    acceptedButtons: Qt.MiddleButton
    acceptedModifiers: Qt.NoModifier
    onTapped: root.dispatchPointerAction("middle", {})
  }

  TapHandler {
    enabled: root.presentationActive && !root.workspaceInputSuppressed
    acceptedButtons: Qt.MiddleButton
    acceptedModifiers: Qt.ControlModifier
    onTapped: root.dispatchPointerAction("middle", { control: true })
  }

  TapHandler {
    enabled: root.presentationActive && !root.workspaceInputSuppressed
    acceptedButtons: Qt.RightButton
    // Right click owns the context menu regardless of keyboard modifiers.
    acceptedModifiers: Qt.KeyboardModifierMask
    onTapped: {
      root.previewDismissRequested()
      contextMenu.open()
    }
  }

  WheelHandler {
    id: wheelHandler

    enabled: root.presentationActive && root.runningCount >= 2
      && root.applicationActions.scrollAction === "cycle-windows" && !root.workspaceInputSuppressed
    target: null
    onWheel: event => {
      event.accepted = false

      var verticalDelta = DockWindowModel.dominantVerticalWheelDelta(
        event.angleDelta.x, event.angleDelta.y)
      if (verticalDelta === 0) return

      var now = Date.now()
      root.wheelRemainder = DockWindowModel.wheelRemainderForTimestamp(
        root.wheelRemainder, root.lastWheelTimestamp, now, 220)
      root.lastWheelTimestamp = now

      var accumulated = DockWindowModel.accumulateWheelSteps(
        root.wheelRemainder, verticalDelta, 120)
      root.wheelRemainder = accumulated.remainder
      var direction = DockWindowModel.wheelStepDirection(accumulated.steps)
      if (direction === 0) return

      var cycled = root.dispatchPointerAction(
        "scroll", {}, { direction: direction })
      event.accepted = cycled
    }
  }

  // Separate from pin reordering: both axes, activate on press so
  // layer-shell can keep the grab, and no target translation.
  function updateWorkspaceGesture(scenePoint, pressPoint) {
    if (root.workspaceGestureOwned) {
      if (root.workspaceDrag && root.workspaceDrag.sourceItem === root)
        root.workspaceDrag.updatePointer(scenePoint)
      return
    }
    var dx = scenePoint.x - pressPoint.x
    var dy = scenePoint.y - pressPoint.y
    if (Math.sqrt(dx * dx + dy * dy) < Application.styleHints.startDragDistance)
      return
    root.workspaceGestureOwned = true
    root.workspaceGestureConsumed = true
    root.dismissPopups()
    root.previewDismissRequested()
    if (root.workspaceDrag)
      root.workspaceDrag.begin(root, root.runningToplevels,
        scenePoint, applicationArtwork.renderedSource)
  }

  DragHandler {
    id: workspaceDragHandler
    enabled: root.workspaceDragEnabled && root.presentationActive
      && (active || root.workspaceGestureOwned
        || root.presentationVisible && root.runningCount > 0
        && !root.sticky && !root.workspaceInputSuppressed)
    target: null
    acceptedButtons: Qt.LeftButton
    dragThreshold: 0
    xAxis.enabled: true
    yAxis.enabled: true
    grabPermissions: PointerHandler.CanTakeOverFromItems
      | PointerHandler.CanTakeOverFromHandlersOfDifferentType
    cursorShape: Qt.ClosedHandCursor
    onActiveChanged: {
      if (active) {
        workspaceReleaseCleanup.stop()
        root.workspaceGestureConsumed = false
        root.updateWorkspaceGesture(
          centroid.scenePosition, centroid.scenePressPosition)
      } else {
        // active=false also means cancellation. Only a released exclusive
        // grab may commit; this next-turn fallback only cancels/cleans up.
        workspaceReleaseCleanup.restart()
      }
    }
    onActiveTranslationChanged: if (active)
      root.updateWorkspaceGesture(
        centroid.scenePosition, centroid.scenePressPosition)
    onGrabChanged: (transition, point) => root.workspaceGrabChanged(transition, point)
    onCanceled: root.cancelWorkspaceDrag("grab stolen")
    onEnabledChanged: if (!enabled) root.cancelWorkspaceDrag("handler disabled")
  }

  Timer {
    id: workspaceReleaseCleanup
    interval: 0
    repeat: false
    onTriggered: {
      root.cancelWorkspaceDrag("grab ended without release")
      root.workspaceGestureOwned = false
      root.workspaceGestureConsumed = false
    }
  }

  DragHandler {
    id: dragHandler

    enabled: root.presentationActive && root.pinnedItem && !root.originOnly
      && !root.workspaceInputSuppressed
    target: null
    acceptedButtons: Qt.LeftButton
    acceptedModifiers: Qt.NoModifier
    xAxis.enabled: !root.vertical
    yAxis.enabled: root.vertical
    onActiveChanged: {
      if (active) {
        root.previewDismissRequested()
        root.dragStarted(root.itemIndex)
      } else {
        root.dragFinished()
      }
    }
    onActiveTranslationChanged: {
      if (active)
        root.dragMoved((root.vertical ? root.y + root.height / 2 : root.x + root.width / 2)
          + (root.vertical ? activeTranslation.y : activeTranslation.x))
    }
  }

  DockContextMenu {
    id: contextMenu

    anchorItem: root
    position: root.position
    autoHide: root.autoHide
    pinnedItem: root.pinnedItem
    runningToplevels: root.presentationActive ? root.runningToplevels : []
    windowActions: root.windowActions
    herdrAgentActions: root.herdrAgentActions
    interfaceAnimationsEnabled: root.interfaceAnimationsEnabled
    originOnly: root.originOnly
    // The Change Icon dialog keeps the dock shown after the menu closes.
    onVisibleChanged: root.syncMenuOpen()
    onIconDialogOpenChanged: root.syncMenuOpen()
    onOpenNewWindow: root.launch()
    onAddApplication: root.addApplicationRequested()
    onRemoveFromDock: root.removeRequested(root.desktopId)
    onHideFromDock: root.hideRequested(root.desktopId)
    onToggleAutoHide: root.autoHideToggled(!root.autoHide)
  }
}
