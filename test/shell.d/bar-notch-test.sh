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
  /command: \[Quickshell\.env\("OMARCHY_PATH"\) \+ "\/bin\/omarchy-hw-apple-silicon"\]/.test(barSource) &&
    /onExited: function\(exitCode\) \{ root\.appleSiliconHost = exitCode === 0 \}/.test(barSource),
  'bar detects Apple Silicon directly through OMARCHY_PATH'
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
JS
