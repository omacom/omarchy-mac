#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const bar = requireFromRoot('shell/plugins/bar/BarModel.js')
const barSource = fs.readFileSync(root + '/shell/plugins/bar/Bar.qml', 'utf8')
const styleSource = fs.readFileSync(root + '/shell/Commons/Style.qml', 'utf8')
const shellJson = fs.readFileSync(root + '/config/omarchy/shell.json', 'utf8')

// Panels measured on real hardware use their camera-cutout depth, which is
// shallower than the strip the panel exposes above its 16:10 area.
assertEqual(bar.notchHeight('eDP-1', 1512, 982, 2), 32, 'MacBook Pro 14" at scale 2 uses its measured 32px cutout')
assertEqual(bar.notchHeight('eDP-1', 1890, 1227, 1.6), 40, 'MacBook Pro 14" at scale 1.6 uses its measured cutout')
assertEqual(bar.notchHeight('eDP-1', 1728, 1117, 2), 32, 'MacBook Pro 16" at scale 2 uses the cutout inferred from the 14"')
assertEqual(bar.notchHeight('eDP-1', 1280, 832, 2), 28, 'MacBook Air 13.6" at scale 2 uses its density-scaled cutout')
assertEqual(bar.notchHeight('eDP-1', 1600, 1040, 1.6), 35, 'MacBook Air 13.6" at scale 1.6 uses its density-scaled cutout')
assertEqual(bar.notchHeight('eDP-1', 1440, 932, 2), 28, 'MacBook Air 15" at scale 2 uses its density-scaled cutout')

// Unmeasured panels fall back to the full strip above the 16:10 area, which
// errs taller than the cutout, never shorter. The display scale applies to
// both axes, so the same panel yields its strip at any scale.
assertEqual(bar.notchHeight('eDP-1', 1536, 990, 2), 30, 'an unmeasured notched panel falls back to its strip')

assertEqual(bar.notchHeight('eDP-1', 1280, 800, 2), 0, 'an exactly 16:10 panel (M1 Air) has no notch')
assertEqual(bar.notchHeight('DP-1', 1512, 982, 2), 0, 'external monitors never report a notch')
assertEqual(bar.notchHeight('eDP-1', 982, 1512, 2), 0, 'a rotated panel is not mistaken for a notch')
assertEqual(bar.notchHeight('eDP-1', 1128, 752, 2), 0, 'a 3:2 panel is not mistaken for a notch')
assertEqual(bar.notchHeight('eDP-1', 0, 0, 2), 0, 'degenerate screen sizes report no notch')
assertEqual(bar.notchHeight('', 1512, 982, 2), 0, 'a missing screen name reports no notch')
assertEqual(bar.notchHeight('eDP-1', 1512, 982, 0), 37, 'a missing scale still yields the strip fallback')

// The bar must gate the floor on Apple Silicon and only floor top bars —
// the strip formula alone would also match some non-Apple panels, and a
// bar on any other edge does not cover the notch.
assert(
  /notchFloor: root\.appleSiliconHost && root\.position === "top"/.test(barSource),
  'bar floors only top bars on Apple Silicon machines'
)
assert(
  /omarchyPath \+ "\/bin\/omarchy-hw-apple-silicon"/.test(barSource),
  'bar probes Apple Silicon through OMARCHY_PATH, not PATH'
)
assert(
  /BarModel\.notchHeight\(screen\.name, screen\.width, screen\.height, screen\.devicePixelRatio\)/.test(barSource),
  'bar derives the floor from its own screen geometry'
)
assert(
  /implicitHeight: root\.vertical \? 0 : Math\.max\(root\.barSize, notchFloor\)/.test(barSource),
  'bar height is floored at the notch, never shrunk to it'
)

// A calibrated [bar] notch-height wins over the derived value, and must not
// scale with the font — it describes physical pixels beside the camera.
assert(
  /Style\.bar\.notchHeight > 0[\s\S]{0,80}\? Style\.bar\.notchHeight/.test(barSource),
  'a calibrated notch-height overrides the derived floor'
)
assert(
  /notchHeight:[\s\S]{0,240}barOverrides\["notch-height"\]/.test(styleSource) &&
    !/barToken\("notch-height"/.test(styleSource),
  'notch-height is read raw, not through the font-scaled bar tokens'
)

// Every notched panel moves the center section beside the right one, at any scale.
const notchedPanels = [
  ['MacBook Pro 14"', 3024, 1964],
  ['MacBook Pro 16"', 3456, 2234],
  ['MacBook Air 13.6"', 2560, 1664],
  ['MacBook Air 15"', 2880, 1864]
]
for (const [name, width, height] of notchedPanels) {
  for (const scale of [1, 2]) {
    assertEqual(
      bar.centerBesideRight(true, 'top', 'eDP-1', width / scale, height / scale, scale),
      true,
      `${name} at scale ${scale} draws the center section beside the right one`
    )
  }
}
assertEqual(bar.centerBesideRight(true, 'top', 'eDP-1', 1890, 1228, 1.6), true, 'a fractional scale still moves the center section')

// Everything else keeps the configured layout.
assertEqual(bar.centerBesideRight(true, 'top', 'USB-2', 3440, 1440, 1), false, 'an external monitor on a notched Mac keeps the center section')
assertEqual(bar.centerBesideRight(true, 'top', 'DP-1', 1728, 1117, 2), false, 'an external monitor shaped like a notched panel keeps the center section')
assertEqual(bar.centerBesideRight(false, 'top', 'eDP-1', 1728, 1117, 2), false, 'a machine that is not Apple Silicon keeps the center section')
for (const position of ['bottom', 'left', 'right'])
  assertEqual(bar.centerBesideRight(true, position, 'eDP-1', 1728, 1117, 2), false, `a ${position} bar keeps the center section`)
assertEqual(bar.centerBesideRight(true, 'top', 'eDP-1', 1728, 1080, 2), false, 'a notched panel with its strip hidden keeps the center section')
assertEqual(bar.centerBesideRight(true, 'top', 'eDP-1', 1280, 800, 2), false, 'a panel without a notch keeps the center section')

// The move is per screen and draw-time only: the user's layout is read as
// configured, and the center entries keep their order and their own region.
assert(
  /centerBesideRight: BarModel\.centerBesideRight\(root\.appleSiliconHost, root\.position, screen\.name, screen\.width, screen\.height, screen\.devicePixelRatio\)/.test(barSource),
  'each bar surface decides the move from its own screen'
)
assert(
  /CenterModules \{\s*anchors\.fill: parent\s*entries: barWindow\.centerBesideRight \? \[\] : root\.layoutEntries\("center"\)\s*\}/.test(barSource),
  'a moved center section draws nothing in the middle of the bar'
)
assert(
  /ModuleList \{\s*entries: barWindow\.centerBesideRight \? root\.layoutEntries\("center"\) : \[\]\s*region: "center"\s*anchors\.right: rightModules\.left\s*anchors\.rightMargin: Style\.space\(\d+\)/.test(barSource),
  'the center entries sit just left of the right section in their own region'
)

// With no gap the last center slot and the first right slot would share an
// edge, and a drop there would always land in whichever registered first.
const seam = [
  { slot: 'right-first', x: 104, width: 20 },
  { slot: 'center-last', x: 80, width: 20 }
]
assertDeepEqual(bar.nearestDropTarget(seam, { x: 101 }, false), { slot: 'center-last', after: true }, 'a drop at the seam nearer the center section lands after its last entry')
assertDeepEqual(bar.nearestDropTarget(seam, { x: 103 }, false), { slot: 'right-first', after: false }, 'a drop at the seam nearer the right section lands before its first entry')
assert(
  /anchorEntry: root\.findCenterAnchorEntry\(entries\)/.test(barSource),
  'an emptied center section does not keep a hidden copy of its anchor'
)

const parsed = JSON.parse(shellJson)
assertEqual(parsed.bar.centerAnchor, 'omarchy.clock', 'shipped bar layout still anchors on the clock')
assert(
  JSON.stringify(parsed.bar.layout.center).indexOf('omarchy.indicators') >= 0,
  'shipped bar layout still keeps the default center widgets'
)
JS
