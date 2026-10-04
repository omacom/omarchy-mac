#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const monitor = requireFromRoot('shell/plugins/panels/monitor/Model.js')

assertEqual(
  monitor.closestScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 2.4, 3456, 2160),
  3,
  'monitor highlights the nearest preset for a derived scale'
)
assertEqual(
  monitor.closestScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 3, 3456, 2160),
  4,
  'monitor highlights an exact preset'
)
const laptop = { x: 0, y: 0, w: 1152, h: 720 }
assertDeepEqual(
  monitor.snapPosition([laptop], { x: -1500, y: -150, w: 1600, h: 900 }),
  { x: -1600, y: -180 },
  'monitor arrangement snaps a display left of another with bottoms flush'
)
assertDeepEqual(
  monitor.snapPosition([laptop], { x: 1200, y: 300, w: 1600, h: 900 }),
  { x: 1152, y: 300 },
  'monitor arrangement keeps a free offset along the edge'
)
assertDeepEqual(
  monitor.snapPosition([laptop], { x: -200, y: -950, w: 1600, h: 900 }),
  { x: -224, y: -900 },
  'monitor arrangement centres a display dropped above another'
)
assertDeepEqual(
  monitor.snapPosition([laptop, { x: 1152, y: 0, w: 1000, h: 720 }], { x: 1100, y: 0, w: 800, h: 600 }),
  { x: 1100, y: -600 },
  'monitor arrangement moves a display dropped onto others to the nearest free edge'
)
// A 1280x720 display right of the laptop, dragged left over it.
assertDeepEqual(
  monitor.snapPosition([laptop], { x: -100, y: 0, w: 1280, h: 720 }),
  { x: -1280, y: 0 },
  'monitor arrangement puts a display dragged past the middle of another on its far side'
)
assertDeepEqual(
  monitor.snapPosition([laptop], { x: 200, y: 0, w: 1280, h: 720 }),
  { x: 1152, y: 0 },
  'monitor arrangement keeps a display not dragged past the middle on its side'
)
assertDeepEqual(
  monitor.snapPosition([laptop], { x: 130, y: -550, w: 1280, h: 720 }),
  { x: 130, y: -720 },
  'monitor arrangement puts a display dragged up over another above it'
)

assertEqual(monitor.clampBrightness(0), 1, 'monitor clamps minimum brightness')
assertEqual(monitor.clampBrightness(101), 100, 'monitor clamps maximum brightness')
assertEqual(monitor.clampBrightness(42.4), 42, 'monitor rounds brightness')
assertEqual(monitor.clampBrightness('nope'), 1, 'monitor rejects invalid brightness')

assertEqual(monitor.normalizeScale('1.250'), '1.25', 'monitor normalizes fractional scale')
assertEqual(monitor.normalizeScale('nope'), '', 'monitor rejects invalid scale')
assertEqual(monitor.cleanScale(3, 1280, 800), '3.2', 'monitor matches clean VM scale')
assertEqual(monitor.cleanScale(1.25, 1280, 800), '1.25', 'monitor preserves an already clean scale')
assertEqual(monitor.cleanScale(1.25, 6016, 3384), '1.33', 'monitor matches clean physical display scale')
assertEqual(monitor.cleanScale(1.6, 0, 800), '', 'monitor rejects a missing display mode')
assertEqual(
  monitor.matchingScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 3.2, 1280, 800),
  4,
  'monitor selects an approximated VM scale'
)
assertEqual(
  monitor.matchingScaleIndex(['1', '1.25', '1.6', '2', '3', '4'], 4, 4, 4),
  5,
  'monitor selects an exact preset'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 1280, 800),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps distinct approximated VM scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 6016, 3384),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps distinct approximated physical display scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 1280, 804),
  ['1', '1.25', '2', '4'],
  'monitor collapses presets with duplicate effective scales'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 5968, 3230),
  ['1', '2'],
  'monitor hides presets the current mode cannot reach'
)
assertDeepEqual(
  monitor.availableScales(['1', '1.25', '1.6', '2', '3', '4'], 0, 0),
  ['1', '1.25', '1.6', '2', '3', '4'],
  'monitor keeps presets until display dimensions are known'
)

assertEqual(monitor.brightnessName(96), 'Sun blast', 'monitor names very bright displays')
assertEqual(monitor.brightnessName(12), 'Candlelit', 'monitor names dim displays')

assertDeepEqual(
  monitor.parseDisplays(JSON.stringify([
    { name: 'eDP-1', enabled: true, focused: false, width: 1920, height: 1080 },
    { name: 'HDMI-A-1', enabled: false, focused: false, width: 0, height: 0 },
    { name: 'DP-1', enabled: true, focused: true, width: 1280, height: 800 }
  ])),
  {
    displays: [
      { name: 'eDP-1', enabled: true, focused: false, width: 1920, height: 1080 },
      { name: 'HDMI-A-1', enabled: false, focused: false, width: 0, height: 0 },
      { name: 'DP-1', enabled: true, focused: true, width: 1280, height: 800 }
    ],
    enabledDisplayCount: 2
  },
  'monitor parses display state'
)

assertDeepEqual(monitor.parseDisplays('{'), { displays: [], enabledDisplayCount: 0 }, 'monitor handles invalid display JSON')

assertDeepEqual(
  monitor.displayToggleCommand('HDMI-A-1', true),
  ['hyprctl', 'eval', 'hl.monitor({ output = "HDMI-A-1", disabled = true })'],
  'monitor disables an external display through the Lua config'
)
assertDeepEqual(
  monitor.displayToggleCommand('HDMI-A-1', false),
  ['hyprctl', 'eval', 'hl.monitor({ output = "HDMI-A-1", mode = "preferred", position = "auto", scale = "auto", disabled = false })'],
  'monitor re-enables an external display with a complete rule'
)
assertDeepEqual(
  monitor.displayToggleCommand('eDP-1', true),
  ['omarchy-hyprland-monitor-internal', 'off'],
  'monitor switches the internal panel through its own command'
)
assertDeepEqual(
  monitor.displayToggleCommand('HDMI-A-1', true, true),
  ['hyprctl', 'eval', 'omarchy_displays.set_enabled("HDMI-A-1", false)'],
  'monitor switches an external display off through the display module when it manages displays'
)
assertDeepEqual(
  monitor.displayToggleCommand('HDMI-A-1', false, true),
  ['hyprctl', 'eval', 'omarchy_displays.set_enabled("HDMI-A-1", true)'],
  'monitor switches it back on through the display module'
)
assertEqual(monitor.displayToggleCommand('DP-1"}) os.exit()--', true), null, 'monitor refuses an unsafe display name')
assertDeepEqual(
  monitor.numberedDisplays([{ name: 'eDP-1' }, { name: 'HDMI-A-1' }, { name: 'USB-2' }], ['USB-2', 'eDP-1']).map(function(d) { return d.number + ' ' + d.name }),
  ['1 USB-2', '2 eDP-1', '0 HDMI-A-1'],
  'monitor lists displays in display order with their numbers, those that are off last'
)
assertEqual(monitor.displayLabel({ name: 'eDP-1', model: '' }), 'Built-in display', 'monitor calls the internal panel the built-in display')
assertEqual(monitor.displayLabel({ name: 'USB-2', model: 'BenQ LCD' }), 'BenQ LCD', 'monitor names an external display by its model')
assertEqual(monitor.displayLabel({ name: 'DP-1', model: '' }), 'DP-1', 'monitor falls back to the connector')
assertDeepEqual(
  monitor.rotationOptions().map(function(r) { return r.transform + ' ' + r.label }),
  ['0 Standard', '1 90°', '2 180°', '3 270°'],
  'monitor offers the four rotations, as Hyprland counts them'
)
assertDeepEqual(
  [0, 3, 4, 5, 9, undefined].map(monitor.rotationLabel),
  ['Standard', '270°', 'Flipped', 'Flipped 90°', 'Flipped 270°', 'Standard'],
  'monitor names every transform, the flipped ones too'
)
assertDeepEqual(
  monitor.rotationCommand('USB-2', 1),
  ['hyprctl', 'eval', 'omarchy_displays.set_rotation("USB-2", 1)'],
  'monitor turns a display through the display module'
)
assertEqual(monitor.rotationCommand('USB-2', 5), null, 'monitor refuses a rotation it does not offer')
assertEqual(monitor.rotationCommand('DP-1"}) os.exit()--', 1), null, 'monitor refuses an unsafe display name for rotation')
JS
