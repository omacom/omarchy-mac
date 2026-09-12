import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
  id: root

  readonly property string readyPath: Quickshell.env("OMARCHY_QML_TEST_READY")
  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  property var failures: []
  property var view: null
  property int revealCount: 0
  property int passwordEditCount: 0
  property bool resultWritten: false

  function fail(message) {
    failures.push(String(message))
  }

  function assertTrue(condition, message) {
    if (!condition) fail(message)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeFile(path, content) {
    if (path) {
      Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(content) + " > " + shellQuote(path)])
    }
  }

  function writeResult() {
    if (resultWritten) return
    resultWritten = true
    writeFile(resultPath, JSON.stringify({
      ok: failures.length === 0,
      failures: failures
    }))
  }

  function verifyReveal() {
    try {
      assertTrue(revealCount === 1, "the first key emits exactly one reveal request")
      assertTrue(view.authenticationUiVisible, "the first key reveals authentication UI")
      assertTrue(!view.screensaverVisible, "the first key hides the secure screensaver")
      assertTrue(view.passwordText === "" && passwordEditCount === 0, "the first key is consumed without prefilling authentication")
      assertTrue(!view.requestAuthenticationReveal(), "revealed UI ignores further reveal requests")
      assertTrue(revealCount === 1, "revealed input does not emit another reveal request")
    } catch (error) {
      fail("lock screensaver reveal verification threw: " + error)
    } finally {
      writeResult()
    }
  }

  PanelWindow {
    id: testWindow
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "black"
    WlrLayershell.namespace: "omarchy-lock-screensaver-reveal-test"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Item {
      id: host
      anchors.fill: parent
    }
  }

  Timer {
    id: readyTimer
    interval: 100
    repeat: false
    onTriggered: root.writeFile(root.readyPath, "ready")
  }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: {
      try {
        var component = Qt.createComponent("file://" + root.rootPath + "/shell/plugins/lock/LockView.qml", Component.PreferSynchronous)
        if (component.status !== Component.Ready) {
          root.fail("LockView failed to load: " + component.errorString())
          root.writeResult()
          return
        }

        root.view = component.createObject(host, {
          width: Qt.binding(function() { return host.width }),
          height: Qt.binding(function() { return host.height }),
          authenticationVisible: false,
          loadBackground: false,
          passwordText: "",
          screensaverContent: "SECURE ASCII"
        })
        if (!root.view) {
          root.fail("LockView failed to instantiate: " + component.errorString())
          root.writeResult()
          return
        }

        root.view.authenticationRevealRequested.connect(function() {
          root.revealCount += 1
          root.view.authenticationVisible = true
          Qt.callLater(root.verifyReveal)
        })
        root.view.passwordTextEdited.connect(function() {
          root.passwordEditCount += 1
        })

        root.assertTrue(root.view.screensaverVisible, "concealed mode shows the secure screensaver")
        root.assertTrue(!root.view.authenticationUiVisible, "concealed mode hides authentication UI")
        readyTimer.start()
      } catch (error) {
        root.fail("lock screensaver reveal fixture threw: " + error)
        root.writeResult()
      }
    }
  }
}
