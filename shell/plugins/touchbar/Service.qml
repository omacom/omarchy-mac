import Quickshell
import QtQuick

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
    Quickshell.execDetached(["bash", applyScript])
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
