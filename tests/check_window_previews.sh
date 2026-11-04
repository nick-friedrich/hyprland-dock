#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

fail() {
  printf 'check_window_previews: %s\n' "$*" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || fail "missing '$pattern' in $file"
}

[[ -f components/DockWindowPreview.qml ]] || fail "missing preview popup"
[[ -f components/DockWindowPreviewTile.qml ]] || fail "missing preview tile"
[[ -f components/DockWindowPreviewModel.js ]] || fail "missing preview model"
require_pattern 'DockWindowPreview[[:space:]]*\{' components/Dock.qml
require_pattern 'showPreviews' components/Dock.qml
require_pattern 'onPreviewRequested:' components/Dock.qml
require_pattern 'previewRequested' components/DockItem.qml
require_pattern 'required property bool showPreviews' components/DockItem.qml
require_pattern 'root\.showPreviews' components/DockItem.qml
require_pattern 'root\.previewRequested\(root' components/DockItem.qml
require_pattern 'ScreencopyView[[:space:]]*\{' components/DockWindowPreviewTile.qml
require_pattern 'captureFrame\(\)' components/DockWindowPreviewTile.qml
require_pattern 'function groupedPreviewMembers\(' components/DockWindowPreviewModel.js
require_pattern 'function previewAnchorOffset\(' components/DockWindowPreviewModel.js
require_pattern 'function hasPreviewContent\(memberCount, activityCount, agentCount\)' components/DockWindowPreviewModel.js

# FDM-990: one window with one Herdr agent is preview-eligible through the
# same helper for hover, configured click, delayed open and refresh.
require_pattern 'import "DockWindowPreviewModel\.js" as PreviewModel' components/DockItem.qml
require_pattern 'function hasPreviewContent\(\)' components/DockItem.qml
require_pattern 'root\.previewAgents\.length' components/DockItem.qml
if grep -Eq 'runningCount[[:space:]]*<[[:space:]]*2.*previewActivities|runningCount[[:space:]]*>=[[:space:]]*2.*previewActivities' components/DockItem.qml; then
  fail "DockItem preview paths must use hasPreviewContent"
fi

# Agent rows share the anchor lifecycle, suppress thumbnails only for an
# all-Herdr item, and capture the real agent target rather than a row index or
# the bridge-only indicatorKey.
for property in previewAgents previewHerdrOnly previewHerdrLabel previewHerdrCounters; do
  require_pattern "property .*${property}" components/DockItem.qml
done
require_pattern 'function herdrPreviewAgentsFor\(' components/Dock.qml
require_pattern 'toplevel:[[:space:]]*toplevel' components/Dock.qml
require_pattern 'serverLabel:[[:space:]]*root\.herdrServerLabel\(agent\.serverId\)' components/Dock.qml
require_pattern 'herdrAgentActions:[[:space:]]*root\.herdrAgentActions' DockHost.qml
require_pattern 'herdrAgentActions:[[:space:]]*root\.herdrAgentActions' components/Dock.qml
require_pattern 'root\.anchorItem\["previewAgents"\]' components/DockWindowPreview.qml
require_pattern 'root\.members\.length[[:space:]]*>=[[:space:]]*2[[:space:]]*&&[[:space:]]*\(!root\.herdrOnly[[:space:]]*\|\|[[:space:]]*root\.dragSession\)' components/DockWindowPreview.qml

# External content-drag hover reuses the one popup: the dwell opens it without
# the ordinary 220 ms delay, exact tiles stay exposed for the drag session, and
# dismissal follows drag membership plus the coordinator handoff.
require_pattern 'function requestDragPreview\(' components/DockWindowPreview.qml
require_pattern 'root\.openDelayMs' components/DockWindowPreview.qml
require_pattern 'handoffMs' components/DockWindowPreview.qml
require_pattern 'DockExternalDragArea[[:space:]]*\{' components/DockWindowPreview.qml
require_pattern 'DockExternalDragArea[[:space:]]*\{' components/DockWindowPreviewTile.qml
require_pattern 'anchors\.rightMargin: closeButton\.width \+ 10' components/DockWindowPreviewTile.qml
require_pattern 'function requestExternalPreview\(' components/Dock.qml
require_pattern 'windowPreview\.requestDragPreview\(' components/Dock.qml
require_pattern 'kind: "preview"' components/DockItem.qml
require_pattern 'kind: "workspace"' components/DockItem.qml
require_pattern 'representedWorkspaceIdentity' components/DockItem.qml
require_pattern 'root\.herdrAgentActions\.captureAgentTarget\(agent\.toplevel, agent\)' components/DockWindowPreview.qml
require_pattern 'root\.herdrAgentActions\.activateHerdrTarget\(target\)' components/DockWindowPreview.qml
require_pattern 'modelData\.focusAgentSupported[[:space:]]*===[[:space:]]*true' components/DockWindowPreview.qml
require_pattern 'activeFocusOnTab:[[:space:]]*actionable' components/DockWindowPreview.qml
require_pattern 'Keys\.onReturnPressed:' components/DockWindowPreview.qml
require_pattern 'text:[[:space:]]*"↵ Focus"' components/DockWindowPreview.qml
require_pattern 'property[[:space:]]+string[[:space:]]+herdrFocusHint:[[:space:]]*"Click a row to focus its pane\."' components/DockWindowPreview.qml
require_pattern 'text:[[:space:]]*root\.herdrFocusHint' components/DockWindowPreview.qml
require_pattern 'HerdrModel\.displayAgentTabSecondary\(' components/DockWindowPreview.qml
require_pattern 'DockHerdrStatusMark[[:space:]]*\{' components/DockWindowPreview.qml
require_pattern 'Qt\.callLater\(root\.refreshSupplementaryContent\)' components/DockWindowPreview.qml

# FDM-810 recovery hardening: overflow must be usable without altering the
# grouped-window source contract inherited from FDM-812.
require_pattern 'WheelHandler[[:space:]]*\{' components/DockWindowPreview.qml
require_pattern 'viewport\.contentWidth[[:space:]]*>[[:space:]]*viewport\.width' components/DockWindowPreview.qml
require_pattern 'viewport\.contentHeight[[:space:]]*>[[:space:]]*viewport\.height' components/DockWindowPreview.qml
wheel_handler="$(sed -n '/      WheelHandler {/,/^      }/p' components/DockWindowPreview.qml)"
for axis in X Y; do
  grep -Eq "viewport\\.content${axis}[[:space:]]*=" <<<"$wheel_handler" \
    || fail "wheel handler must update viewport.content${axis}"
done
if grep -Eq 'previewViewport\.(contentWidth|contentHeight|contentX|contentY)' <<<"$wheel_handler"; then
  fail "wheel handler must not use the preview size object as a Flickable"
fi
require_pattern 'event\.accepted[[:space:]]*=[[:space:]]*false' components/DockWindowPreview.qml
require_pattern 'event\.accepted[[:space:]]*=[[:space:]]*true' components/DockWindowPreview.qml

# Popup lifetime must follow the live anchor and monitor rather than leaving an
# orphan popup after scope/hotplug/destruction changes.
require_pattern 'onAnchorItemChanged:' components/DockWindowPreview.qml
require_pattern 'target:[[:space:]]*root\.anchorItem' components/DockWindowPreview.qml
require_pattern 'target:[[:space:]]*root\.anchorScreen' components/DockWindowPreview.qml
require_pattern 'function onDestroyed\(object\)' components/DockWindowPreview.qml
require_pattern 'root\.anchorItem[[:space:]]*===[[:space:]]*object' components/DockWindowPreview.qml

# Capture failure is a supported fallback, not a stuck/blank preview.
require_pattern 'property bool captureStopped:[[:space:]]*false' components/DockWindowPreviewTile.qml
require_pattern 'onStopped:[[:space:]]*root\.captureStopped[[:space:]]*=[[:space:]]*true' components/DockWindowPreviewTile.qml
require_pattern 'root\.captureStopped[[:space:]]*\|\|' components/DockWindowPreviewTile.qml

# Preview tiles and their close affordance must remain keyboard/accessibility
# discoverable even though the popup itself does not grab keyboard focus.
require_pattern 'Accessible\.role:[[:space:]]*Accessible\.Button' components/DockWindowPreviewTile.qml
require_pattern 'Accessible\.name:[[:space:]]*root\.titleText' components/DockWindowPreviewTile.qml
require_pattern 'Accessible\.description:' components/DockWindowPreviewTile.qml
require_pattern 'Accessible\.name:[[:space:]]*"Close "[[:space:]]*\+[[:space:]]*root\.titleText' components/DockWindowPreviewTile.qml

printf 'check_window_previews: PASS\n'
