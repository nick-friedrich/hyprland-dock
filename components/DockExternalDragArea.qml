import QtQuick

// Reusable nonvisual external-drag adapter. It tracks a native content drag
// only so the shared coordinator can dwell; it never reads the payload, starts
// a drag, accepts a drop, or dispatches focus itself.
DropArea {
  id: root

  property var navigation: null
  property QtObject owner: null
  property var targetDescriptor: null
  property bool navigationEnabled: true

  property int token: 0
  // Observability for the Qt fixture: records the final acceptance value after
  // onDropped has explicitly rejected the navigation target.
  property bool lastDropAccepted: true

  keys: []

  function eligible() {
    return navigationEnabled && !!navigation && !!owner && !!targetDescriptor
      && typeof targetDescriptor.key === "string" && targetDescriptor.key !== ""
  }

  function begin() {
    if (!eligible() || typeof navigation.enter !== "function") return 0
    token = navigation.enter(owner, targetDescriptor)
    return token
  }

  function release(genuineExit) {
    if (!token) {
      token = 0
      return
    }
    var current = token
    token = 0
    if (!navigation || typeof navigation.leave !== "function") return
    navigation.leave(current, genuineExit !== false)
  }

  function refresh() {
    if (eligible() && containsDrag && token === 0) begin()
  }

  onEntered: function(drag) {
    // Keep tracking so containsDrag stays true; this is not a drop acceptance.
    if (drag) drag.accepted = true
    begin()
  }

  onPositionChanged: function(drag) {
    if (drag) drag.accepted = true
    if (token === 0) begin()
  }

  onExited: release(true)

  function handleDrop(drop) {
    if (!drop) return false
    // Qt defaults DragEvent.accepted to true on a drop. Explicitly reject the
    // navigation target: the destination app negotiates the real operation.
    drop.accepted = false
    lastDropAccepted = drop.accepted
    release(false)
    if (navigation && typeof navigation.endSession === "function")
      navigation.endSession()
    return true
  }

  onDropped: function(drop) {
    handleDrop(drop)
  }

  onContainsDragChanged: {
    if (!containsDrag) release(true)
    else refresh()
  }

  onNavigationEnabledChanged: {
    if (!navigationEnabled) release(false)
    else refresh()
  }

  onNavigationChanged: {
    release(false)
    refresh()
  }

  onOwnerChanged: {
    release(false)
    refresh()
  }

  onTargetDescriptorChanged: {
    if (token) release(false)
    refresh()
  }

  Component.onDestruction: release(false)
}
