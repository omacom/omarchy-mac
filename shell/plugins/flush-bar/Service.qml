import Quickshell
import Quickshell.Hyprland
import QtQuick 6.11

// Keeps the window gap on the bar's edge in step with the bar: 0 when the bar
// is transparent (windows sit flush under it) or the same as the other edges
// when opaque. The shell persists every bar change — edge moves and the
// transparency toggle — into shell.json, which surfaces here as
// shell.barConfig, so binding to it sees the same state the bar itself sees.
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell
  property var manifest

  // The state we last handed to gaps.sh, so a bar move can restore the edge
  // it came from and unchanged applies are skipped.
  property bool applied: false
  property string appliedPosition: ""
  property bool appliedTransparent: false

  // Boot / reload can race the first apply: monitor-clamshell and similar
  // paths call `hyprctl reload` after the shell is up, which resets gaps_out
  // to the config default. A single immediate re-assert on configreloaded is
  // not enough either — Hyprland can still be settling (see Style.qml's
  // refreshTimer). Count how many startup passes remain.
  property int startupPassesRemaining: 0

  readonly property var barConfig: shell ? shell.barConfig : null
  readonly property string position: normalizePosition(barConfig && barConfig.position)
  readonly property bool transparent: !!(barConfig && barConfig.transparent === true)

  readonly property string gapsScript: decodeURIComponent(
    Qt.resolvedUrl("gaps.sh").toString().replace(/^file:\/\//, ""))

  // Same normalization the bar applies to its own config (BarModel.js).
  function normalizePosition(value) {
    var next = String(value || "").trim()
    return /^(top|bottom|left|right)$/.test(next) ? next : "top"
  }

  // Hand the bar's edge and transparency to gaps.sh, which sets Hyprland's
  // gaps_out: 0 under a transparent bar (windows flush) or the window gap when
  // opaque. Passing the edge the bar just moved off of lets the script restore
  // exactly that edge, so a hand-set zero elsewhere survives.
  function applyGaps(previousPosition) {
    var movedFrom = previousPosition === undefined ? position : previousPosition
    Quickshell.execDetached(["bash", gapsScript, position, transparent ? "true" : "false", movedFrom])
  }

  // Re-assert after a short settle delay. Used after config reload / monitor
  // events so we win the race against Hyprland applying its defaults.
  function reassertSoon() {
    if (!root.applied) return
    settleTimer.restart()
  }

  // Several re-asserts over the first few seconds of the session, covering
  // boot-time monitor reconciliation and delayed hyprctl reloads.
  function armStartupReassert() {
    startupPassesRemaining = 6
    startupTimer.restart()
  }

  function syncGaps() {
    if (!shell) return
    if (applied && position === appliedPosition && transparent === appliedTransparent) return
    var previous = applied ? appliedPosition : position
    var firstApply = !applied
    applied = true
    appliedPosition = position
    appliedTransparent = transparent
    applyGaps(previous)
    // First successful bind (shell inject / first config) also arms the
    // multi-pass startup reassert so a later boot reload cannot strand us.
    if (firstApply) armStartupReassert()
  }

  // The shell injects `shell` right after creating the service, so the
  // onShellChanged handler doubles as the once-at-startup apply.
  onShellChanged: syncGaps()
  onPositionChanged: syncGaps()
  onTransparentChanged: syncGaps()

  // After a config reload Hyprland restores gaps_out from looknfeel; re-assert
  // immediately and again after a settle beat (Style.qml uses 200ms for the
  // same reason).
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !root.applied) return
      var name = String(event.name || "")
      if (name === "configreloaded" || name === "monitoradded" || name === "monitorremoved") {
        root.applyGaps()
        root.reassertSoon()
      }
    }
  }

  Timer {
    id: settleTimer
    interval: 250
    repeat: false
    onTriggered: if (root.applied) root.applyGaps()
  }

  // ~0.5s × 6 ≈ 3s of coverage after first apply. Cheap (gaps.sh is a quick
  // hyprctl getoption + eval) and only armed once per service lifetime.
  Timer {
    id: startupTimer
    interval: 500
    repeat: true
    onTriggered: {
      if (root.applied) root.applyGaps()
      root.startupPassesRemaining -= 1
      if (root.startupPassesRemaining <= 0) stop()
    }
  }
}
