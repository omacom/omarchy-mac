import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  property var failures: []

  function fail(message) {
    failures.push(String(message))
  }

  function assertTrue(condition, message) {
    if (!condition) fail(message)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var payload = JSON.stringify({
      ok: failures.length === 0,
      failures: failures
    })

    if (resultPath) {
      Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
    }
  }

  function findByObjectName(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = findByObjectName(children[i], name)
      if (found) return found
    }
    return null
  }

  Item { id: host; width: 800; height: 600 }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: {
      try {
        var component = Qt.createComponent("file://" + root.rootPath + "/shell/plugins/lock/LockView.qml", Component.PreferSynchronous)
        if (component.status !== Component.Ready) {
          root.fail("LockView failed to load: " + component.errorString())
          return
        }

        var view = component.createObject(host, { width: 800, height: 600, loadBackground: false })
        if (!view) {
          root.fail("LockView failed to instantiate: " + component.errorString())
          return
        }

        // Stand in for the lock service: a wake lights the panel, edits become the password.
        var wakes = 0
        view.wakeRequested.connect(function() { wakes += 1; view.displaysBlank = false })
        view.passwordTextEdited.connect(function(password) { view.passwordText = password })

        root.assertTrue(!view.isWakeKey(Qt.Key_A, false), "a lit lock types its first key")

        view.displaysBlank = true
        root.assertTrue(view.isWakeKey(Qt.Key_A, false), "the key that wakes a blank lock is not typed")
        view.displaysBlank = false
        root.assertTrue(view.isWakeKey(Qt.Key_A, true), "auto-repeats of a held wake key are not typed")
        root.assertTrue(!view.isWakeKey(Qt.Key_B, false), "the next key after the wake is typed")
        root.assertTrue(!view.isWakeKey(Qt.Key_A, true), "a new key ends the wake key hold")
        root.assertTrue(!view.isWakeKey(Qt.Key_A, false), "pressing the wake key again types it")

        var input = root.findByObjectName(view, "passwordInput")
        root.assertTrue(input !== null, "the password field is reachable")
        if (input) {
          view.displaysBlank = true
          input.insert(0, "x")
          root.assertTrue(wakes === 1, "input method text at a blank lock wakes it, got " + wakes + " wakes")
          root.assertTrue(input.text === "" && view.passwordText === "", "input method text at a blank lock is dropped, got '" + input.text + "'")

          input.insert(0, "y")
          root.assertTrue(view.passwordText === "y", "input method text at a lit lock is typed, got '" + view.passwordText + "'")
        }

        view.destroy()
      } catch (error) {
        root.fail("lock wake key fixture threw: " + error)
      } finally {
        root.writeResult()
      }
    }
  }
}
