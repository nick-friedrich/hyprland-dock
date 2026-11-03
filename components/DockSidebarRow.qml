pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Ui as Ui
import "DockSidebarInteractionModel.js" as InteractionModel
import "DockSidebarModel.js" as SidebarModel
import "DockHerdrModel.js" as HerdrModel
import "DockIconModel.js" as DockIconModel
import "DockBadgeModel.js" as BadgeModel
import "DockBrowserActivityModel.js" as ActivityModel

// Hierarchy row for the approved sidebar direction: Lucide monitor icon +
// two-line identity, workspace badge-only identity, continuous tree guides,
// focused accent rail, and modest selection fills. Domain actions stay on
// DockSidebarRowInput / fold. Section card fills live in DockSidebarViewport.
Item {
  id: root
  required property var row
  required property var controller
  property var viewport: null
  property var appearance: null
  property string panelConnector: ""
  // Owning PanelWindow for external-drag surface ownership.
  property var navigationOwner: null
  // Presentation-only eligibility supplied by DockSidebarViewport. This keeps
  // cached/offscreen rows from running their local working-state timer.
  property bool herdrAnimationEligible: false
  readonly property var input: rowInput
  readonly property string desktopId: String(row.desktopId || "")
  readonly property var applications: DesktopEntries.applications.values || []
  readonly property var entry: {
    var modelRevision = applications.length
    if (row.item && row.item.entry) return row.item.entry
    if (!root.desktopId) return null
    return DesktopEntries.byId(root.desktopId)
  }
  readonly property var browserProfileService: controller.host ? controller.host.browserProfileService : null
  readonly property string browserProfileKey: profile ? profile.key : ""
  readonly property bool navigable: ["window", "workspace", "application", "launcher", "browser-tab"].indexOf(kind) >= 0
  required property bool collapsed
  required property real rowHeight
  readonly property string rowKey: row.key
  readonly property string kind: row.kind
  readonly property var liveWindowIconRule: kind === "window" && row.toplevel
    ? DockIconModel.matchWindowRule(controller.windowIconOverrides || [],
        String(row.toplevel.appId || ""), String(row.toplevel.title || ""))
    : null
  readonly property string liveWindowOverrideSource: liveWindowIconRule
    ? String(liveWindowIconRule.source || "") : ""
  readonly property bool hasArtwork: kind === "window" || kind === "application" || kind === "launcher"
  readonly property bool nestedWindow: kind === "window" && row.nested === true
  readonly property bool nestedTab: kind === "browser-tab"
  readonly property bool nestedHerdr: kind === "herdr-agent" || kind === "herdr-state"
  readonly property bool nestedChild: nestedTab || nestedHerdr
  readonly property bool herdrActionable: kind === "herdr-agent" && row.actionable === true
    && row.focusAgentSupported === true
  readonly property bool herdrStatusDotVisible: !root.collapsed
    && (kind === "herdr-agent" || kind === "herdr-state")
  readonly property string normalizedHerdrStatus: HerdrModel.normalizeStatus(row.status)
  readonly property bool herdrWorkingStatusTarget: kind === "herdr-agent"
  readonly property bool herdrWorkingStatus: root.herdrWorkingStatusTarget
    && root.normalizedHerdrStatus === "working"
  readonly property string tabFaviconSource: nestedTab
    ? DockIconModel.faviconFileUrl(String(row.faviconPath || "")) : ""
  readonly property bool tabFaviconReady: nestedTab && tabFaviconSource !== ""
    && tabFavicon.status === Image.Ready
  readonly property bool soleWindow: kind === "window" && row.soleWindow === true
  readonly property bool tabsExpandable: kind === "window" && row.tabsExpandable === true
  readonly property bool appExpandable: kind === "application" && row.expandable === true
  readonly property bool herdrAssociated: kind === "window" && row.herdrAssociated === true
  readonly property bool herdrExpandable: herdrAssociated && row.herdrExpandable === true
  readonly property bool herdrFolded: herdrAssociated && row.herdrFolded === true
  // Claude parents fold sessions; Herdr and T3 parents keep the agents wording.
  readonly property bool herdrClaudeParent: herdrAssociated
    && String(row.herdrServerId || "").indexOf("claude:") === 0
  readonly property string herdrFoldNoun: herdrClaudeParent ? "Sessions" : "Agents"
  readonly property var herdrStatusCounters: {
    if (!herdrAssociated) return []
    var values = row.herdrStatusCounters
    return Array.isArray(values) ? values : []
  }
  readonly property bool herdrCountersVisible: !root.collapsed && herdrAssociated
    && herdrStatusCounters.length > 0
  readonly property bool herdrWorkingCounter: {
    for (var i = 0; i < herdrStatusCounters.length; ++i) {
      if (HerdrModel.normalizeStatus(herdrStatusCounters[i].status) === "working")
        return true
    }
    return false
  }
  readonly property bool herdrWindowWorkingAnimationActive: herdrAssociated
    && root.herdrFolded && herdrWorkingCounter
    && root.animationsEnabled && root.herdrAnimationEligible
  // Expanded rows already show their working agents below; only folded
  // parents carry the window-level indicator.
  readonly property bool herdrWindowWorkingIndicatorVisible: herdrAssociated
    && root.herdrFolded && herdrWorkingCounter
  readonly property real herdrWindowWorkingIndicatorGap: Style.space(5)
  readonly property real herdrWindowWorkingIndicatorReservation:
    herdrWindowWorkingIndicatorVisible ? 10 + herdrWindowWorkingIndicatorGap : 0
  readonly property string herdrKindLabel: kind === "herdr-agent"
    ? InteractionModel.herdrAgentKindLabel({ agentKind: row.agentKind || "" })
    : ""
  // Kind moves onto the two-line secondary row; do not reserve side kind width.
  readonly property bool herdrKindVisible: false
  readonly property string herdrAgentSubtitle: kind === "herdr-agent"
    ? String(row.subtitle || "") : ""
  readonly property bool herdrTwoLineLabels: !root.collapsed && kind === "herdr-agent"
  readonly property int windowCount: kind === "application" ? Number(row.windowCount || row.windows && row.windows.length || 0) : 0
  readonly property int treeDepth: Number(row.treeDepth || 0)
  readonly property bool isLastSibling: row.isLastSibling !== false
  readonly property var ancestorContinues: row.ancestorContinues || []
  readonly property real workspaceCardInset: viewport && viewport.workspaceCardInset !== undefined
    ? Number(viewport.workspaceCardInset) : Style.space(5)
  readonly property var treeLayout: InteractionModel.sidebarTreeGuideLayout(root.workspaceCardInset)
  readonly property bool insideWorkspaceCard: kind !== "monitor" && kind !== "section"
    && (kind === "workspace" || !!row.workspaceKey)
  // Populated expanded workspaces put the badge on the first child.
  readonly property bool inlineWorkspaceLayout: !root.collapsed
    && (root.leadingWorkspaceBadgeVisible || row.inlineWorkspaceGroup === true)
  readonly property var inlineWorkspaceGeometry: InteractionModel.sidebarInlineWorkspaceGeometry(
    root.workspaceCardInset, Style.space)
  readonly property real inlineBadgeLayoutWidth: root.inlineWorkspaceGeometry.badgeWidth
  // Empty workspace cards must not draw a fake header→children stem.
  readonly property bool workspaceHasChildren: {
    if (kind !== "workspace") return false
    var apps = row.target && row.target.applications
    return !!(apps && apps.length > 0)
  }
  readonly property string monitorTitle: kind === "monitor"
    ? String(row.title || row.label || row.connector || "Monitor") : ""
  readonly property string monitorConnector: kind === "monitor" ? String(row.connector || "") : ""
  // Card/projection order may follow workspaceMonitorOrder; miniatures use
  // physical x/y (monitorMetadata with empty order) and join focus by
  // connector/identity from projection.monitorSections.
  readonly property var monitorTopologyStrip: {
    var screens = controller.screens
    var monitors = controller.monitors
    var proj = controller.projection
    var focusSections = (proj && proj.monitorSections) || []
    return SidebarModel.physicalMonitorStrip(screens, monitors, focusSections)
  }
  readonly property int monitorStripCount: monitorTopologyStrip.length
  readonly property int monitorSectionIndex: Number(row.sectionIndex || 0)
  readonly property int monitorStripIndex: InteractionModel.monitorStripIndexFor(
    root.monitorTopologyStrip, root.row.monitorIdentity, root.monitorConnector)
  readonly property string monitorStripOrdinal: monitorStripIndex >= 0
    ? (monitorStripIndex + 1) + "/" + monitorStripCount : ""
  // Browser parents keep a stable desktop-entry label; identity still works when
  // the tab provider is down (DEFAULT_BROWSER_CLASSES) or tabs are folded.
  readonly property bool isBrowserWindow: {
    if (kind !== "window") return false
    var service = root.browserProfileService
    var serviceRevision = service ? Number(service.revision || 0) : 0
    var catalogRevision = applications.length
    var classes = ActivityModel.effectiveBrowserClasses(service ? service.classes : [])
    var tracker = controller.host ? controller.host.badgeTracker : null
    var aliases = tracker ? tracker.identityAliases : ({})
    return BadgeModel.strictIdentityMatches(root.desktopId, root.entry, classes, aliases)
  }
  readonly property string windowTitle: {
    if (kind === "browser-tab" || kind === "herdr-agent" || kind === "herdr-state")
      return String(row.title || (kind === "herdr-state"
        ? String(row.serverLabel || "").trim() || "Herdr"
        : kind === "herdr-agent" ? "Coding agent" : "Tab"))
    if (kind === "window" && row.toplevel)
      return String(row.toplevel.title || "").trim() || "Untitled window"
    return ""
  }
  readonly property string liveTitle: {
    if (kind === "herdr-agent" || kind === "herdr-state")
      return InteractionModel.sidebarWindowDisplayTitle({
        kind: kind,
        title: String(row.title || "")
      })
    if (kind === "browser-tab" || kind === "window")
      return InteractionModel.sidebarWindowDisplayTitle({
        kind: kind,
        isBrowser: root.isBrowserWindow,
        isHerdr: root.herdrAssociated,
        herdrLabel: String(row.herdrDisplayLabel || ""),
        entryName: root.entry ? String(root.entry.name || "") : String(row.label || ""),
        windowTitle: root.windowTitle,
        tabTitle: kind === "browser-tab" ? String(row.title || "") : "",
        pillCount: root.attention.count,
        countPillVisible: alertCount.visible
      })
    if (kind === "application") return String(row.label || "")
    if (kind === "monitor") return root.monitorTitle
    if (kind === "workspace") return root.workspaceBadgeText
    return String(row.label || "")
  }
  readonly property string secondaryPath: kind === "window"
    ? InteractionModel.sidebarWindowSecondaryTitle({
        kind: kind,
        isBrowser: root.isBrowserWindow,
        isHerdr: root.herdrAssociated,
        entryName: root.entry ? String(root.entry.name || "") : String(row.label || ""),
        windowTitle: root.windowTitle
      }) : ""
  // Prefer shared model display label (id:10 → Work); identity is fallback only.
  readonly property string workspaceFullName: kind === "workspace"
    ? InteractionModel.workspaceBadgeLabel(row.workspaceIdentity || "", row.label || "")
    : ""
  readonly property string workspaceBadgeText: InteractionModel.compactWorkspaceBadgeLabel(
    root.workspaceFullName)
  readonly property var leadingWorkspace: !root.collapsed && row.leadingWorkspace
    ? row.leadingWorkspace : null
  readonly property bool leadingWorkspaceBadgeVisible: !!root.leadingWorkspace
  readonly property string leadingWorkspaceFullName: root.leadingWorkspace
    ? InteractionModel.workspaceBadgeLabel(root.leadingWorkspace.workspaceIdentity || "",
      root.leadingWorkspace.label || "") : ""
  readonly property string leadingWorkspaceBadgeText: InteractionModel.compactWorkspaceBadgeLabel(
    root.leadingWorkspaceFullName)
  readonly property string inlineWorkspaceBadgeKey: root.leadingWorkspace
    ? String(root.leadingWorkspace.key || "") : ""
  readonly property bool inlineWorkspaceBadgeFocused: leadingWorkspaceBadge.activeFocus
  readonly property var inlineWorkspaceBadgeAnchor: leadingWorkspaceBadge
  function focusInlineWorkspaceBadge(reason) {
    if (!root.leadingWorkspaceBadgeVisible) return false
    leadingWorkspaceBadge.pointerFocused = false
    leadingWorkspaceBadge.forceActiveFocus(
      reason === undefined ? Qt.TabFocusReason : reason)
    return leadingWorkspaceBadge.activeFocus
  }
  // Rail keeps the compact two-code-point token; tooltips/expanded keep full name.
  readonly property string workspaceRailLabel: {
    if (kind !== "workspace") return ""
    var full = root.workspaceFullName || String(row.label || root.liveTitle || "")
    return InteractionModel.compactWorkspaceBadgeLabel(full)
  }
  readonly property bool focusedWindow: kind === "window" && row.toplevel && row.toplevel.activated === true
  readonly property bool activeBrowserTab: nestedTab
    && row.active === true
    && !!row.toplevel
    && row.toplevel.activated === true
  readonly property bool containsFocusedWindow: {
    if (kind !== "application" || !row.windows) return false
    for (var i = 0; i < row.windows.length; ++i) {
      var member = row.windows[i]
      if (member && member.toplevel && member.toplevel.activated === true) return true
    }
    return false
  }
  readonly property string accessibleLabel: {
    var attention = root.attention
    var state = root.windowState
    var alertBits = ""
    if (attention.countVisible && attention.count > 0)
      alertBits += " · " + attention.count + " alerts"
    else if (attention.severity === "urgent")
      alertBits += " · Urgent"
    else if (attention.severity === "attention")
      alertBits += " · Attention"
    if (kind === "monitor")
      return root.monitorTitle + (root.monitorConnector ? " · " + root.monitorConnector : "")
    if (kind === "workspace")
      return "Workspace " + root.workspaceFullName
        + (row.active ? " · Active" : "")
        + (row.monitorIdentity ? " · Monitor " + row.monitorIdentity : "")
    if (kind === "browser-tab")
      return (row.active === true ? "Active tab: " : "Tab: ") + root.windowTitle + alertBits
        + (attention.muted ? " · Alerts excluded from totals" : "")
    if (kind === "herdr-agent")
      return (row.serverLabel === "T3 Code" ? "T3 Code thread: "
          : row.serverLabel === "Claude" ? "Claude session: " : "Herdr agent: ") + liveTitle
        + (root.herdrAgentSubtitle ? " · " + root.herdrAgentSubtitle : "")
        + " · " + InteractionModel.herdrStatusAccessibleText(row.status)
        + (root.herdrActionable && root.controller.herdrFocusErrorFor(root.rowKey)
          ? " · Focus failed (" + root.controller.herdrFocusErrorFor(root.rowKey) + ")"
          : "")
    if (kind === "herdr-state")
      return (row.serverLabel === "T3 Code" ? "T3 Code: "
          : row.serverLabel === "Claude" ? "Claude: " : "Herdr: ") + liveTitle
    var titleLabel = kind === "window"
      ? InteractionModel.sidebarWindowTooltipTitle({
        kind: "window",
        isBrowser: root.isBrowserWindow,
        isHerdr: root.herdrAssociated,
        displayTitle: liveTitle,
        windowTitle: root.windowTitle
      })
      : liveTitle
    var herdrCountBits = ""
    if (root.herdrAssociated && root.herdrStatusCounters.length) {
      for (var ci = 0; ci < root.herdrStatusCounters.length; ++ci) {
        var counter = root.herdrStatusCounters[ci]
        herdrCountBits += " · " + InteractionModel.herdrStatusAccessibleText(counter.status)
          + " " + String(counter.count)
      }
    }
    return titleLabel
      + (kind === "application" && windowCount > 1 ? " · " + windowCount : "")
      + herdrCountBits
      + (root.leadingWorkspaceFullName
        ? " · Workspace " + root.leadingWorkspaceFullName
        : (row.workspaceIdentity ? " · Workspace " + row.workspaceIdentity : ""))
      + (row.monitorIdentity ? " · Monitor " + row.monitorIdentity : "")
      + (state.fullscreen ? " · Fullscreen" : "")
      + (state.pinned ? " · Pinned" : "")
      + (state.minimized ? " · Minimized" : "")
      + alertBits
      + (containsFocusedWindow && row.folded ? " · Contains focused window" : "")
      + (tabsExpandable ? (row.tabsFolded ? " · Tabs folded" : " · Tabs expanded") : "")
      + (herdrExpandable ? " · " + root.herdrFoldNoun + (root.herdrFolded ? " folded" : " expanded") : "")
  }
  readonly property var profile: hasArtwork ? controller.profileForRow(row) : null
  readonly property var attention: controller.attentionForRow(row)
  // scopeRevision tracks Hyprland fullscreen events; hyprToplevels carries the
  // live lastIpcObject used by windowStateForRow.
  readonly property var windowState: {
    var revision = controller.scopeRevision
    var handles = controller.hyprToplevels
    return controller.windowStateForRow(row)
  }
  readonly property bool alertControlFocused: controller.alertControlKey === root.rowKey
  readonly property bool showAlertControl: !root.collapsed && root.nestedTab
    && !!root.attention.serviceId
    && (root.attention.count > 0 || root.attention.muted === true
      || root.attention.countVisible === true)
  readonly property real padding: root.collapsed
    ? Math.min(Style.space(8), Math.max(2, width / 8))
    : Style.space(8)
  readonly property real iconSize: {
    if (!hasArtwork && kind !== "monitor") return 0
    if (collapsed) {
      if (kind === "monitor") return 16
      if (hasArtwork) return 22
      return 0
    }
    if (kind === "monitor") return 24
    return 18
  }
  readonly property real artX: {
    if (collapsed) return 0
    if (kind === "workspace") return root.treeLayout.badgeLeft
    if (root.inlineWorkspaceLayout) {
      if (root.leadingWorkspaceBadgeVisible || root.treeDepth <= 1)
        return root.inlineWorkspaceGeometry.artX
      return InteractionModel.sidebarTreeIconX(root.workspaceCardInset, Math.max(1, root.treeDepth))
        + root.inlineWorkspaceGeometry.guideOffset
    }
    if (nestedChild || hasArtwork)
      return InteractionModel.sidebarTreeIconX(root.workspaceCardInset, Math.max(1, root.treeDepth))
    return root.padding
  }
  readonly property real baseLabelX: {
    if (root.leadingWorkspaceBadgeVisible && root.hasArtwork)
      return root.inlineWorkspaceGeometry.labelX
    if (root.nestedChild)
      return root.artX + 14 + Style.space(8)
    if (root.hasArtwork) return artwork.x + artwork.width + Style.space(4)
    return root.padding
  }
  // Shared fill/rail horizontal bounds (tree-indented vs whole-card workspace).
  readonly property var selectionInsets: InteractionModel.sidebarSelectionInsets({
    kind: root.kind,
    collapsed: root.collapsed,
    insideWorkspaceCard: root.insideWorkspaceCard,
    workspaceCardInset: root.workspaceCardInset,
    artX: root.artX
  })
  readonly property real selectionLeft: selectionInsets.left
  readonly property real selectionRight: selectionInsets.right
  readonly property bool railNumericAlert: InteractionModel.sidebarRowHasNumericAlert(
    collapsed, root.attention.countVisible)
  readonly property var rowMetrics: InteractionModel.sidebarRowMetrics(
    row, collapsed, rowHeight, Style.space, root.railNumericAlert)
  readonly property bool windowFooterDrag: controller.rowDragActive
    && controller.dragSession && controller.dragSession.target
    && controller.dragSession.target.kind === "window"
  readonly property bool isMonitorFinal: viewport
    && InteractionModel.isMonitorFinalKey(row.key, viewport.sectionSpans)
  readonly property bool showNewWorkspaceFooter: root.windowFooterDrag && root.isMonitorFinal
  readonly property real footerTargetHeight: InteractionModel.newWorkspaceFooterTargetHeight(collapsed)
  readonly property real footerExtraHeight: InteractionModel.newWorkspaceFooterExtra(collapsed, Style.space)
  readonly property string footerKey: {
    if (!root.showNewWorkspaceFooter) return ""
    if (viewport && typeof viewport.footerKeyForRowKey === "function") {
      var keyed = viewport.footerKeyForRowKey(row.key)
      if (keyed) return keyed
    }
    var identity = String(row.monitorIdentity || "")
    if (!identity) return ""
    return InteractionModel.newWorkspaceFooterKey(identity)
  }
  readonly property bool footerDropTarget: root.showNewWorkspaceFooter && root.footerKey !== ""
    && controller.dragTarget && controller.dragTarget.key === root.footerKey
  readonly property string footerMonitorName: {
    var monitorRow = null
    if (controller && controller.rowsByKey) {
      var monitorKey = String(row.monitorKey || "")
      if (row.kind === "monitor") monitorRow = row
      else if (monitorKey) monitorRow = controller.rowsByKey[monitorKey] || null
      if (!monitorRow && row.monitorIdentity) {
        var keys = Object.keys(controller.rowsByKey || {})
        for (var i = 0; i < keys.length; ++i) {
          var candidate = controller.rowsByKey[keys[i]]
          if (candidate && candidate.kind === "monitor"
              && String(candidate.monitorIdentity || "") === String(row.monitorIdentity || "")) {
            monitorRow = candidate
            break
          }
        }
      }
    }
    if (monitorRow)
      return String(monitorRow.title || monitorRow.label || monitorRow.connector || monitorRow.monitorIdentity || "")
    return String(row.monitorIdentity || "")
  }
  readonly property string footerAccessibleLabel: "New workspace on " + root.footerMonitorName
  readonly property real placeholderBefore: root.viewport && typeof root.viewport.placeholderBefore === "function"
    ? root.viewport.placeholderBefore(root.rowKey) : 0
  readonly property real placeholderAfter: root.viewport && typeof root.viewport.placeholderAfter === "function"
    ? root.viewport.placeholderAfter(root.rowKey) : 0
  readonly property real gapBefore: rowMetrics.gapBefore + root.placeholderBefore
  readonly property real baseGapAfter: rowMetrics.gapAfter
  readonly property real gapAfter: rowMetrics.gapAfter + root.placeholderAfter
    + (root.showNewWorkspaceFooter ? root.footerExtraHeight : 0)
  readonly property real contentY: rowMetrics.contentY + root.placeholderBefore
  readonly property real sectionGap: gapBefore
  readonly property real contentHeight: rowMetrics.contentHeight
  readonly property real computedHeight: rowMetrics.height + root.placeholderBefore + root.placeholderAfter
    + (root.showNewWorkspaceFooter ? root.footerExtraHeight : 0)
  readonly property string monitorOrdinal: String(monitorSectionIndex + 1)
  objectName: "sidebar-row:" + rowKey
  implicitHeight: computedHeight
  height: computedHeight
  clip: true
  Accessible.role: kind === "application" ? Accessible.Button : Accessible.ListItem
  Accessible.name: accessibleLabel
  Keys.forwardTo: root.viewport ? [root.viewport.keyboard] : []
  // Qt reports the focus reason only on Controls, not on a plain Item, so pointer
  // focus is tracked explicitly: mouse-focused rows show no keyboard focus
  // decoration when the OnDemand layer regains keyboard focus on re-entry.
  property bool pointerFocused: false
  readonly property bool keyboardFocusVisible: root.activeFocus && !root.pointerFocused
  function focusFromPointer() {
    root.pointerFocused = true
    root.forceActiveFocus(Qt.MouseFocusReason)
  }
  onActiveFocusChanged: {
    if (activeFocus) root.controller.focusedRowKey = root.rowKey
    else root.pointerFocused = false
  }
  opacity: InteractionModel.dragSourceOpacity(root.row, root.controller.dragSession)

  // Right edge reserved for mute / fold chevrons. Matches fold/tabsFold
  // anchors.rightMargin (workspace-card inset), not left padding.
  readonly property real herdrRightChromeWidth: {
    if (root.collapsed) return 0
    var w = 0
    if (root.insideWorkspaceCard) w += root.workspaceCardInset
    if (fold.visible) w += fold.width
    if (tabsFold.visible) w += tabsFold.width
    if (herdrFold.visible) w += herdrFold.width
    if (root.showAlertControl) w += Style.space(22) + Style.space(4)
    return w
  }
  // Left edge of the fold stack; counters sit immediately to its left.
  readonly property real herdrFoldLeft: {
    if (!content.width) return 0
    return Math.max(0, content.width - root.herdrRightChromeWidth)
  }
  readonly property real herdrCountersRightLimit: root.herdrFoldLeft
  // Prefer showing every nonzero counter at full width; name/state yield.
  readonly property real herdrCountersNaturalWidth: herdrCountersVisible
    ? herdrCounters.implicitWidth : 0
  readonly property bool herdrStateStripFits: {
    if (!root.herdrCountersVisible) return true
    if (root.kind !== "window") return true
    if (!(root.windowState.fullscreen || root.windowState.pinned || root.windowState.minimized))
      return true
    var gap = Style.space(6)
    var labelRight = label.x + Math.min(label.implicitWidth, label.width)
    var countersLeft = root.herdrFoldLeft - root.herdrCountersNaturalWidth - gap
    // stateStrip is Style.space(14) tall with up to 3×12 icons + spacing.
    var stripW = 0
    if (root.windowState.fullscreen) stripW += 12
    if (root.windowState.pinned) stripW += (stripW ? Style.space(4) : 0) + 12
    if (root.windowState.minimized) stripW += (stripW ? Style.space(4) : 0) + 12
    return labelRight + gap + stripW + gap <= countersLeft
  }

  readonly property bool animationsEnabled: root.controller.settings
    && root.controller.settings.interfaceAnimationsEnabled !== false
  readonly property bool herdrWorkingAnimationActive: root.herdrStatusDotVisible
    && root.herdrWorkingStatus
    && root.animationsEnabled
    && root.herdrAnimationEligible
  readonly property bool dropTarget: root.controller.dragTarget
    && root.controller.dragTarget.key === root.rowKey
  readonly property bool workspaceDropTarget: root.windowFooterDrag && root.controller.dragTarget
    && root.controller.dragTarget.identity === root.row.workspaceIdentity
  readonly property bool footerBlocked: root.windowFooterDrag && root.controller.windowActions
    && root.controller.windowActions.windowWorkspacePin(root.controller.dragSession.target.toplevel) !== null
  readonly property color footerColor: root.footerBlocked ? Color.urgent
    : root.footerDropTarget ? Color.accent : Color.muted
  // Persistent included-alert window-name nudge (label Translate only).
  property int attentionNudgeX: 0
  DockHerdrStatusColors { id: herdrStatusColors }
  readonly property int attentionDisplayCount: root.attention.countVisible
    ? root.attention.count : 0
  readonly property bool persistentSelected: root.focusedWindow || root.activeBrowserTab
  readonly property bool persistentContext: (root.containsFocusedWindow && root.row.folded)
    || false
  readonly property color persistentFill: {
    if (root.focusedWindow)
      return Util.alpha(Color.accent, 0.18)
    if (root.activeBrowserTab)
      return Util.alpha(Color.foreground, 0.06)
    if (root.containsFocusedWindow && root.row.folded)
      return Util.alpha(Color.accent, 0.12)
    return "transparent"
  }
  // Monitor headings stay visually passive: tooltip via passiveHover, active
  // border + workspace-drag highlight live on the section card in the viewport.
  readonly property color rowFill: InteractionModel.composeRowFill({
    dropTarget: !root.windowFooterDrag && root.kind !== "monitor" && root.dropTarget,
    pressed: !root.controller.rowDragActive && root.kind !== "monitor" && root.input.pressed,
    activeFocus: root.keyboardFocusVisible,
    hovered: !root.controller.rowDragActive && root.kind !== "monitor"
      && (root.input.hovered || passiveHover.hovered),
    navigable: InteractionModel.rowHoverFillEligible(root.kind, root.herdrActionable),
    persistentSelected: root.persistentSelected,
    persistentContext: root.persistentContext,
    dropFill: Style.pressedFillFor(Color.accent, Color.accent),
    pressedFill: Style.pressedFillFor(Color.foreground, Color.accent),
    focusFill: Style.focusFillFor(Color.foreground, Color.accent),
    selectedHoverFill: root.activeBrowserTab
      ? Util.alpha(Color.foreground, 0.10)
      : Util.alpha(Color.accent, Math.min(0.42, Style.selectionFillAlpha + Style.hoverFillAlpha)),
    contextHoverFill: Util.alpha(Color.accent, Math.min(0.24, 0.12 + Style.hoverFillAlpha)),
    hoverFill: Util.alpha(Color.foreground, 0.06),
    persistentFill: root.persistentFill
  })

  // Fill layer uses selectionLeft/Right (tree-indented vs whole-card). Guides
  // and fill stay stationary; only the window-name label translates.
  Item {
    id: fillLayer
    anchors.left: parent.left
    anchors.right: parent.right
    y: root.contentY
    height: root.contentHeight
    z: 0

    Ui.BorderSurface {
      anchors.fill: parent
      anchors.leftMargin: root.selectionLeft
      anchors.rightMargin: root.selectionRight
      radius: Style.cornerRadius
      color: root.viewport && root.viewport.dropFlashKey === root.rowKey
        ? Qt.tint(root.rowFill, Util.alpha(Color.accent, 0.22 * root.viewport.dropFlashOpacity)) : root.rowFill
      borderSpec: root.keyboardFocusVisible
        ? Border.controlSpec("focus", Color.foreground, Color.accent) : Border.none()
      Behavior on color {
        enabled: root.animationsEnabled
        ColorAnimation { duration: 120 }
      }
    }

    // Focused window: 2px accent rail at the same selection left edge.
    Rectangle {
      visible: root.focusedWindow
      width: 2
      radius: 1
      anchors.left: parent.left
      anchors.leftMargin: root.selectionLeft
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(4)
      color: Color.accent
    }
  }

  // Continuous tree guides (expanded only). Parent of content so they span the
  // first-child 4px gap; never drawn through inter-workspace/monitor gaps.
  Item {
    id: treeGuides
    anchors.fill: parent
    z: 1
    visible: !root.collapsed
    readonly property color guideColor: Util.alpha(Color.foreground, 0.18)
    readonly property real guideTop: root.row.layoutGapBefore === "children" ? 0 : root.contentY
    readonly property real contentMid: root.contentY + root.contentHeight / 2
    readonly property real contentBottom: root.contentY + root.contentHeight
    // Chip bottom edges in row coordinates. Vertical guides start here so no
    // line is ever painted through a translucent workspace badge; horizontal
    // connectors start at the chip's right edge for the same reason.
    readonly property real inlineBadgeBottom: root.contentY + leadingWorkspaceBadge.y
      + leadingWorkspaceBadge.height
    readonly property real workspaceBadgeBottom: root.contentY + workspaceBadge.y
      + workspaceBadge.height
    // Depth-1 stems use stemOffset so they stay under the badge (not under
    // the icons); artwork keeps geometry.artX on the guideOffset column.
    readonly property real stemOffset: root.inlineWorkspaceLayout
      ? root.inlineWorkspaceGeometry.stemOffset : 0
    // Deeper guide columns follow guideOffset so they sit at the center of
    // the parent row's rendered window icon, not its left edge.
    readonly property real guideOffset: root.inlineWorkspaceLayout
      ? root.inlineWorkspaceGeometry.guideOffset : 0
    // Only another *direct* row of this workspace continues the badge column.
    // Expanded tabs / windows / Herdr agents live in a deeper guide column and
    // never justify a downward stem beneath the badge.
    readonly property bool badgeStemExtendsDown: root.leadingWorkspaceBadgeVisible
      && !root.isLastSibling

    // Workspace stem from badge bottom down to first-child gap bridge.
    // Suppress on empty workspaces (no visible children / no applications).
    Rectangle {
      visible: root.kind === "workspace" && root.workspaceHasChildren
      x: root.treeLayout.guide0
      width: 1
      y: treeGuides.workspaceBadgeBottom
      height: Math.max(0, treeGuides.contentBottom - y)
      color: treeGuides.guideColor
    }

    // Inline badge stem: drops from the rendered badge's bottom edge at the
    // badge center, so it bridges into the next direct row without crossing
    // the chip. Sole first rows keep only the horizontal connector.
    Rectangle {
      visible: root.leadingWorkspaceBadgeVisible && treeGuides.badgeStemExtendsDown
      x: leadingWorkspaceBadge.x + leadingWorkspaceBadge.width / 2
      width: 1
      y: Math.max(treeGuides.contentMid, treeGuides.inlineBadgeBottom)
      height: Math.max(0, treeGuides.contentBottom - y)
      color: treeGuides.guideColor
    }

    Repeater {
      model: root.treeDepth >= 1 ? root.ancestorContinues.length : 0
      Rectangle {
        required property int index
        visible: root.ancestorContinues[index] === true
          && !(root.leadingWorkspaceBadgeVisible && index === 0)
        x: InteractionModel.sidebarTreeGuideColumnX(root.workspaceCardInset,
          index + 1, treeGuides.guideOffset, treeGuides.stemOffset)
        width: 1
        y: treeGuides.guideTop
        height: Math.max(0, treeGuides.contentBottom - y)
        color: treeGuides.guideColor
      }
    }

    Rectangle {
      id: ownStem
      // First inline row uses the badge stem; suppress the old header-relative stem.
      visible: root.treeDepth >= 1 && !root.leadingWorkspaceBadgeVisible
      x: InteractionModel.sidebarTreeGuideColumnX(root.workspaceCardInset,
        root.treeDepth, treeGuides.guideOffset, treeGuides.stemOffset)
      width: 1
      y: treeGuides.guideTop
      height: Math.max(0, (root.isLastSibling ? treeGuides.contentMid : treeGuides.contentBottom) - y)
      color: treeGuides.guideColor
    }

    Rectangle {
      visible: root.leadingWorkspaceBadgeVisible && (root.hasArtwork || root.nestedChild)
      x: leadingWorkspaceBadge.x + leadingWorkspaceBadge.width
      y: treeGuides.contentMid
      width: Math.max(0, root.artX - x - 2)
      height: 1
      color: treeGuides.guideColor
    }

    Rectangle {
      visible: !root.leadingWorkspaceBadgeVisible
        && root.treeDepth >= 1 && (root.hasArtwork || root.nestedChild)
      x: ownStem.x
      y: treeGuides.contentMid
      width: Math.max(0, root.artX - x - 2)
      height: 1
      color: treeGuides.guideColor
    }
  }

  // Inter-monitor gap is owned by section cards; no duplicate hairline.

  Item {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    y: root.contentY
    height: root.contentHeight
    z: 2
    clip: true

    // Official Lucide monitor SVG (expanded). Rail uses compact icon+ordinal.
    DockLucideIcon {
      id: monitorGlyph
      visible: root.kind === "monitor" && !root.collapsed
      x: root.padding
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      height: Style.space(16)
      iconName: "monitor"
      iconSize: Style.space(16)
      tint: root.dropTarget ? Color.accent : Color.foreground
      opacity: 0.85
    }

    Rectangle {
      id: workspaceBadge
      visible: root.kind === "workspace" && !root.collapsed
      x: root.treeLayout.badgeLeft
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      height: Style.space(22)
      radius: Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: root.workspaceDropTarget || root.row.focused
        ? Color.accent : Util.alpha(Color.foreground, 0.24)
      Text {
        id: badgeLabel
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(8))
        text: root.workspaceBadgeText
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: root.workspaceDropTarget || root.row.focused ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    // Populated expanded workspaces share the first application/window row.
    // Keep this as a separate hit target so its activation and context menu
    // still address the workspace rather than the child window.
    Rectangle {
      id: leadingWorkspaceBadge
      visible: root.leadingWorkspaceBadgeVisible
      objectName: "sidebar-inline-workspace-badge"
      // Context refresh validates anchors by rowKey. This badge targets the
      // synthetic workspace row, not the child application/window row.
      readonly property string rowKey: root.inlineWorkspaceBadgeKey
      property bool pointerFocused: false
      z: 4
      activeFocusOnTab: true
      x: root.inlineWorkspaceGeometry.badgeX
      anchors.verticalCenter: parent.verticalCenter
      // The badge and every sibling row consume the same fixed column.
      width: root.inlineBadgeLayoutWidth
      height: Style.space(22)
      radius: Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: ((leadingWorkspaceBadge.activeFocus && !leadingWorkspaceBadge.pointerFocused)
          || root.workspaceDropTarget || (root.leadingWorkspace && root.leadingWorkspace.focused))
        ? Color.accent : Util.alpha(Color.foreground, 0.24)
      Text {
        id: leadingWorkspaceBadgeLabel
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(8))
        text: root.leadingWorkspaceBadgeText
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: root.workspaceDropTarget || (root.leadingWorkspace && root.leadingWorkspace.focused)
          ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
      Accessible.role: Accessible.Button
      Accessible.name: "Workspace " + root.leadingWorkspaceFullName
      HoverHandler { id: leadingBadgeHover }
      DockToolTip {
        anchorItem: leadingWorkspaceBadge
        position: root.controller.edge
        requestedVisible: leadingBadgeHover.hovered
          && root.leadingWorkspaceBadgeText !== root.leadingWorkspaceFullName
        text: root.leadingWorkspaceFullName
        fontFamily: Style.font.family
        fontSize: Style.font.bodySmall
      }
      Accessible.onPressAction: {
        var target = root.controller.captureTarget(root.inlineWorkspaceBadgeKey)
        if (target && root.viewport)
          root.viewport.activate(target, false, root.panelConnector, Qt.NoModifier)
      }
      Keys.forwardTo: root.viewport ? [root.viewport.keyboard] : []
      onActiveFocusChanged: {
        if (activeFocus) root.controller.focusedRowKey = root.rowKey
        else leadingWorkspaceBadge.pointerFocused = false
      }
      DockSidebarRowInput {
        anchors.fill: parent
        controller: root.controller
        rowKey: root.leadingWorkspace ? root.leadingWorkspace.key : ""
        panelConnector: root.panelConnector
        navigationOwner: root.navigationOwner
        // The badge owns its own rectangle; child-target priority makes it win
        // over the enclosing row regardless of drag-entry order.
        externalPriority: 10
        workspaceHeader: true
        dragEnabled: true
        viewport: root.viewport
        enabled: leadingWorkspaceBadge.visible
        onFocusRequested: {
          leadingWorkspaceBadge.pointerFocused = true
          leadingWorkspaceBadge.forceActiveFocus(Qt.MouseFocusReason)
        }
        onActivated: function(target, control, connector, modifiers) {
          if (root.viewport) root.viewport.activate(target, control, connector, modifiers)
        }
        onContextRequested: target => {
          if (root.viewport) root.viewport.contextRequested(target, leadingWorkspaceBadge)
        }
        onDragMoved: point => {
          if (root.viewport) root.viewport.moveDrag(point)
        }
        onDragReleased: point => {
          if (root.viewport) root.viewport.finishDrag(point)
        }
      }
    }

    DockAppIcon {
      id: artwork
      visible: root.hasArtwork
      width: root.iconSize
      height: root.iconSize
      x: root.collapsed ? (content.width - width) / 2 : root.artX
      y: root.collapsed ? Style.space(10) : Math.round((content.height - height) / 2)
      roundedArtwork: false
      badgeRingColor: root.insideWorkspaceCard && root.viewport
        ? root.viewport.monitorFill : Color.background
      desktopId: String(root.row.desktopId || "")
      desktopIcon: root.entry ? String(root.entry.icon || "") : ""
      iconOverrides: root.controller.settings.iconOverrides || ({})
      windowOverrideSource: root.kind === "window"
        ? root.liveWindowOverrideSource : ""
      reloadRevision: root.controller.host.iconReloadRevision || 0
      profileKey: root.profile ? root.profile.key : ""
      profileName: root.profile && root.profile.entry ? String(root.profile.entry.name || "") : ""
      profileAvatarPath: root.profile && root.profile.entry ? String(root.profile.entry.avatarPath || "") : ""
      profileBadgesEnabled: root.controller.settings.browserProfileBadgesEnabled !== false
      opacity: root.row.minimized ? 0.65 : 1
    }

    // Rail alert count under the 22px icon (16px line; metrics add 5px bottom).
    // Compact badge keeps the same 36/58 shared height contract.
    Rectangle {
      id: railAlertCount
      objectName: "sidebar-rail-alert-count"
      visible: root.collapsed && root.hasArtwork && root.attention.countVisible
        && root.attention.text !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.space(10) + 22 + Style.space(5)
      height: Style.space(16)
      width: {
        var natural = railAlertLabel.implicitWidth + Style.space(4) * 2
        var available = Math.max(0, content.width - 4)
        return Math.min(available, Math.max(Style.space(16), natural))
      }
      radius: Style.space(3)
      color: Util.alpha(Color.accent, Math.min(0.14, Style.selectedFillAlpha))
      border.width: Style.space(1)
      border.color: Util.alpha(Color.accent, Math.min(0.40, Style.hoverBorderAlpha + 0.15))
      Text {
        id: railAlertLabel
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(8))
        height: parent.height
        text: root.attention.text
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: root.attention.severity === "urgent" ? Color.urgent : Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Image {
      id: tabFavicon
      visible: root.nestedTab && !root.collapsed && root.tabFaviconReady
      width: 14
      height: 14
      x: root.artX
      anchors.verticalCenter: parent.verticalCenter
      asynchronous: true
      fillMode: Image.PreserveAspectFit
      source: root.tabFaviconSource
      sourceSize: Qt.size(32, 32)
      opacity: root.activeBrowserTab ? 1 : 0.85
    }

    // Lucide earth icon when the tab has no site favicon (Chrome-style default).
    DockLucideIcon {
      id: tabFaviconFallback
      visible: root.nestedTab && !root.collapsed && !root.tabFaviconReady
      width: 14
      height: 14
      x: root.artX
      anchors.verticalCenter: parent.verticalCenter
      iconName: "earth"
      iconSize: 14
      tint: root.activeBrowserTab
        ? Color.foreground
        : Util.alpha(Color.foreground, 0.75)
    }

    // Nested Herdr marker — working uses the shared smooth spinner. Reduced
    // motion and clipped rows keep the same static arc instead of reverting.
    Item {
      id: herdrStatusMarker
      objectName: "sidebar-herdr-status-marker"
      visible: root.herdrStatusDotVisible
      width: root.herdrWorkingStatus ? 10 : 8
      height: width
      x: root.artX + (root.herdrWorkingStatus ? 2 : 3)
      anchors.verticalCenter: parent.verticalCenter

      DockHerdrWorkingIndicator {
        id: herdrWorkingIndicator
        objectName: "sidebar-herdr-working-indicator"
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        visible: root.herdrWorkingStatus
        active: root.herdrWorkingAnimationActive
        animationsEnabled: root.animationsEnabled
        tint: herdrStatusColors.color("working")
      }

      Rectangle {
        objectName: "sidebar-herdr-static-status-dot"
        visible: !root.herdrWorkingStatus
        anchors.centerIn: parent
        width: 8
        height: 8
        radius: 4
        color: herdrStatusColors.hollow(root.row.status)
          ? "transparent"
          : herdrStatusColors.color(root.row.status)
        border.width: herdrStatusColors.hollow(root.row.status) ? 1 : 0
        border.color: Color.muted
        opacity: root.herdrActionable
          && (root.normalizedHerdrStatus === "working"
            || root.normalizedHerdrStatus === "blocked") ? 1.0
          : root.herdrActionable
            && root.normalizedHerdrStatus === "done" ? 0.9
          : 0.75
      }
    }

    // Compact single-line monitor identity — the header shows the monitor name
    // and the topology strip only; connector names (HDMI-A-1, DP-1) stay out of
    // the header and remain available for targeting/accessibility.
    Row {
      id: monitorLabels
      visible: root.kind === "monitor" && !root.collapsed && content.width >= 140
      x: monitorGlyph.x + monitorGlyph.width + Style.space(8)
      width: Math.max(0, content.width - x - root.padding
        - (displayStrip.visible ? displayStrip.width + Style.space(8) : 0))
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Text {
        id: monitorTitleLabel
        objectName: "sidebar-label"
        width: parent.width
        height: Math.ceil(font.pixelSize * 1.25)
        text: root.monitorTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        color: root.dropTarget ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }
    }

    // Tiny connected-display strip: physical x/y miniature order. Each header
    // fills its own monitor, accented only when that monitor is focused.
    // >4 shows this header's own physical ordinal N/M.
    // Rail omits the strip (uses focused tint on railMonitor instead).
    Item {
      id: displayStrip
      visible: root.kind === "monitor" && !root.collapsed && root.monitorStripCount > 0
      anchors.right: parent.right
      anchors.rightMargin: root.padding
      anchors.verticalCenter: parent.verticalCenter
      width: root.monitorStripCount > 4 ? ordinalLabel.implicitWidth : displayStripBody.width
      height: Math.max(displayStripBody.height, ordinalLabel.height, Style.space(12))

      Row {
        id: displayStripBody
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        visible: root.monitorStripCount <= 4
        Repeater {
          model: root.monitorStripCount <= 4 ? root.monitorStripCount : 0
          Item {
            id: monitorMini
            required property int index
            readonly property var monitorData: root.monitorTopologyStrip[index] || ({})
            readonly property bool focusedMonitor: monitorData.focused === true
            readonly property bool ownMonitor: index === root.monitorStripIndex
            width: 14
            height: 10
            Accessible.name: InteractionModel.monitorTopologyTooltip(monitorData)
            Rectangle {
              anchors.centerIn: parent
              width: 14
              height: 10
              radius: 2
              color: parent.ownMonitor
                ? (parent.focusedMonitor ? Color.accent : Util.alpha(Color.foreground, 0.42))
                : "transparent"
              border.width: parent.ownMonitor ? 0 : 1
              border.color: Util.alpha(Color.foreground, 0.42)
            }
            HoverHandler { id: monitorMiniHover }
            DockToolTip {
              anchorItem: monitorMini
              position: root.controller.edge
              requestedVisible: monitorMiniHover.hovered
              text: monitorMini.Accessible.name
              fontFamily: Style.font.family
              fontSize: Style.font.bodySmall
            }
          }
        }
      }
      Text {
        id: ordinalLabel
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        visible: root.monitorStripCount > 4
        text: root.monitorStripOrdinal
        textFormat: Text.PlainText
        color: root.row.focused ? Color.accent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Text {
      id: label
      objectName: "sidebar-label"
      visible: !root.collapsed && root.kind !== "monitor" && root.kind !== "workspace"
        && root.kind !== "herdr-agent"
      x: {
        return root.baseLabelX + root.herdrWindowWorkingIndicatorReservation
      }
      width: {
        // Herdr: reserve fold + full natural counter/kind width first so every
        // nonzero count stays visible; name elides (may reach zero). State icons
        // are optional and yield via herdrStateStripFits — not taken from the
        // counter budget.
        var leading = 0
        if (countBadge.visible)
          leading += Style.space(6) + countBadge.width
        if (alertCount.visible)
          leading += Style.space(4) + alertCount.reservedWidth
        if (severityDot.visible)
          leading += Style.space(4) + severityDot.width
        if (root.herdrCountersVisible || root.herdrKindVisible || herdrFold.visible) {
          var available = Math.max(0, content.width - x - leading - root.herdrRightChromeWidth)
          return InteractionModel.herdrCompactLabelWidths({
            availableWidth: available,
            kindWidth: herdrKindLabel.visible ? herdrKindLabel.implicitWidth : 0,
            countersWidth: herdrCounters.visible ? herdrCounters.implicitWidth : 0,
            controlsWidth: 0,
            gap: Style.space(6)
          }).nameWidth
        }
        if (stateStrip.visible)
          leading += Style.space(6) + stateStrip.width
        var available = Math.max(0, content.width - x - leading - root.padding
          - (root.insideWorkspaceCard ? root.workspaceCardInset : 0)
          - (fold.visible ? fold.width : 0)
          - (tabsFold.visible ? tabsFold.width : 0)
          - (root.showAlertControl ? Style.space(22) + Style.space(4) : 0))
        return root.secondaryPath ? Math.min(label.implicitWidth, available * 0.45) : available
      }
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.liveTitle
      elide: Text.ElideRight
      wrapMode: Text.NoWrap
      maximumLineCount: 1
      horizontalAlignment: Text.AlignLeft
      color: root.kind === "section" || root.kind === "herdr-state" ? Color.muted
        : root.row.urgent ? Color.urgent
        : root.focusedWindow ? Color.accent
        : Color.foreground
      font.family: Style.font.family
      font.pixelSize: root.kind === "section" ? Style.font.caption
        : Style.font.bodySmall
      font.bold: root.focusedWindow
      renderType: Text.NativeRendering
      verticalAlignment: Text.AlignVCenter
      transform: Translate { x: root.attentionNudgeX }
    }

    Text {
      id: secondaryPathLabel
      visible: !root.collapsed && root.secondaryPath !== ""
      x: (stateStrip.visible ? stateStrip.x + stateStrip.width
        : label.x + label.width) + Style.space(6)
      width: Math.max(0, content.width - x - root.padding
        - (root.insideWorkspaceCard ? root.workspaceCardInset : 0)
        - (fold.visible ? fold.width : 0)
        - (tabsFold.visible ? tabsFold.width : 0)
        - (alertCount.visible ? alertCount.width + Style.space(4) : 0))
      anchors.verticalCenter: parent.verticalCenter
      text: root.secondaryPath
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Util.alpha(Color.foreground, root.focusedWindow ? 0.78 : 0.62)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      renderType: Text.NativeRendering
    }

    // Working Herdr parents place the motion before their name, rather than
    // beside the numeric status counter. The label reserves its width above.
    DockHerdrWorkingIndicator {
      id: herdrWindowWorkingIndicator
      objectName: "sidebar-herdr-window-working-indicator"
      visible: root.herdrWindowWorkingIndicatorVisible
      active: root.herdrWindowWorkingAnimationActive
      animationsEnabled: root.animationsEnabled
      width: 10
      height: 10
      x: root.baseLabelX
      anchors.verticalCenter: parent.verticalCenter
      tint: herdrStatusColors.color("working")
    }

    // Two-line Herdr agent identity.
    Column {
      id: herdrAgentLabels
      objectName: "sidebar-herdr-agent-labels"
      visible: root.herdrTwoLineLabels
      x: root.artX + 14 + Style.space(8)
      width: {
        var available = Math.max(0, content.width - x - root.herdrRightChromeWidth)
        return InteractionModel.herdrCompactLabelWidths({
          availableWidth: available,
          kindWidth: 0,
          countersWidth: herdrCounters.visible ? herdrCounters.implicitWidth : 0,
          controlsWidth: 0,
          gap: Style.space(6)
        }).nameWidth
      }
      y: Math.round((content.height - implicitHeight) / 2)
      spacing: 1
      Text {
        objectName: "sidebar-label"
        width: parent.width
        height: Math.ceil(font.pixelSize * 1.15)
        text: root.liveTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
        maximumLineCount: 1
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }
      Row {
        visible: root.herdrAgentSubtitle.length > 0
        width: parent.width
        height: Math.max(Math.ceil(Style.font.caption * 1.1), projectIcon.visible ? projectIcon.height : 0)
        spacing: projectIcon.visible ? Style.space(4) : 0

        DockT3ProjectIcon {
          id: projectIcon
          objectName: "sidebar-t3-project-icon"
          icon: root.row.projectIcon || null
          visible: icon !== null && parent.width >= width
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          objectName: "sidebar-herdr-agent-subtitle"
          width: Math.max(0, parent.width - (projectIcon.visible ? projectIcon.width + parent.spacing : 0))
          height: parent.height
          text: root.herdrAgentSubtitle
          textFormat: Text.PlainText
          elide: Text.ElideRight
          wrapMode: Text.NoWrap
          maximumLineCount: 1
          // Brighter than muted, still quieter than the title.
          color: Qt.tint(Color.muted, Util.alpha(Color.foreground, 0.45))
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          verticalAlignment: Text.AlignVCenter
        }
      }
    }

    // Agent kind (Codex / Claude / Cursor) — after name; parents use counters instead.
    Text {
      id: herdrKindLabel
      objectName: "sidebar-herdr-kind"
      visible: root.herdrKindVisible
      anchors.verticalCenter: parent.verticalCenter
      x: label.x + Math.min(label.implicitWidth, label.width) + Style.space(6)
      width: Math.min(implicitWidth, Math.max(0,
        content.width - x - root.herdrRightChromeWidth - root.padding))
      textFormat: Text.PlainText
      text: root.herdrKindLabel
      elide: Text.ElideNone
      wrapMode: Text.NoWrap
      maximumLineCount: 1
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
      verticalAlignment: Text.AlignVCenter
    }

    // Parent status counters — full natural width, right-anchored to the fold.
    // Never clip nonzero buckets; name/state icons yield instead.
    Row {
      id: herdrCounters
      objectName: "sidebar-herdr-counters"
      visible: root.herdrCountersVisible
      spacing: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: herdrFold.visible ? herdrFold.left : parent.right
      anchors.rightMargin: herdrFold.visible ? 0
        : ((root.insideWorkspaceCard ? root.workspaceCardInset : 0)
          + (tabsFold.visible ? tabsFold.width : 0)
          + (fold.visible ? fold.width : 0))
      height: Style.space(14)
      // Width is the natural sum of children — do not clamp or clip.

      Repeater {
        model: root.herdrStatusCounters
        delegate: Item {
          id: counterItem
          objectName: "sidebar-herdr-counter"
          required property var modelData
          readonly property string normalizedStatus: HerdrModel.normalizeStatus(modelData.status)
          readonly property bool working: normalizedStatus === "working"
          width: counterRow.width
          height: herdrCounters.height

          Row {
            id: counterRow
            spacing: 2
            height: parent.height
            Item {
              objectName: "sidebar-herdr-counter-marker"
              width: Style.space(14)
              height: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              DockLucideIcon {
                objectName: "sidebar-herdr-counter-icon"
                anchors.fill: parent
                iconName: "bot"
                iconSize: Style.space(14)
                tint: herdrStatusColors.color(counterItem.modelData.status)
              }
            }
            Text {
              objectName: "sidebar-herdr-counter-text"
              height: parent.height
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: String(counterItem.modelData.count)
              color: herdrStatusColors.color(counterItem.modelData.status)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
          }
          Accessible.name: InteractionModel.herdrCounterAccessibleText(
            counterItem.modelData.count, counterItem.modelData.status)
          HoverHandler { id: counterHover }
          DockToolTip {
            anchorItem: counterItem
            position: root.controller.edge
            requestedVisible: counterHover.hovered
            text: counterItem.Accessible.name
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
          }
        }
      }
    }

    // Expanded window state: fullscreen / pinned / minimized (informational).
    Row {
      id: stateStrip
      visible: !root.collapsed && root.kind === "window"
        && (root.windowState.fullscreen || root.windowState.pinned || root.windowState.minimized)
        && root.herdrStateStripFits
      spacing: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      x: label.x + Math.min(label.implicitWidth, label.width) + Style.space(6)
      height: Style.space(14)
      DockLucideIcon {
        visible: root.windowState.fullscreen
        width: 12
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        iconName: "maximize-2"
        iconSize: 12
        tint: Color.accent
      }
      DockLucideIcon {
        visible: root.windowState.pinned
        width: 12
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        iconName: "pin"
        iconSize: 12
        tint: Color.muted
      }
      DockLucideIcon {
        visible: root.windowState.minimized
        width: 12
        height: 12
        anchors.verticalCenter: parent.verticalCenter
        iconName: "minus"
        iconSize: 12
        tint: Color.muted
      }
    }

    // Alert count pill at the right edge before the fold chevron. Exact count stays in
    // Accessible.name; displayed text is "2" / "99+" (no parentheses).
    Rectangle {
      id: alertCount
      objectName: "sidebar-alert-count"
      readonly property int reservedWidth: visible ? width : 0
      visible: InteractionModel.sidebarCountPillVisible(root.kind, root.collapsed,
          root.attention.countVisible, root.tabsExpandable, root.row.tabsFolded)
        && root.attention.text !== ""
        && (root.kind === "window" || root.kind === "application"
          || root.kind === "browser-tab" || root.kind === "launcher")
        && (root.kind !== "application" || root.row.folded === true)
      height: Math.max(Style.space(16), alertCountLabel.implicitHeight + Style.space(2))
      width: alertCountLabel.implicitWidth + Style.space(4) * 2
      radius: height / 2
      color: Color.accent
      anchors.verticalCenter: parent.verticalCenter
      x: content.width - (root.insideWorkspaceCard ? root.workspaceCardInset : root.padding)
        - (fold.visible ? fold.width : 0) - (tabsFold.visible ? tabsFold.width : 0)
        - (herdrFold.visible ? herdrFold.width : 0)
        - (alertMute.visible ? alertMute.width + Style.space(4) : 0)
        - width - Style.space(4)
      Text {
        id: alertCountLabel
        anchors.centerIn: parent
        text: root.attention.text
        textFormat: Text.PlainText
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    // Severity-only urgent/attention (no manufactured numeric count).
    Rectangle {
      id: severityDot
      visible: !root.collapsed && !root.attention.countVisible
        && (root.attention.severity === "urgent" || root.attention.severity === "attention")
        && (root.kind === "window" || root.kind === "application"
          || root.kind === "browser-tab" || root.kind === "launcher")
      width: 8
      height: 8
      radius: 4
      color: root.attention.severity === "urgent" ? Color.urgent : Color.accent
      anchors.verticalCenter: parent.verticalCenter
      x: {
        if (alertCount.visible) return alertCount.x + alertCount.reservedWidth + Style.space(4)
        if (stateStrip.visible) return stateStrip.x + stateStrip.width + Style.space(4)
        if (countBadge.visible) return countBadge.x + countBadge.width + Style.space(4)
        return label.x + Math.min(label.implicitWidth, label.width) + Style.space(4)
      }
    }

    // Collapsed rail workspace badge (canonical id:/name: token; elide if needed).
    Rectangle {
      id: railWorkspaceBadge
      visible: root.collapsed && root.kind === "workspace"
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      width: {
        var natural = railBadgeLabel.implicitWidth + Style.space(8)
        var available = Math.max(24, content.width - 4)
        return Math.min(available, Math.max(24, natural))
      }
      height: Style.space(22)
      radius: Style.space(4)
      color: Util.alpha(Color.foreground, 0.08)
      border.width: 1
      border.color: root.row.focused
        ? Util.alpha(Color.accent, 0.50)
        : Util.alpha(Color.foreground, 0.14)
      Text {
        id: railBadgeLabel
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Style.space(8))
        text: root.workspaceRailLabel
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: root.row.focused ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    // Rail monitor: centered 16px Lucide + ordinal; focused uses accent tint.
    Row {
      id: railMonitor
      visible: root.collapsed && root.kind === "monitor"
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)
      DockLucideIcon {
        width: 16
        height: 16
        anchors.verticalCenter: parent.verticalCenter
        iconName: "monitor"
        iconSize: 16
        tint: root.dropTarget || root.row.focused ? Color.accent : Color.foreground
        opacity: 0.85
      }
      Text {
        objectName: "sidebar-label"
        anchors.verticalCenter: parent.verticalCenter
        text: root.monitorOrdinal
        textFormat: Text.PlainText
        color: root.dropTarget || root.row.focused ? Color.accent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Rectangle {
      id: countBadge
      visible: root.kind === "application" && root.windowCount > 1 && !root.collapsed
        && root.row.folded === true && !alertCount.visible
      anchors.verticalCenter: parent.verticalCenter
      x: fold.x - width - Style.space(4)
      width: Math.max(Style.space(16), countLabel.implicitWidth + Style.space(8))
      height: Style.space(16)
      radius: height / 2
      color: Color.accent
      Text {
        id: countLabel
        anchors.centerIn: parent
        text: String(root.windowCount)
        textFormat: Text.PlainText
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    HoverHandler { id: passiveHover; enabled: true }
    DockSidebarRowInput {
      id: rowInput
      // Cover content only (excludes gapBefore/gapAfter); inset away from monitor gutter.
      anchors.fill: parent
      anchors.leftMargin: root.insideWorkspaceCard ? root.workspaceCardInset : 0
      anchors.rightMargin: root.insideWorkspaceCard ? root.workspaceCardInset : 0
      controller: root.controller
      rowKey: root.rowKey
      panelConnector: root.panelConnector
      navigationOwner: root.navigationOwner
      workspaceHeader: root.kind === "workspace"
      viewport: root.viewport
      enabled: root.navigable || root.herdrActionable
      onFocusRequested: root.focusFromPointer()
      onActivated: function(target, control, connector, modifiers) {
        if (root.viewport) root.viewport.activate(target, control, connector, modifiers)
      }
      onContextRequested: target => { if (root.viewport) root.viewport.contextRequested(target, root) }
      onDragMoved: point => { if (root.viewport) root.viewport.moveDrag(point) }
      onDragReleased: point => { if (root.viewport) root.viewport.finishDrag(point) }
    }

    Ui.Button {
      id: fold
      objectName: "sidebar-app-fold"
      visible: root.appExpandable && !root.collapsed
      anchors.right: parent.right
      anchors.rightMargin: root.insideWorkspaceCard ? root.workspaceCardInset : 0
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(content.height, 28)
      height: content.height
      iconText: ""
      tooltipText: root.row.folded ? "Expand " + root.liveTitle : "Fold " + root.liveTitle
      focusable: false
      enabled: !root.controller.interactionBusy
      onClicked: { root.focusFromPointer(); root.controller.toggleApplication(root.rowKey) }
      Item {
        anchors.centerIn: parent
        width: 14
        height: 14
        rotation: root.row.folded ? 0 : 90
        DockLucideIcon {
          anchors.fill: parent
          iconName: "chevron-right"
          iconSize: 14
          tint: root.containsFocusedWindow && root.row.folded ? Color.accent : Color.foreground
        }
      }
    }

    Ui.Button {
      id: tabsFold
      objectName: "sidebar-tabs-fold"
      visible: root.tabsExpandable && !root.collapsed
      anchors.right: parent.right
      anchors.rightMargin: root.insideWorkspaceCard ? root.workspaceCardInset : 0
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(content.height, 28)
      height: content.height
      iconText: ""
      tooltipText: root.row.tabsFolded
        ? "Show tabs for " + root.liveTitle
        : "Hide tabs for " + root.liveTitle
      focusable: false
      enabled: !root.controller.interactionBusy
      onClicked: {
        root.focusFromPointer()
        root.controller.toggleWindowTabs(root.rowKey)
      }
      Item {
        anchors.centerIn: parent
        width: 14
        height: 14
        rotation: root.row.tabsFolded ? 0 : 90
        DockLucideIcon {
          anchors.fill: parent
          iconName: "chevron-right"
          iconSize: 14
          tint: root.focusedWindow && root.row.tabsFolded ? Color.accent : Color.foreground
        }
      }
    }

    Ui.Button {
      id: herdrFold
      objectName: "sidebar-herdr-fold"
      visible: root.herdrExpandable && !root.collapsed
      anchors.right: parent.right
      anchors.rightMargin: (root.insideWorkspaceCard ? root.workspaceCardInset : 0)
        + (tabsFold.visible ? tabsFold.width : 0)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(content.height, 28)
      height: content.height
      iconText: ""
      tooltipText: root.herdrFolded
        ? "Show " + root.herdrFoldNoun.toLowerCase() + " for " + root.liveTitle
        : "Hide " + root.herdrFoldNoun.toLowerCase() + " for " + root.liveTitle
      focusable: false
      enabled: !root.controller.interactionBusy
      onClicked: {
        root.focusFromPointer()
        root.controller.toggleHerdrAgents(root.rowKey)
      }
      Item {
        anchors.centerIn: parent
        width: 14
        height: 14
        rotation: root.herdrFolded ? 0 : 90
        DockLucideIcon {
          anchors.fill: parent
          iconName: "chevron-right"
          iconSize: 14
          tint: root.focusedWindow && root.herdrFolded ? Color.accent : Color.foreground
        }
      }
    }

    // Service-wide mute for alert-bearing tabs. Does not activate the tab or drag.
    Item {
      id: alertMute
      objectName: "sidebar-alert-mute"
      visible: root.showAlertControl
        && (root.attention.muted || root.input.hovered || passiveHover.hovered
          || root.alertControlFocused || root.activeFocus)
      width: Style.space(22)
      height: Style.space(22)
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: (root.insideWorkspaceCard ? root.workspaceCardInset : 0)
        + (tabsFold.visible ? tabsFold.width : 0)
        + (herdrFold.visible ? herdrFold.width : 0)
        + (fold.visible ? fold.width : 0)
      z: 3
      opacity: root.attention.muted || root.alertControlFocused ? 1 : 0.9

      Accessible.role: Accessible.Button
      Accessible.name: root.attention.muted
        ? "Include " + (root.attention.serviceLabel || "service")
          + " alerts in totals across all tabs"
        : "Exclude " + (root.attention.serviceLabel || "service")
          + " alerts from totals across all tabs"
      Accessible.onPressAction: root.controller.toggleRowActivityMute(root.rowKey)

      HoverHandler {
        id: muteHover
        cursorShape: Qt.PointingHandCursor
      }
      TapHandler {
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.WithinBounds
        onTapped: {
          root.controller.alertControlKey = root.rowKey
          root.controller.toggleRowActivityMute(root.rowKey)
        }
      }

      DockLucideIcon {
        anchors.centerIn: parent
        width: Style.space(14)
        height: Style.space(14)
        iconName: root.attention.muted ? "eye-off" : "eye"
        tint: root.alertControlFocused || muteHover.hovered
          ? Color.accent : Color.muted
      }

      DockToolTip {
        anchorItem: alertMute
        position: root.controller.edge
        requestedVisible: muteHover.hovered
        text: root.attention.muted
          ? "Include " + (root.attention.serviceLabel || "service")
            + " alerts in totals across all tabs"
          : "Exclude " + (root.attention.serviceLabel || "service")
            + " alerts from totals across all tabs"
        fontFamily: Style.font.family
        fontSize: Style.font.bodySmall
      }
    }
  }

  // Drag-only monitor footer: temporary new-workspace drop target on each
  // monitor's final visible row. Keys stay stable; no synthetic workspace rows.
  Item {
    id: newWorkspaceFooter
    visible: root.showNewWorkspaceFooter
    x: root.workspaceCardInset
    y: root.computedHeight - root.footerTargetHeight - root.workspaceCardInset
    width: Math.max(0, root.width - root.workspaceCardInset * 2)
    height: root.footerTargetHeight
    z: 3
    Accessible.role: Accessible.Button
    Accessible.name: root.footerAccessibleLabel
    opacity: root.showNewWorkspaceFooter ? 1 : 0
    Behavior on opacity {
      NumberAnimation { duration: root.animationsEnabled ? 120 : 0; easing.type: Easing.OutCubic }
    }
    DockSidebarDropSlot {
      anchors.fill: parent
      lineColor: root.footerColor
      fillColor: root.footerDropTarget && !root.footerBlocked
        ? Style.pressedFillFor(Color.accent, Color.accent) : "transparent"
      badgeX: root.collapsed ? (width - 22) / 2 : Style.space(7)
      badgeSize: 22
      showBadge: true
    }
    DockLucideIcon {
      id: footerPlus
      width: 14
      height: 14
      anchors.verticalCenter: parent.verticalCenter
      x: root.collapsed ? Math.round((parent.width - width) / 2) : Style.space(11)
      iconName: root.footerBlocked ? "ban" : "plus"
      iconSize: 14
      tint: root.footerColor
    }
    Text {
      visible: !root.collapsed
      anchors.verticalCenter: parent.verticalCenter
      x: footerPlus.x + footerPlus.width + Style.space(12)
      width: Math.max(0, parent.width - x - Style.space(8))
      text: "New workspace"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.footerColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      renderType: Text.NativeRendering
      verticalAlignment: Text.AlignVCenter
    }
  }

  SequentialAnimation {
    id: attentionMotion
    loops: Animation.Infinite
    NumberAnimation {
      target: root
      property: "attentionNudgeX"
      to: 3
      duration: 350
      easing.type: Easing.InOutQuad
    }
    NumberAnimation {
      target: root
      property: "attentionNudgeX"
      to: 0
      duration: 350
      easing.type: Easing.InOutQuad
    }
    PauseAnimation { duration: 2300 }
  }

  // Start once while eligible; stop/reset immediately when not. Does not
  // restart an already-running loop on unrelated row/model refreshes.
  function syncAttentionNameMotion() {
    var eligible = InteractionModel.attentionNameMotionEligible(
      root.kind, root.collapsed, root.attention.countVisible, root.attention.count,
      root.animationsEnabled, root.controller.rowDragActive)
    if (!eligible) {
      attentionMotion.stop()
      root.attentionNudgeX = 0
      return
    }
    if (!attentionMotion.running)
      attentionMotion.start()
  }

  onAnimationsEnabledChanged: root.syncAttentionNameMotion()
  onCollapsedChanged: root.syncAttentionNameMotion()
  onKindChanged: root.syncAttentionNameMotion()
  Connections {
    target: root.controller
    function onRowDragActiveChanged() { root.syncAttentionNameMotion() }
  }

  onRowChanged: root.syncAttentionNameMotion()
  onAttentionDisplayCountChanged: root.syncAttentionNameMotion()
  Component.onCompleted: root.syncAttentionNameMotion()
  Component.onDestruction: {
    attentionMotion.stop()
    root.attentionNudgeX = 0
    if (root.controller.alertControlKey === root.rowKey)
      root.controller.clearAlertControl()
  }

  DockToolTip {
    anchorItem: root
    position: root.controller.edge
    requestedVisible: passiveHover.hovered && !root.controller.rowDragActive
      && !muteHover.hovered
      && (root.kind === "monitor" || root.kind === "workspace"
        || root.collapsed || (label.visible && label.truncated)
        || (root.kind === "browser-tab" && root.liveTitle !== root.windowTitle)
        || root.secondaryPath !== ""
        || (monitorLabels.visible && monitorLabels.children[0] && monitorLabels.children[0].truncated)
        || (workspaceBadge.visible && badgeLabel.truncated)
        || (railWorkspaceBadge.visible && railBadgeLabel.truncated))
    text: root.accessibleLabel
    fontFamily: Style.font.family
    fontSize: Style.font.bodySmall
  }
}
