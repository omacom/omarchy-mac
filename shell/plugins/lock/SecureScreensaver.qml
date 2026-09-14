import QtQuick
import Quickshell.Io

Item {
  id: root

  property string sourcePath: ""
  property string content: ""
  property string loadedContent: ""

  readonly property string displayedText: content.length > 0 ? content : loadedContent
  readonly property real horizontalDrift: Math.min(36, width * 0.025)
  readonly property real verticalDrift: Math.min(28, height * 0.025)

  Rectangle {
    anchors.fill: parent
    color: "black"
  }

  Text {
    id: asciiArt
    objectName: "secureScreensaverText"
    width: parent.width * 0.8
    height: parent.height * 0.72
    anchors.centerIn: parent
    text: root.displayedText
    color: "#d8d8d8"
    opacity: 0.88
    textFormat: Text.PlainText
    wrapMode: Text.NoWrap
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    font.family: "monospace"
    font.pixelSize: 72
    fontSizeMode: Text.Fit
    minimumPixelSize: 6

    transform: Translate {
      id: drift
    }
  }

  SequentialAnimation {
    running: root.visible && root.displayedText.length > 0
    loops: Animation.Infinite

    NumberAnimation {
      target: drift
      property: "x"
      from: 0
      to: root.horizontalDrift
      duration: 9000
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      target: drift
      property: "x"
      to: -root.horizontalDrift
      duration: 18000
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      target: drift
      property: "x"
      to: 0
      duration: 9000
      easing.type: Easing.InOutSine
    }
  }

  SequentialAnimation {
    running: root.visible && root.displayedText.length > 0
    loops: Animation.Infinite

    NumberAnimation {
      target: drift
      property: "y"
      from: 0
      to: -root.verticalDrift
      duration: 12000
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      target: drift
      property: "y"
      to: root.verticalDrift
      duration: 24000
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      target: drift
      property: "y"
      to: 0
      duration: 12000
      easing.type: Easing.InOutSine
    }
  }

  FileView {
    path: root.sourcePath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadedContent = text()
    onLoadFailed: root.loadedContent = ""
    onFileChanged: reload()
  }
}
