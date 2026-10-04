import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  // The display the brightness is for: the focused one, or the built-in
  // panel when the focused display can't be dimmed.
  property string brightnessMonitor: ""
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0
  // The display module's main display ("" while the module isn't managing
  // monitors, which hides the arrangement), and the display Identify is
  // showing its number on: a connector, "*" for every display, or "".
  property string mainName: ""
  property string identifying: ""
  // With the display module and two or more displays on, scale is Linked
  // displays (every display showing things the same real size) or Per
  // display (each keeps its own), as the module remembers it, and every
  // display has its own scale row, whichever display this panel opened on.
  readonly property bool arranged: mainName !== "" && enabledDisplayCount > 1
  property bool perDisplay: false
  property var pendingAction: null
  readonly property var panelMonitor: button.QsWindow.window ? Hyprland.monitorFor(button.QsWindow.window.screen) : null

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale<n>"   - one row of up to 6 Button scale presets per display
  //                  (see scaleRows); each treated as a single horizontal
  //                  row from j/k's perspective. h/l moves between presets,
  //                  identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row. r opens the row's rotation menu,
  //                  which takes j/k and Enter until it closes.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]

  // A scale row for every display, display 1 first, while the display module
  // arranges them; otherwise one for the focused display.
  readonly property var scaleRows: {
    var names = arranged ? arrangement.displays.map(function(d) { return d.name }) : [focusedMonitor]
    return names.map(function(name, index) {
      var display = displayNamed(name)
      return {
        name: name,
        number: arranged ? index + 1 : 0,
        section: "scale" + index,
        width: display ? display.width : 0,
        height: display ? display.height : 0,
        values: display ? Model.availableScales(scalePresets, display.width, display.height) : scalePresets
      }
    })
  }

  function scaleRow(section) {
    for (var i = 0; i < scaleRows.length; i++) {
      if (scaleRows[i].section === section) return scaleRows[i]
    }
    return null
  }

  // Linked, the scale every display would get for each preset of each
  // display (the module's linked_preview), and the preset under the pointer
  // or keyboard cursor, so the other rows can show where they'd land.
  property var linkedPreview: ({})
  readonly property var previewFrom: {
    var scales = cursorActive && arranged && !perDisplay ? scaleRow(focusSection) : null
    return scales && selectedIndex >= 0 && selectedIndex < scales.values.length
      ? { name: scales.name, preset: scales.values[selectedIndex] }
      : null
  }

  // The display rows, in display order (display 1 first), those that are off
  // last.
  readonly property var rows: Model.numberedDisplays(displays, arrangement.displays.map(function(d) { return d.name }))

  function displayNamed(name) {
    for (var i = 0; i < displays.length; i++) {
      if (displays[i] && displays[i].name === name) return displays[i]
    }
    return null
  }

  function liveScale(name) {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === name) return values[i].scale
    }
    return monitorScale
  }

  function liveTransform(name) {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === name) return values[i].lastIpcObject ? values[i].lastIpcObject.transform || 0 : 0
    }
    return 0
  }

  // Every display that's on turns, while the display module arranges them.
  function rotatable(display) {
    return root.mainName !== "" && !!display && display.enabled
  }
  property string focusSection: "scale0"
  property int selectedIndex: 0
  property bool cursorActive: false

  // The display whose rotation menu is open ("" while none is), and the
  // rotation under the pointer or keyboard cursor in it.
  property string rotatingName: ""
  property int rotationIndex: 0
  readonly property bool rotationMenuOpen: rotatingName !== "" && rows.some(function(d) { return d.name === rotatingName && rotatable(d) })

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    for (var i = 0; i < scaleRows.length; i++) list.push(scaleRows[i].section)
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "monitors") return rows.length
    var scales = scaleRow(section)
    return scales ? scales.values.length : 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || scaleRow(section) !== null
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in a scale row, walks its presets; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    var scales = scaleRow(focusSection)
    if (!scales) return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scales.values.length - 1) next = scales.values.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (rotationMenuOpen) {
      setRotation(rotatingName, Model.rotationOptions()[rotationIndex].transform)
      return
    }
    var scales = scaleRow(focusSection)
    if (scales && selectedIndex >= 0 && selectedIndex < scales.values.length) {
      setScale(scales.values[selectedIndex], scales.name)
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < rows.length) {
      var d = rows[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; a scale row clamps into its presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  // One action at a time; the last one asked for while another runs goes next.
  function run(command) {
    if (actionProc.running) {
      root.pendingAction = command
      return
    }
    actionProc.command = command
    actionProc.running = true
  }

  // The module keeps the choice; Linked displays matches every display to
  // main again.
  function setScaleMode(each) {
    root.perDisplay = each
    run(["hyprctl", "eval", "omarchy_displays.set_scale_mode(\"" + (each ? "each" : "linked") + "\")"])
  }

  function setMain(name) {
    run(["hyprctl", "eval", "omarchy_displays.set_main(\"" + name + "\")"])
  }

  // Where the arrangement dropped a display, in logical pixels.
  function moveDisplay(name, x, y) {
    run(["hyprctl", "eval", "omarchy_displays.move(\"" + name + "\", " + x + ", " + y + ")"])
  }

  // Opens display `name`'s rotation menu at the rotation it has, or closes
  // the menu when it's open.
  function toggleRotationMenu(name) {
    if (root.rotatingName === name) {
      root.rotatingName = ""
      return
    }
    root.rotationIndex = liveTransform(name) % 4
    root.rotatingName = name
  }

  function setRotation(name, transform) {
    root.rotatingName = ""
    var command = Model.rotationCommand(name, transform)
    if (command) run(command)
  }

  // Shows a display's number big on that display for a moment, or every
  // display's without a name.
  function identify(name) {
    root.identifying = name || "*"
    identifyTimer.restart()
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!mainProc.running) mainProc.running = true
    if (!previewProc.running) previewProc.running = true
    // Quickshell's monitor list doesn't follow scale changes by itself.
    Hyprland.refreshMonitors()
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.brightnessMonitor || root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  // The preset a scale row highlights for its display's live scale. A row
  // that comes through a Repeater's modelData has its values as a QML list,
  // which closestScaleIndex doesn't take for an array.
  function activeScaleIndex(scales) {
    return scales.width > 0 ? Model.closestScaleIndex(Array.from(scales.values), liveScale(scales.name), scales.width, scales.height) : -1
  }

  // What a preset comes to on the display of a scale row.
  function effectiveScale(scales, scale) {
    return scales.width > 0 ? Model.cleanScale(scale, scales.width, scales.height) : normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    var command = Model.displayToggleCommand(name, enabled, root.mainName !== "")
    if (command) run(command)
  }

  function setScale(scale, name) {
    if (arranged) {
      run(["hyprctl", "eval", "omarchy_displays.set_scale(\"" + name + "\", " + Number(scale) + ")"])
    } else {
      run(["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale])
    }
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    rotatingName = ""
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        // The scale row of the display this panel opened on.
        var own = scaleRows.filter(function(scales) { return panelMonitor && scales.name === panelMonitor.name })[0] || scaleRows[0]
        focusSection = own ? own.section : "textsize"
        selectedIndex = own ? 0 : -1
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleRowsChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    // Not while a display is dragged: new monitor data rebuilds the tiles.
    running: root.opened && !arrangement.dragging
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
        root.brightnessMonitor = String(lines[8] || "").trim()
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: mainProc
    // hyprctl prints something else for an empty answer, so "-" stands for
    // "not managing monitors" and only a known display counts as main.
    command: ["hyprctl", "repl", "return omarchy_displays and (omarchy_displays.main_name() .. ' ' .. omarchy_displays.scale_mode()) or '-'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var fields = String(text || "").trim().split(" ")
        var known = Hyprland.monitors.values.some(function(m) { return m.name === fields[0] })
        root.mainName = known ? fields[0] : ""
        root.perDisplay = fields[1] === "each"
      }
    }
  }

  Process {
    id: previewProc
    command: ["hyprctl", "repl", "return omarchy_displays and omarchy_displays.linked_preview() or '{}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.linkedPreview = JSON.parse(String(text || "{}")) || {}
        } catch (e) {
          root.linkedPreview = {}
        }
      }
    }
  }

  Timer {
    id: identifyTimer
    interval: 2000
    onTriggered: root.identifying = ""
  }

  Variants {
    model: root.identifying !== "" ? Quickshell.screens : []

    PanelWindow {
      id: identifyWindow
      required property var modelData
      readonly property var monitor: Hyprland.monitorFor(modelData)

      screen: modelData
      visible: root.identifying === "*" || (!!monitor && monitor.name === root.identifying)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}
      WlrLayershell.namespace: "omarchy-identify"
      WlrLayershell.layer: WlrLayer.Overlay

      Column {
        anchors.centerIn: parent

        DisplayBadge {
          anchors.horizontalCenter: parent.horizontalCenter
          number: {
            for (var i = 0; i < arrangement.displays.length; i++) {
              if (identifyWindow.monitor && arrangement.displays[i].name === identifyWindow.monitor.name) return i + 1
            }
            return 0
          }
          size: modelData.height / 3
          color: "white"
          fontFamily: root.bar.fontFamily
          layer.enabled: true
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.4
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: identifyWindow.monitor ? Model.displayLabel(root.displayNamed(identifyWindow.monitor.name)) : ""
          color: "white"
          style: Text.Outline
          styleColor: Qt.rgba(0, 0, 0, 0.6)
          font.family: root.bar.fontFamily
          font.pixelSize: modelData.height / 24
        }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      var next = root.pendingAction
      root.pendingAction = null
      if (next) {
        root.run(next)
        return
      }
      root.refresh()
      settleRefresh.restart()
    }
  }

  // Hyprland applies new monitor rules on its next frame, which can come after
  // the first read, so the arrangement and scales are read again once they
  // have landed.
  Timer {
    id: settleRefresh
    interval: 300
    onTriggered: root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // As tall as its content, which grows with every display, up to the
    // screen's height.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        // An open rotation menu takes j/k.
        if (root.rotationMenuOpen) {
          root.rotationIndex = Math.max(0, Math.min(3, root.rotationIndex + dy))
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.scaleRow(root.focusSection)) root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive || root.rotationMenuOpen) root.activateCursor()
      onCloseRequested: {
        if (root.rotationMenuOpen) root.rotatingName = ""
        else root.close()
      }
      // r opens the rotation menu of the display row under the cursor.
      onTextKey: function(text) {
        var display = root.focusSection === "monitors" ? root.rows[root.selectedIndex] : null
        if (text === "r" && root.cursorActive && root.rotatable(display)) root.toggleRotationMenu(display.name)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        // Only a screen too short for it scrolls, with the scroll bar beside
        // the content rather than over it.
        readonly property bool overflowing: panelColumn.implicitHeight > height
        anchors.fill: parent
        clip: true
        rightPadding: overflowing ? ScrollBar.vertical.width + Style.space(4) : 0
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: overflowing ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: scrollArea.overflowing
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              // Which display it's for, once there are two to tell apart: its
              // number in the column the scale rows keep theirs in, with the
              // slider starting where their scales do.
              DisplayBadge {
                id: brightnessBadge
                readonly property var target: root.rows.filter(function(d) { return d.name === root.brightnessMonitor })[0]
                readonly property bool shown: root.arranged && number > 0
                visible: shown
                number: target ? target.number : 0
                x: Style.space(6) + (Style.space(22) - width) / 2
                anchors.verticalCenter: parent.verticalCenter
                size: Style.font.title * 1.4
                color: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: brightnessBadge.shown ? Style.space(36) : Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: scaleModes
                visible: root.arranged
                spacing: Style.spacing.xs
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                  model: [{ label: "Linked displays", each: false }, { label: "Per display", each: true }]

                  Button {
                    required property var modelData
                    text: modelData.label
                    fontSize: Style.font.caption
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.sm
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    active: root.perDisplay === modelData.each
                    onClicked: root.setScaleMode(modelData.each)
                  }
                }
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: !root.arranged && root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // A row per display, marked with its number while there's more
            // than one.
            Column {
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.scaleRows

                Row {
                  id: scaleRow
                  required property var modelData

                  readonly property int active: root.activeScaleIndex(modelData)
                  // Linked, the preset this display lands on for the one
                  // under the cursor in another row.
                  readonly property int landing: {
                    var from = root.previewFrom
                    var presets = from && from.name !== modelData.name ? root.linkedPreview[from.name] : null
                    var scale = presets && presets[from.preset] ? presets[from.preset][modelData.name] : undefined
                    return scale !== undefined && modelData.width > 0
                      ? Model.closestScaleIndex(Array.from(modelData.values), scale, modelData.width, modelData.height)
                      : -1
                  }
                  readonly property int count: modelData.values.length
                  readonly property real pillWidth: count > 0
                    ? (width - (modelData.number > 0 ? badgeSlot.width + spacing : 0) - spacing * (count - 1)) / count
                    : 0

                  width: parent.width
                  spacing: Style.spacing.xs

                  // The number as big as in the display list below, and in
                  // line with it: that list insets its rows, centres the
                  // number in a column of its own and starts the name after
                  // a gap, where the scales start here.
                  Item {
                    id: badgeSlot
                    visible: scaleRow.modelData.number > 0
                    width: Style.space(6) + Style.space(22) + Style.space(8) - scaleRow.spacing
                    height: rowBadge.height
                    anchors.verticalCenter: parent.verticalCenter

                    DisplayBadge {
                      id: rowBadge
                      x: Style.space(6) + (Style.space(22) - width) / 2
                      number: scaleRow.modelData.number
                      size: Style.font.title * 1.4
                      color: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                    }
                  }

                  Repeater {
                    model: scaleRow.modelData.values

                    ScalePill {
                      required property string modelData
                      required property int index

                      scales: scaleRow.modelData
                      scaleValue: modelData
                      scaleIndex: index
                      active: scaleRow.active === index
                      previewed: scaleRow.landing === index
                      width: scaleRow.pillWidth
                    }
                  }
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            Item {
              width: parent.width
              implicitHeight: Math.max(displaysHeader.implicitHeight, identifyButton.implicitHeight)

              PanelSectionHeader {
                id: displaysHeader
                text: "DISPLAYS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: identifyButton
                visible: root.arranged
                text: "Identify"
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.identify()
              }
            }

            // Drag a display to arrange, click it to see its number on it;
            // ★ in a row makes that display main.
            Arrangement {
              id: arrangement
              width: parent.width
              visible: root.arranged
              bar: root.bar
              mainName: root.mainName
              identified: root.identifying
              onMoveRequested: function(name, x, y) { root.moveDisplay(name, x, y) }
              onIdentifyRequested: function(name) { root.identify(name) }
            }

            Repeater {
              model: root.rows

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // A preset in the scale row `scales` (one of root.scaleRows).
  component ScalePill: Button {
    id: pill
    required property var scales
    required property string scaleValue
    required property int scaleIndex
    // Where this display lands, Linked, for the preset under the cursor.
    property bool previewed: false

    text: root.effectiveScale(scales, scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    hasCursor: previewed || (root.cursorActive && root.focusSection === scales.section && root.selectedIndex === scaleIndex)

    onClicked: root.setScale(scaleValue, scales.name)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = pill.scales.section
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      // Above the row's own click area, so the ★ gets its clicks.
      z: 1
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Item {
        width: Style.space(22)
        height: rowBadge.height
        anchors.verticalCenter: parent.verticalCenter

        // The display number, once there is more than one to tell apart.
        DisplayBadge {
          id: rowBadge
          anchors.horizontalCenter: parent.horizontalCenter
          number: root.enabledDisplayCount > 1 ? monitorRow.display.number || 0 : 0
          size: Style.font.title * 1.4
          color: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }
      }

      Text {
        textFormat: Text.PlainText
        text: Model.displayLabel(monitorRow.display) + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16) - (root.arranged ? Style.space(24) : 0)
          - (rotationChip.visible ? rotationChip.width + Style.space(8) : 0)
        anchors.verticalCenter: parent.verticalCenter
      }

      // The display's rotation; a click opens the four to choose from.
      Text {
        id: rotationChip
        // The display's transform. Not `transform`, which every Item has.
        readonly property int turn: root.liveTransform(monitorRow.display.name)
        readonly property bool open: root.rotatingName === monitorRow.display.name

        visible: root.rotatable(monitorRow.display)
        onVisibleChanged: if (!visible && open) root.rotatingName = ""
        textFormat: Text.PlainText
        text: "󰑧" + (turn ? " " + Model.rotationLabel(turn) : "") + " 󰅀"
        color: root.bar.foreground
        // Quiet until the display is turned or its menu is open.
        opacity: turn || open ? 1 : 0.55
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        width: Math.ceil(rotationWidest.advanceWidth)
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter

        TextMetrics {
          id: rotationWidest
          font: rotationChip.font
          text: "󰑧 270° 󰅀"
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleRotationMenu(monitorRow.display.name)
        }

        Popup {
          id: rotationMenu
          readonly property real gap: Style.spacing.xxs

          // Below the chip, or above it where the panel ends too soon.
          x: rotationChip.width - width
          y: {
            var overlay = Overlay.overlay
            if (!overlay || !visible) return rotationChip.height + gap
            var top = rotationChip.mapToItem(overlay, 0, 0).y
            return top + rotationChip.height + gap + height > overlay.height ? -height - gap : rotationChip.height + gap
          }
          width: Style.space(120)
          padding: Style.spacing.hairline
          // The chip toggles it; a press anywhere else closes it.
          closePolicy: Popup.CloseOnPressOutsideParent
          focus: false
          onClosed: if (rotationChip.open) root.rotatingName = ""

          Connections {
            target: root
            function onRotatingNameChanged() {
              if (root.rotatingName === monitorRow.display.name) rotationMenu.open()
              else rotationMenu.close()
            }
          }

          background: BorderSurface {
            color: Color.popups.background
            borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
            radius: Style.cornerRadius
          }

          contentItem: Column {
            spacing: Style.spacing.labelGap

            Repeater {
              model: Model.rotationOptions()

              Rectangle {
                id: rotationOption
                required property var modelData
                required property int index
                readonly property bool highlighted: index === root.rotationIndex
                readonly property color ink: highlighted ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground

                width: rotationMenu.availableWidth
                height: Style.spacing.popupRowHeight
                radius: Style.cornerRadius
                color: highlighted ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: rotationOption.modelData.label
                  color: rotationOption.ink
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: rotationOption.modelData.transform === rotationChip.turn ? "󰄬" : ""
                  color: rotationOption.ink
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.rotationIndex = rotationOption.index
                  onClicked: root.setRotation(monitorRow.display.name, rotationOption.modelData.transform)
                }
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.arranged
        text: monitorRow.display.name === root.mainName ? "★" : "☆"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setMain(monitorRow.display.name)
        }
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
