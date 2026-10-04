import QtQuick
import qs.Commons

// A small monitor screen with the display number drawn in it. Drawn from
// rectangles rather than a font glyph, so the number lands in the middle of
// the screen at any size and in any font. number 0 draws a plain monitor.
Item {
  id: root

  property int number: 0
  // Width of the monitor; the height follows.
  property real size: Style.font.title
  property color color: Color.foreground
  property string fontFamily: Style.font.family

  readonly property int screenWidth: Math.max(8, Math.round(size))
  readonly property int screenHeight: Math.round(screenWidth * 0.72)
  readonly property int stroke: Math.max(1, Math.round(screenWidth / 18))
  readonly property int innerWidth: screenWidth - stroke * 2
  readonly property int innerHeight: screenHeight - stroke * 2
  readonly property string label: number > 0 ? String(number) : ""

  implicitWidth: screenWidth
  implicitHeight: screenHeight

  Rectangle {
    id: screen
    width: root.screenWidth
    height: root.screenHeight
    radius: Math.max(1, Math.round(root.screenWidth / 10))
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
  }


  // Measured at 100 px to find the size at which the digits fill the screen
  // (two digits included), then again at that size to centre their ink.
  TextMetrics {
    id: reference
    font.family: root.fontFamily
    font.pixelSize: 100
    font.weight: Font.Medium
    text: root.label
  }

  TextMetrics {
    id: ink
    font.family: root.fontFamily
    font.pixelSize: digits.font.pixelSize
    font.weight: Font.Medium
    text: root.label
  }

  Text {
    id: digits
    visible: root.label !== ""
    textFormat: Text.PlainText
    text: root.label
    color: root.color
    font.family: root.fontFamily
    font.weight: Font.Medium
    font.pixelSize: Math.max(1, Math.floor(Math.min(
      root.innerHeight * 0.7 / Math.max(0.01, reference.tightBoundingRect.height / 100),
      root.innerWidth * 0.7 / Math.max(0.01, reference.tightBoundingRect.width / 100))))
    x: Math.round(root.screenWidth / 2 - (ink.tightBoundingRect.x + ink.tightBoundingRect.width / 2))
    y: Math.round(root.screenHeight / 2 - baselineOffset - (ink.tightBoundingRect.y + ink.tightBoundingRect.height / 2))
  }
}
