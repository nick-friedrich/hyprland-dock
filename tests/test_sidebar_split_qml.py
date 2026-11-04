"""Execute production allocator wiring and row sizing without a compositor.

Only panel/row inputs and visual endpoints are fixtures. Layout blocks, actual
row/viewport metric expressions and the background gesture are production code.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from tests.test_widget_chrome_qml import block

ROOT = Path(__file__).resolve().parents[1]
RUNNER = os.environ.get('QMLTESTRUNNER') or shutil.which('qmltestrunner') or '/usr/lib/qt6/bin/qmltestrunner'


def run_qml(test, source, support=None):
    with tempfile.TemporaryDirectory(prefix='smartdock-split-') as tmp:
        path = Path(tmp)
        for name, text in (support or {}).items():
            (path / name).write_text(text)
        case = path / 'tst_production.qml'
        case.write_text(source)
        result = subprocess.run([RUNNER, '-input', str(case), '-import', str(ROOT / 'components'),
                                 '-import', str(ROOT / 'tests/qml-imports')],
                                env=dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software'),
                                capture_output=True, text=True, timeout=40)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        test.assertNotIn('QWARN', result.stdout + result.stderr)
        test.assertNotIn('QFATAL', result.stdout + result.stderr)
        print(result.stdout.strip().splitlines()[-2])


def imports():
    return ('import QtQuick\nimport QtTest\nimport qs.Commons\n'
            f'import "{(ROOT / "components").as_uri()}"\n'
            f'import "{(ROOT / "components/DockSidebarWidgetModel.js").as_uri()}" as WidgetModel\n'
            f'import "{(ROOT / "components/DockSidebarInteractionModel.js").as_uri()}" as InteractionModel\n')


class SidebarSplitProductionQmlTests(unittest.TestCase):
    @unittest.skipUnless(Path(RUNNER).is_file(), 'Qt runner unavailable; installed in Headless CI')
    def test_actual_middle_region_allocation_anchors_and_blank_gesture(self):
        middle = block((ROOT / 'components/DockSidebar.qml').read_text(), 'id: middleRegion')
        middle = middle.replace('DockSidebarViewport {', 'HierarchyFixture {\n naturalContentHeight: root.hierarchyDemand')
        middle = middle.replace('DockSidebarWidgetArea {', 'WidgetFixture {\n naturalWidgetHeaderHeight: 38\n naturalWidgetContentHeight: root.widgetDemand\n presentedWidgetCount: root.widgetCount')
        shared = 'property var controller; property var appearance\n'
        support = {
            'HierarchyFixture.qml': 'import QtQuick\nItem {\n' + shared + '''
              property real naturalContentHeight: 0; property real rowHeight: 34
              property string panelConnector; property bool panelCollapsed; property bool presentationVisible
              property var tabForwardTarget
              property var navigationOwner
              signal contextRequested(var target, var anchorItem)
              signal dismissContextRequested()
            }''',
            'WidgetFixture.qml': 'import QtQuick\nItem {\n' + shared + '''
              property var panel; property var viewport; property real windowRowHeight
              property real naturalWidgetHeaderHeight; property real naturalWidgetContentHeight
              property int presentedWidgetCount
              property bool sectionVisible: height >= naturalWidgetHeaderHeight && presentedWidgetCount > 0
              property var manageControl: null
            }''',
        }
        source = imports() + '''
TestCase {
  id: testCase; name: "SplitProductionLayout"; when: windowShown; visible:true; width:900; height:800
  Component {
    id: factory
    Item {
      id:root; width:280; height:700
      property bool panelCollapsed:false
      property real resizeEdgeAllowance:8
      property real hierarchyDemand:1000; property real widgetDemand:1000; property int widgetCount:3
      property var screen:({name:"TEST"}); property var sidebarAppearance:null
      property string sidebarEdge:"left"; property string presentationMode:"sidebar"
      property var modeGestureToken:({revision:1}); property bool animationsEnabled:false
      property var footerControl:launcher
      property int commits:0
      property alias hierarchy:sidebarViewport; property alias widgets:sidebarWidgets
      property alias blank:viewportDragSurface; property alias middle:middleRegion
      property alias pinY:pinnedStrip.y
      QtObject { id:c; property bool interactionBusy:false }
      property var controller:c
      function openContext() {} function commitModeSwitch(position, token) { commits++ }
      Item { id:controls; width:parent.width; height:40 }
      Item { id:pinnedStrip; y:654; height:40 }
      Item { id:launcher }
      QtObject { id:sidebarContext; function dismiss() {} }
''' + middle + '''
    }
  }
  function test_live_allocation_data() {
    return [{tag:"minimum-left",width:240,edge:"left"},{tag:"wide-right",width:420,edge:"right"}]
  }
  function test_live_allocation(data) {
    var p=createTemporaryObject(factory,testCase,{width:data.width,sidebarEdge:data.edge})
    verify(p!==null);wait(0)
    compare(p.middle.y,46);compare(p.middle.height,600)
    compare(p.middle.x,14);compare(p.middle.width,p.width-28)
    fuzzyCompare(p.hierarchy.height,330,0.001);fuzzyCompare(p.widgets.height,270,0.001)
    compare(p.widgets.y,p.hierarchy.height);compare(p.blank.height,0)
    p.hierarchyDemand=100;p.widgetDemand=34;wait(0)
    compare(p.hierarchy.height,100);compare(p.widgets.height,72);compare(p.blank.height,428)
    compare(p.blank.y,172)
    var h=p.hierarchy.height,w=p.widgets.height
    mouseWheel(p.blank,40,30,0,-120);compare(p.hierarchy.height,h);compare(p.widgets.height,w)
    mousePress(p.blank,40,20);mouseMove(p.blank,40,80,30);mouseRelease(p.blank,40,80)
    compare(p.commits,1)
    p.pinY=84;wait(0)
    compare(p.hierarchy.height,30);compare(p.widgets.height,0)
    p.pinY=92;wait(0);compare(p.hierarchy.height,0);compare(p.widgets.height,38)
    p.pinY=654;p.panelCollapsed=true;wait(0)
    compare(p.middle.x,6);compare(p.middle.height,608);compare(p.widgets.height,0)
    compare(p.blank.height,508)
  }
}
'''
        run_qml(self, source, support)

    @unittest.skipUnless(Path(RUNNER).is_file(), 'Qt runner unavailable; installed in Headless CI')
    def test_projection_demand_equals_actual_row_sizing_for_every_kind(self):
        viewport = (ROOT / 'components/DockSidebarViewport.qml').read_text()
        row = (ROOT / 'components/DockSidebarRow.qml').read_text()
        names = ['rowMetricsFor', 'placeholderBefore', 'placeholderAfter', 'windowFooterActive', 'footerExtraHeight']
        functions = '\n'.join(block(viewport, 'function ' + name + '(') for name in names)
        demand = re.search(r'  readonly property real naturalContentHeight: \{[\s\S]*?\n  \}', viewport).group()
        sizing = row[row.index('  readonly property bool railNumericAlert:'):row.index('  readonly property string footerKey:')]
        sizing += row[row.index('  readonly property real placeholderBefore:'):row.index('  readonly property string monitorOrdinal:')]
        source = imports() + '''
TestCase {
  id:testCase; name:"SplitCanonicalRowMetrics"; when:windowShown; visible:true; width:400; height:800
  Item {
    id:root; width:280; height:720
    property var visibleRows:[]; property bool panelCollapsed:false; property real rowHeight:34
    property var workspacePlaceholder:null; property real placeholderHeight:40
    property var sectionSpans:[]
    property var controller:c
    QtObject {
      id:c
      property bool rowDragActive:false; property var dragSession:null
      function attentionForRow(row) { return {countVisible:row.alert===true} }
    }
''' + functions + '\n' + demand + '''
    Flickable { id:list; anchors.fill:parent; contentHeight:col.implicitHeight; clip:true
      Column { id:col; width:parent.width
        Repeater { id:rows; model:root.visibleRows
          delegate: Item {
            id:rowItem; required property var modelData; width:col.width
            property var row:modelData; property string rowKey:row.key
            property var attention:c.attentionForRow(row)
            property bool collapsed:root.panelCollapsed; property real rowHeight:root.rowHeight
            property var controller:c; property var viewport:root
''' + sizing.replace('root.', 'rowItem.') + '''
            implicitHeight:computedHeight; height:computedHeight
          }
        }
      }
    }
    property alias listView:list; property alias rendered:rows
  }
  function test_all_kinds_alerts_font_and_drag_variants() {
    var kinds=["monitor","workspace","section","application","window","browser-tab","herdr-agent","herdr-state"]
    var data=[]
    for(var kind of kinds) for(var alert of [false,true])
      data.push({kind:kind,key:kind+alert,alert:alert,layoutGapBefore:"workspace",layoutGapAfter:6})
    root.visibleRows=data;root.sectionSpans=[{kind:"monitor",lastKey:"windowtrue"}]
    for(var rail of [false,true]) for(var rowHeight of [34,60]) for(var drag of [false,true]) {
      root.panelCollapsed=rail;root.rowHeight=rowHeight
      c.rowDragActive=drag;c.dragSession=drag?{target:{kind:"window"}}:null
      root.workspacePlaceholder=drag?{beforeKey:"applicationfalse",afterKey:"browser-tabtrue"}:null
      wait(0)
      var sum=0
      for(var i=0;i<data.length;i++) {
        var item=root.rendered.itemAt(i);verify(item!==null)
        var metrics=root.rowMetricsFor(data[i])
        fuzzyCompare(item.height,metrics.height,0.00001);sum+=item.height
      }
      fuzzyCompare(root.naturalContentHeight,sum,0.00001)
      root.listView.contentY=80;wait(0)
      fuzzyCompare(root.naturalContentHeight,sum,0.00001)
    }
  }
}
'''
        run_qml(self, source)
