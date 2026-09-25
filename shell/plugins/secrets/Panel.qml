import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Secrets manager over the default Secret Service collection, backed by the
// omarchy-secrets-* commands. Summon with:
//   omarchy-shell shell summon omarchy.secrets '{}'
//
// Security contract: secret values never enter QML state. Copy pipes
// `omarchy-secrets-get` straight into `wl-copy --sensitive` so the value skips
// clipboard history, then a 30s timer runs `omarchy-secrets-clipclear`, which
// clears only while the clipboard still holds that secret. Add writes the
// value to the child's stdin after `started`; close() wipes every field and
// pending identity.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  // ---- list state ---------------------------------------------------------
  property var items: []
  property string filter: ""
  property var vault: allVaults
  property bool vaultOpen: false
  property string sortMode: "name"
  // null cannot collide with a service name, so it is the unfiltered state.
  readonly property var allVaults: null
  property int selectedIndex: 0
  property bool loading: false
  property bool refreshPending: false

  // ---- add form -----------------------------------------------------------
  property bool adding: false
  property bool saving: false

  // ---- delete confirm -----------------------------------------------------
  property string pendingDeleteService: ""
  property string pendingDeleteAccount: ""
  property bool deleting: false

  // ---- clipboard copy -----------------------------------------------------
  property bool pendingCopy: false
  // Identity of the in-flight copy; selection may move before it exits.
  property string copyingService: ""
  property string copyingAccount: ""

  // ---- notice -------------------------------------------------------------
  property string notice: ""
  property bool noticeIsError: false

  // Vaults: distinct non-empty services with item counts, name-sorted.
  readonly property var vaults: {
    var counts = new Map()
    for (var i = 0; i < root.items.length; i++) {
      var s = root.items[i].service
      if (s != null && s !== "") counts.set(s, (counts.get(s) || 0) + 1)
    }
    return [...counts.keys()].sort().map(function(s) {
      return { service: s, count: counts.get(s) }
    })
  }

  readonly property var filtered: {
    var list = root.items
    if (root.vault !== allVaults)
      list = list.filter(function(it) { return it.service === root.vault })
    var f = root.filter.toLowerCase()
    if (f !== "")
      list = list.filter(function(it) {
        return (it.label || "").toLowerCase().indexOf(f) !== -1
          || (it.service || "").toLowerCase().indexOf(f) !== -1
          || (it.account || "").toLowerCase().indexOf(f) !== -1
      })
    if (root.sortMode === "recent") {
      list = list.slice().sort(function(a, b) {
        return (b.modified || 0) - (a.modified || 0)
      })
    } else {
      list = list.slice().sort(function(a, b) {
        var ka = ((a.service || "") + "" + (a.account || "") + "" + (a.label || ""))
        var kb = ((b.service || "") + "" + (b.account || "") + "" + (b.label || ""))
        return ka < kb ? -1 : ka > kb ? 1 : 0
      })
    }
    return list
  }

  function open(payloadJson) {
    var wasOpen = root.opened
    root.opened = true
    root.notice = ""
    root.noticeIsError = false
    refresh()
    // The window maps hidden-then-visible; grab keys once the surface exists.
    // Only on the closed->open transition: a re-summon while a text field owns
    // focus must not steal it into hotkey dispatch.
    if (!wasOpen)
      Qt.callLater(function() {
        if (root.opened) keyCatcher.forceActiveFocus()
      })
  }

  function close() {
    root.opened = false
    // Wipe anything that could carry a secret or an armed identity.
    root.items = []
    root.filter = ""
    root.vault = allVaults
    root.vaultOpen = false
    root.selectedIndex = 0
    root.adding = false
    root.saving = false
    root.pendingDeleteService = ""
    root.pendingDeleteAccount = ""
    root.deleting = false
    root.pendingCopy = false
    root.copyingService = ""
    root.copyingAccount = ""
    root.notice = ""
    root.noticeIsError = false
    filterField.text = ""
    serviceField.text = ""
    accountField.text = ""
    secretField.text = ""
    confirmDialog.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.secrets")
    else close()
  }

  function setNotice(text, isError) {
    root.notice = text
    root.noticeIsError = isError
  }

  function refresh() {
    if (listProc.running) { root.refreshPending = true; return }
    root.loading = true
    listProc.running = true
  }

  function applyList(raw) {
    var rows = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      try {
        var obj = JSON.parse(line)
        if (obj) rows.push(obj)
      } catch (e) {}
    }
    root.items = rows
    if (root.vault !== allVaults
        && !rows.some(function(it) { return it.service === root.vault }))
      root.vault = allVaults
    if (root.selectedIndex >= root.filtered.length) root.selectedIndex = Math.max(0, root.filtered.length - 1)
  }

  function cycleVault() {
    var names = [allVaults].concat(root.vaults.map(function(v) { return v.service }))
    var next = (names.indexOf(root.vault) + 1) % names.length
    root.vault = names[next]
    root.selectedIndex = 0
    root.vaultOpen = false
  }

  function selectVault(service) {
    root.vault = service
    root.selectedIndex = 0
    root.vaultOpen = false
  }

  function cycleSort() {
    root.sortMode = root.sortMode === "name" ? "recent" : "name"
    root.selectedIndex = 0
  }

  function vaultLabel() {
    if (root.vault === allVaults) return "All vaults (" + root.items.length + ")"
    var count = 0
    for (var i = 0; i < root.vaults.length; i++)
      if (root.vaults[i].service === root.vault) count = root.vaults[i].count
    return root.vault + " (" + count + ")"
  }

  function selectedItem() {
    var list = root.filtered
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function actionable(it) {
    return it && it.service != null && it.service !== "" && it.account != null && it.account !== ""
  }

  function copySelected() {
    var it = selectedItem()
    if (!it) return
    if (!actionable(it)) { setNotice("Stored by another app — no service/account identity", true); return }
    if (copyProc.running) { root.pendingCopy = true; return }
    setNotice("", false)
    root.copyingService = String(it.service)
    root.copyingAccount = String(it.account)
    // The value flows through the pipe only: it never lands in a QML
    // property, and --sensitive keeps it out of omarchy clipboard history.
    // wl-copy runs only when get succeeds so a lookup failure can neither
    // clobber the clipboard nor masquerade as a successful copy.
    copyProc.command = ["bash", "-c",
      "v=$(omarchy-secrets-get \"$1\" \"$2\") && printf %s \"$v\" | wl-copy --sensitive", "bash",
      root.copyingService, root.copyingAccount]
    copyProc.running = true
  }

  function requestDeleteSelected() {
    var it = selectedItem()
    if (!it || !actionable(it) || root.deleting) return
    root.pendingDeleteService = String(it.service)
    root.pendingDeleteAccount = String(it.account)
    confirmDialog.message = "Delete " + root.pendingDeleteService + " / " + root.pendingDeleteAccount + "?"
      + (it.app && it.app !== "omarchy" ? " Managed by " + it.app + "." : "")
    confirmDialog.selectedIndex = 0
    confirmDialog.opened = true
    Qt.callLater(function() { confirmDialog.forceActiveFocus() })
  }

  function startAdd() {
    root.adding = true
    setNotice("", false)
    Qt.callLater(function() { serviceField.forceActiveFocus() })
  }

  function cancelAdd() {
    root.adding = false
    serviceField.text = ""
    accountField.text = ""
    secretField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitAdd() {
    var service = serviceField.text.trim()
    var account = accountField.text.trim()
    var secret = secretField.text
    if (service === "" || account === "") { setNotice("Service and account are required", true); return }
    if (secret === "") { setNotice("Secret must not be empty", true); return }
    if (setProc.running) return
    root.saving = true
    setProc.command = ["omarchy-secrets-set", service, account]
    // Re-arm stdin per run: a previously finished process kept stdinEnabled
    // false, which would launch with a closed write channel and starve the
    // child's stdin read.
    setProc.stdinEnabled = true
    setProc.running = true
  }

  // ---- backend processes --------------------------------------------------
  // stderr lands in each process's lastStderr and is surfaced only on a
  // nonzero exit: the backends also use stderr for success diagnostics
  // ("updated 1 item(s)", duplicate-match warnings), which are not errors.
  Process {
    id: listProc
    property string lastStderr: ""
    command: ["omarchy-secrets-list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (root.opened) root.applyList(text) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: listProc.lastStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.loading = false
      if (!root.opened) { root.refreshPending = false; return }
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
        return
      }
      if (exitCode !== 0 && (root.notice === "" || !root.noticeIsError))
        root.setNotice(listProc.lastStderr !== "" ? listProc.lastStderr : "Could not list secrets", true)
    }
  }

  Process {
    id: copyProc
    property string lastStderr: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: copyProc.lastStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // The timed clear must outlive this panel: the dominant flow is
        // copy-then-dismiss. A detached systemd --on-active timer survives
        // plugin destruction, and clipclear re-verifies the clipboard still
        // holds this secret before clearing, so a newer user copy is safe.
        Util.execArgv(["systemd-run", "--user", "--quiet", "--on-active=30", "--",
          "omarchy-secrets-clipclear", root.copyingService, root.copyingAccount])
        if (root.opened) root.setNotice("Copied to clipboard (clears in 30s)", false)
      } else if (root.opened && (root.notice === "" || !root.noticeIsError)) {
        root.setNotice(copyProc.lastStderr !== "" ? "Copy failed: " + copyProc.lastStderr : "Copy failed", true)
      }
      if (root.pendingCopy) {
        root.pendingCopy = false
        if (root.opened) Qt.callLater(root.copySelected)
      }
    }
  }

  // A blocked D-Bus call (locked keyring waiting on an unlock prompt the
  // exclusive keyboard grab can hide) or a failed process start otherwise
  // leaves the panel spinning forever; surface it instead of hanging.
  Timer {
    id: stallTimer
    interval: 10000
    running: root.opened
      && (listProc.running || copyProc.running || setProc.running || delProc.running)
    onTriggered: {
      if (root.notice === "")
        root.setNotice("Waiting on the keyring — an unlock prompt may be behind this panel", true)
    }
  }

  Process {
    id: setProc
    property string lastStderr: ""
    stdinEnabled: true
    onStarted: {
      write(secretField.text)
      stdinEnabled = false
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: setProc.lastStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.saving = false
      secretField.text = ""
      if (!root.opened) return
      if (exitCode === 0) {
        root.adding = false
        serviceField.text = ""
        accountField.text = ""
        root.setNotice("Saved", false)
        keyCatcher.forceActiveFocus()
        root.refresh()
      } else if (root.notice === "" || !root.noticeIsError) {
        root.setNotice(setProc.lastStderr !== "" ? "Save failed: " + setProc.lastStderr : "Save failed", true)
      }
    }
  }

  Process {
    id: delProc
    property string lastStderr: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: delProc.lastStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.deleting = false
      root.pendingDeleteService = ""
      root.pendingDeleteAccount = ""
      if (!root.opened) return
      if (exitCode === 0) {
        root.setNotice("Deleted", false)
        root.refresh()
      } else if (root.notice === "" || !root.noticeIsError) {
        root.setNotice(delProc.lastStderr !== "" ? "Delete failed: " + delProc.lastStderr : "Delete failed", true)
      }
    }
  }

  // ---- window -------------------------------------------------------------
  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-secrets"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.72)
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a text field or the confirm dialog owns focus, keys belong to it.
      blocked: confirmDialog.opened
        || serviceField.activeFocus || accountField.activeFocus
        || secretField.activeFocus || filterField.activeFocus

      onMoveRequested: function(dx, dy) {
        // While the vault picker is open, keys act on it, not the hidden list.
        if (root.vaultOpen) return
        if (dy === 0 || root.filtered.length === 0) return
        var n = root.filtered.length
        root.selectedIndex = ((root.selectedIndex + dy) % n + n) % n
        pointerGate.reset()
      }
      onActivateRequested: { if (!root.vaultOpen) root.copySelected() }
      onDeleteRequested: { if (!root.vaultOpen) root.requestDeleteSelected() }
      onCloseRequested: {
        if (root.vaultOpen) { root.vaultOpen = false; return }
        root.dismiss()
      }
      onTextKey: function(t) {
        if (root.vaultOpen) return
        if (t === "/") { filterField.forceActiveFocus(); filterField.selectAll() }
        else if (t === "a") root.startAdd()
        else if (t === "r") root.refresh()
        else if (t === "v") root.cycleVault()
        else if (t === "s") root.cycleSort()
      }

      // Centered themed card; swallows clicks so only the scrim dismisses.
      Item {
        anchors.centerIn: parent
        width: card.width
        height: card.height
        scale: Math.min(1,
          (keyCatcher.width - Style.space(32)) / Math.max(1, width),
          (keyCatcher.height - Style.space(32)) / Math.max(1, height))

        MouseArea { anchors.fill: parent; onClicked: {} }

        // Rows sliding under a resting pointer must not steal the j/k
        // selection; the gate requires real movement first.
        PointerMoveGate {
          id: pointerGate
          referenceItem: card
        }

        BorderSurface {
          id: card
          width: Math.min(Style.space(560), keyCatcher.width - Style.space(48))
          height: Math.min(Style.space(480), keyCatcher.height - Style.space(48))
          color: Color.background
          borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
          padding: Style.space(20)
          radius: Style.cornerRadius

          ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: card.contentTopInset
            anchors.rightMargin: card.contentRightInset
            anchors.bottomMargin: card.contentBottomInset
            anchors.leftMargin: card.contentLeftInset
            spacing: Style.space(10)

            RowLayout {
              Layout.fillWidth: true
              Text {
                textFormat: Text.PlainText
                text: "SECRETS"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 2
              }
              Item { Layout.fillWidth: true }
              Text {
                textFormat: Text.PlainText
                text: root.loading ? "…" : root.filtered.length + " item" + (root.filtered.length === 1 ? "" : "s")
                color: Util.alpha(Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                id: vaultButton
                Layout.fillWidth: true
                text: root.vaultLabel() + "  ▾"
                focusable: false
                onClicked: root.vaultOpen = !root.vaultOpen
              }

              Button {
                text: root.sortMode === "name" ? "Name" : "Recent"
                focusable: false
                onClicked: root.cycleSort()
              }
            }

            // Vault picker overlays the list while open; Escape/v close it.
            // ListView virtualizes delegates so many vaults scroll instead of
            // overflowing the card.
            ListView {
              visible: root.vaultOpen
              Layout.fillWidth: true
              Layout.preferredHeight: Math.min(contentHeight, Style.space(200))
              clip: true
              spacing: Style.space(2)
              model: root.vaultOpen
                ? [{ service: allVaults, count: root.items.length }].concat(root.vaults)
                : []

              delegate: Item {
                required property var modelData
                width: ListView.view ? ListView.view.width : 0
                height: Style.space(26)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: modelData.service === root.vault
                    ? Util.alpha(Color.accent, 0.18)
                    : "transparent"
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: modelData.service === allVaults ? "All vaults" : modelData.service
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.count
                    color: Util.alpha(Color.foreground, 0.45)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectVault(modelData.service)
                }
              }
            }

            TextField {
              id: filterField
              Layout.fillWidth: true
              placeholderText: "Filter…   ( / )"
              onTextChanged: {
                root.filter = text
                root.selectedIndex = 0
              }
              Keys.onEscapePressed: function(event) {
                if (text !== "") { text = ""; event.accepted = true; return }
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true

              // Empty states share one slot; the list sits on top.
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                visible: !root.loading && root.filtered.length === 0
                text: root.items.length === 0
                  ? (root.notice !== "" && root.noticeIsError ? "" : "No secrets stored")
                  : "No matches"
                color: Util.alpha(Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              // ListView virtualizes delegates (matters at ~700 items) and
              // keeps the keyboard selection on screen.
              ListView {
                anchors.fill: parent
                visible: !root.vaultOpen
                clip: true
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds
                model: root.filtered
                currentIndex: root.selectedIndex
                onCurrentIndexChanged: {
                  if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                }

                delegate: Item {
                  id: row
                  required property int index
                  required property var modelData

                  width: ListView.view.width
                  height: Style.space(34)

                  readonly property bool isSelected: index === root.selectedIndex
                  readonly property bool isActionable: root.actionable(modelData)
                  readonly property bool isExternal: modelData.app !== "omarchy"

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: isSelected ? Util.alpha(Color.accent, 0.18) : "transparent"
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(8)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: isActionable
                        ? modelData.service + " / " + modelData.account
                        : (modelData.label || "(unnamed)")
                      color: isActionable
                        ? (isSelected ? Color.foreground : Util.alpha(Color.foreground, 0.85))
                        : Util.alpha(Color.foreground, 0.45)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: !isActionable || isExternal
                      textFormat: Text.PlainText
                      text: isActionable ? "ext" : "other app"
                      color: Util.alpha(Color.foreground, 0.35)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: isActionable && isSelected
                      textFormat: Text.PlainText
                      text: "copy"
                      color: Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: isActionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onPositionChanged: function(mouse) {
                      if (pointerGate.moved(row, mouse)) root.selectedIndex = index
                    }
                    // copySelected() explains itself for foreign rows; sync
                    // selection first so a click acts on the clicked row.
                    onClicked: { root.selectedIndex = index; root.copySelected() }
                  }
                }
              }
            }

            // Add form slides in under the list.
            ColumnLayout {
              visible: root.adding
              Layout.fillWidth: true
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                TextField {
                  id: serviceField
                  Layout.fillWidth: true
                  placeholderText: "service"
                  Keys.onReturnPressed: accountField.forceActiveFocus()
                  Keys.onEscapePressed: root.cancelAdd()
                }
                TextField {
                  id: accountField
                  Layout.fillWidth: true
                  placeholderText: "account"
                  Keys.onReturnPressed: secretField.forceActiveFocus()
                  Keys.onEscapePressed: root.cancelAdd()
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                TextField {
                  id: secretField
                  Layout.fillWidth: true
                  placeholderText: "secret"
                  password: true
                  Keys.onReturnPressed: root.submitAdd()
                  Keys.onEscapePressed: root.cancelAdd()
                }
                Button {
                  text: root.saving ? "…" : "Save"
                  focusable: false
                  onClicked: root.submitAdd()
                }
                Button {
                  text: "Cancel"
                  focusable: false
                  onClicked: root.cancelAdd()
                }
              }
            }

            Text {
              visible: root.notice !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.notice
              color: root.noticeIsError ? Color.urgent : Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // Hints must never paint past the card edge: fillWidth + elide
            // keeps them inside, and tight `·` separators keep the full
            // string visible at the normal card width.
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: "j/k move · enter copy · x del · / filter · v vault · s sort · a add · r refresh · esc close"
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        confirmText: "Delete"
        Keys.onPressed: function(event) {
          if (handleKey(event)) event.accepted = true
        }
        onCanceled: {
          opened = false
          root.pendingDeleteService = ""
          root.pendingDeleteAccount = ""
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: {
          opened = false
          if (root.pendingDeleteService === "") { keyCatcher.forceActiveFocus(); return }
          root.deleting = true
          // Purge the clipboard first while the keyring copy still exists for
          // clipclear's compare; then delete every item matching the pair.
          delProc.command = ["bash", "-c",
            "omarchy-secrets-clipclear \"$1\" \"$2\" 2>/dev/null || true; exec omarchy-secrets-delete \"$1\" \"$2\"",
            "bash", root.pendingDeleteService, root.pendingDeleteAccount]
          delProc.running = true
          keyCatcher.forceActiveFocus()
        }
      }
    }
  }
}
