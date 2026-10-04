import QtQuick
import Quickshell.Hyprland
import qs.Commons
import "Model.js" as Model

// The displays drawn to scale, as the display module arranged them. Drag one
// to rearrange: an outline shows where it lands, flush against the nearest
// side of another display, and on release the panel has the module move it
// there and remember it. Click one to have its number shown on it.
Item {
  id: root

  property var bar
  property string mainName: ""
  // The display whose number is being shown on it, drawn highlighted.
  property string identified: ""
  property bool dragging: false
  // Where the display being dragged would land, in logical pixels.
  property var landing: null

  signal moveRequested(string name, int x, int y)
  signal identifyRequested(string name)

  implicitHeight: Style.space(130)

  // Logical rects, sorted into display numbers (display 1 is the leftmost).
  readonly property var displays: {
    var result = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var m = values[i]
      if (m.name === "FALLBACK" || m.name.indexOf("HEADLESS") === 0 || m.scale <= 0) continue
      var turned = m.lastIpcObject && m.lastIpcObject.transform % 2 === 1
      var w = Math.round((turned ? m.height : m.width) / m.scale)
      var h = Math.round((turned ? m.width : m.height) / m.scale)
      result.push({ name: m.name, x: m.x, y: m.y, w: w, h: h })
    }
    result.sort(function(a, b) { return a.x !== b.x ? a.x - b.x : a.y - b.y })
    return result
  }

  readonly property var bounds: {
    var b = { x: 0, y: 0, w: 1, h: 1 }
    if (displays.length === 0) return b
    var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
    for (var i = 0; i < displays.length; i++) {
      left = Math.min(left, displays[i].x)
      top = Math.min(top, displays[i].y)
      right = Math.max(right, displays[i].x + displays[i].w)
      bottom = Math.max(bottom, displays[i].y + displays[i].h)
    }
    return { x: left, y: top, w: right - left, h: bottom - top }
  }

  // Room around the displays so one can be dragged to any side.
  readonly property real zoom: Math.min(width / (bounds.w * 1.6), height / (bounds.h * 1.6))
  readonly property real originX: (width - bounds.w * zoom) / 2
  readonly property real originY: (height - bounds.h * zoom) / 2

  function viewX(x) { return originX + (x - bounds.x) * zoom }
  function viewY(y) { return originY + (y - bounds.y) * zoom }

  // The logical rect display `index` lands on when dragged to atX, atY in
  // the view.
  function landingFor(index, atX, atY) {
    var moving = displays[index]
    var others = []
    for (var i = 0; i < displays.length; i++) {
      if (i !== index) others.push(displays[i])
    }
    if (others.length === 0) return null
    var spot = Model.snapPosition(others, {
      x: Math.round((atX - originX) / zoom + bounds.x),
      y: Math.round((atY - originY) / zoom + bounds.y),
      w: moving.w,
      h: moving.h
    })
    return { x: spot.x, y: spot.y, w: moving.w, h: moving.h }
  }

  Rectangle {
    visible: root.landing !== null
    x: root.landing ? root.viewX(root.landing.x) : 0
    y: root.landing ? root.viewY(root.landing.y) : 0
    width: root.landing ? root.landing.w * root.zoom : 0
    height: root.landing ? root.landing.h * root.zoom : 0
    radius: Style.space(4)
    color: Qt.alpha(Color.accent, 0.15)
    border.width: 1
    border.color: Color.accent
  }

  Repeater {
    model: root.displays

    Rectangle {
      id: tile
      required property var modelData
      required property int index

      readonly property real homeX: root.viewX(modelData.x)
      readonly property real homeY: root.viewY(modelData.y)

      function goHome() {
        tile.x = Qt.binding(function() { return tile.homeX })
        tile.y = Qt.binding(function() { return tile.homeY })
      }

      x: homeX
      y: homeY
      z: handle.drag.active ? 1 : 0
      width: modelData.w * root.zoom
      height: modelData.h * root.zoom
      radius: Style.space(4)
      color: Qt.alpha(root.bar.foreground, handle.drag.active || root.identified === modelData.name ? 0.22 : 0.12)
      border.width: 1
      border.color: modelData.name === root.mainName ? Color.accent : Qt.alpha(root.bar.foreground, 0.5)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: (tile.index + 1) + (tile.modelData.name === root.mainName ? " ★" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      MouseArea {
        id: handle
        anchors.fill: parent
        cursorShape: Qt.OpenHandCursor
        drag.target: tile
        // The panel scrolls when it's taller than the screen; a drag here
        // moves the display, not the panel.
        preventStealing: true
        onPressed: root.dragging = true
        onPositionChanged: if (drag.active) root.landing = root.landingFor(tile.index, tile.x, tile.y)
        onCanceled: {
          root.dragging = false
          root.landing = null
          tile.goHome()
        }
        // Only a press that didn't turn into a drag.
        onClicked: root.identifyRequested(tile.modelData.name)
        onReleased: {
          root.dragging = false
          root.landing = null
          var spot = tile.x !== tile.homeX || tile.y !== tile.homeY ? root.landingFor(tile.index, tile.x, tile.y) : null
          if (!spot || (spot.x === tile.modelData.x && spot.y === tile.modelData.y)) {
            tile.goHome()
            return
          }
          // It stays where it lands until the panel reads the new
          // arrangement back, which rebuilds the tiles.
          tile.x = root.viewX(spot.x)
          tile.y = root.viewY(spot.y)
          root.moveRequested(tile.modelData.name, spot.x, spot.y)
        }
      }
    }
  }
}
