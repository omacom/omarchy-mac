import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell
  property var manifest

  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string applyScript: pluginDir + "/apply.sh"
  readonly property url overlayUrl: {
    var home = Quickshell.env("HOME") || ""
    return "file://" + home + "/.config/omarchy/touchbar.json"
  }

  function applyLayout() {
    if (applyProc.running) return
    applyErr.text = ""
    applyProc.running = true
  }

  function reportApplyFailure(exitCode) {
    var detail = String(applyErr.text || "").trim()
    if (!detail) detail = "Could not install the Touch Bar layout (exit " + exitCode + ")"
    Quickshell.execDetached([
      "omarchy-notification-send", "-u", "critical", "-g", "󰁨",
      "Touch Bar", detail
    ])
  }

  Process {
    id: applyProc
    command: ["bash", root.applyScript]
    stdout: StdioCollector { }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.reportApplyFailure(exitCode)
    }
  }

  // Only rewrite /etc when the user keeps an overlay. Fresh installs get the
  // stock tiny-dfr config from install/hardware/apple/touchbar.sh.
  FileView {
    id: overlay
    path: root.overlayUrl
    watchChanges: true
    onFileChanged: {
      overlay.reload()
      root.applyLayout()
    }
    onLoaded: {
      if (overlay.text && overlay.text.length > 0)
        root.applyLayout()
    }
  }
}
