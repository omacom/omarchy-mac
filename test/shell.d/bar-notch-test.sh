#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const bar = requireFromRoot('shell/plugins/bar/BarModel.js')
const barSource = fs.readFileSync(root + '/shell/plugins/bar/Bar.qml', 'utf8')
const styleSource = fs.readFileSync(root + '/shell/Commons/Style.qml', 'utf8')

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

const cutouts = bar.parseCutouts(JSON.stringify({ panels: [
  { connector: 'eDP', width: 3024, height: 1964, cutoutWidth: 420 },
  { connector: 'eDP', width: 2560, height: 1664 }
] }))
const mode = (width, height, transform = 0) => ({ width, height, transform })
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, mode(3024, 1964)), 210, 'scale 2 halves the physical cutout width')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 3024, 1964, mode(3024, 1964)), 420, 'scale 1 keeps the physical width')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1890, 1228, mode(3024, 1964)), 263, 'fractional scaling reserves every cutout column')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, null), 0, 'a missing monitor mode leaves the layout unchanged')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1890, 1228, null), 0, 'fractional scaling without a mode never guesses')
assertEqual(bar.cutoutLeftEdge(cutouts, 'top', 'eDP-1', 1512, 982, mode(3024, 1964)), 651, 'the cutout starts at logical column 651')
for (const position of ['bottom', 'left', 'right'])
  assertEqual(bar.cutoutLeftEdge(cutouts, position, 'eDP-1', 1512, 982, mode(3024, 1964)), 0, `${position} bars keep their layout`)
for (const name of ['DP-1', 'HDMI-A-1'])
  assertEqual(bar.cutoutWidthAt(cutouts, 'top', name, 1512, 982, mode(3024, 1964)), 0, `${name} keeps its layout`)
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1280, 832, mode(2560, 1664)), 0, 'a panel without a measured width keeps its layout')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, mode(3024, 1890)), 0, 'a different mode keeps its layout')
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 0, 0, null), 0, 'an empty screen has no cutout')
for (const transform of [1, 2, 3, 5, 6, 7])
  assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, mode(3024, 1964, transform)), 0, `transform ${transform} has no top cutout`)
assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, mode(3024, 1964, 4)), 210, 'horizontal mirroring preserves a centered cutout')
for (const unknown of [
  mode(0, 0, 2),
  { width: 3024, height: 1964 },
  mode(3024, 1964, null),
  mode(3024, 1964, false)
])
  assertEqual(bar.cutoutWidthAt(cutouts, 'top', 'eDP-1', 1512, 982, unknown), 0, 'invalid mode or unknown orientation leaves the layout unchanged')
for (const text of ['', 'bad json', 'null', '[]', '{"panels":{}}'])
  assertDeepEqual(bar.parseCutouts(text), [], 'invalid descriptions leave the layout unchanged')
for (const bad of [true, false, null, '420', 1.5, 0, -1, 3024])
  assertDeepEqual(bar.parseCutouts(JSON.stringify({ panels: [
    { connector: 'eDP', width: 3024, height: 1964, cutoutWidth: bad }
  ] })), [], `invalid width ${JSON.stringify(bad)} leaves the layout unchanged`)
const narrow = bar.parseCutouts(JSON.stringify({ panels: [
  { connector: 'eDP', width: 100, height: 100, cutoutWidth: 1 }
] }))
assertEqual(narrow.length, 1, 'one physical column is a valid positive cutout width')
assertEqual(bar.cutoutLeftEdge(narrow, 'top', 'eDP-1', 100, 100, mode(100, 100)), 49, 'a one-column cutout keeps its safe left edge')

assertDeepEqual(bar.notchSlotLayout([500], 300, 647), [
  { x: 147, visible: false }
], 'an oversized center control cannot overlap the left controls')
assertDeepEqual(bar.notchSlotLayout([200, 400, 100], 300, 647), [
  { x: -53, visible: false },
  { x: 147, visible: false },
  { x: 547, visible: true }
], 'overflow drops whole leading controls and keeps a complete trailing control')
assertDeepEqual(bar.notchSlotLayout([247, 100], 300, 647), [
  { x: 300, visible: true },
  { x: 547, visible: true }
], 'controls that exactly fit keep their full width and order')
assertDeepEqual(bar.notchSlotLayout([248, 100], 300, 647), [
  { x: 299, visible: false },
  { x: 547, visible: true }
], 'one overflowing pixel hides the whole control instead of clipping it')
assertDeepEqual(bar.notchSlotLayout([100], 647, 647), [
  { x: 547, visible: false }
], 'no available space hides every center control')
assertDeepEqual(bar.notchSlotLayout([0, 100], 300, 647), [
  { x: 547, visible: false },
  { x: 547, visible: true }
], 'an empty control consumes no space or input target')
assertDeepEqual(bar.notchSlotLayout([347, 0], 300, 647), [
  { x: 300, visible: true },
  { x: 647, visible: false }
], 'a hidden trailing control does not push a control that fits out of the space')
assertDeepEqual(bar.notchSlotLayout([100, 0, 247], 300, 647), [
  { x: 300, visible: true },
  { x: 400, visible: false },
  { x: 400, visible: true }
], 'a hidden control between two others leaves no blank slot')
assertDeepEqual(bar.notchSlotLayout([], 300, 647), [], 'an empty center section stays empty')
JS
