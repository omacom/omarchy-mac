function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var modeWidth = Number(width)
  var modeHeight = Number(height)
  if (!isFinite(requested) || !isFinite(modeWidth) || !isFinite(modeHeight)
      || requested <= 0 || modeWidth <= 0 || modeHeight <= 0) return ""

  var divisor = gcd(Math.round(modeWidth * 120), Math.round(modeHeight * 120))
  var scaleUnits = Math.round(requested * 120)
  if (scaleUnits > divisor) scaleUnits = divisor
  while (divisor % scaleUnits !== 0) scaleUnits++
  return normalizeScale(scaleUnits / 120)
}

function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1

  var bestIndex = -1
  var bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue

    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) {
      bestIndex = i
      bestDistance = distance
    }
  }
  return bestIndex
}

// The preset matching the current scale, or, for a scale between presets
// (derived from the main display), the nearest one.
function closestScaleIndex(scales, currentScale, width, height) {
  var index = matchingScaleIndex(scales, currentScale, width, height)
  var current = Number(currentScale)
  if (index >= 0 || !Array.isArray(scales) || !isFinite(current)) return index

  var bestDistance = Infinity
  for (var i = 0; i < scales.length; i++) {
    var distance = Math.abs(Number(cleanScale(scales[i], width, height)) - current)
    if (distance < bestDistance) {
      index = i
      bestDistance = distance
    }
  }
  return index
}

function availableScales(scales, width, height) {
  if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []

  var byEffectiveScale = {}
  for (var i = 0; i < scales.length; i++) {
    var requested = Number(scales[i])
    var effective = Number(cleanScale(requested, width, height))

    if (!isFinite(requested) || !isFinite(effective)) continue

    var key = normalizeScale(effective)
    var existing = byEffectiveScale[key]
    if (!existing || Math.abs(requested - effective) < existing.distance) {
      byEffectiveScale[key] = {
        value: String(scales[i]),
        index: i,
        distance: Math.abs(requested - effective)
      }
    }
  }

  return Object.keys(byEffectiveScale)
    .map(function(key) { return byEffectiveScale[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(candidate) { return candidate.value })
}

function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}

function parseDisplays(raw) {
  var displays = []
  try {
    displays = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    displays = []
  }
  if (!Array.isArray(displays)) displays = []

  var count = 0
  for (var i = 0; i < displays.length; i++) {
    if (displays[i] && displays[i].enabled) count++
  }

  return {
    displays: displays,
    enabledDisplayCount: count
  }
}

// Where a display dragged in the arrangement lands: flush against the side
// of another display nearest to where it was dropped, never overlapping one.
// Nearness counts in display sizes, the two displays' mean width across and
// mean height up and down, so a display dragged past the middle of another
// lands on its far side, and one dragged mostly up or down lands above or
// below it. Along that side it snaps to the ends or the centre when it's
// close, and otherwise keeps at least a pixel of edge shared. Rects are
// logical pixels { x, y, w, h }; others must not be empty.
function snapPosition(others, moving) {
  function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  }

  function along(start, span, size, dropped) {
    var stops = [start, start + span - size, start + Math.floor((span - size) / 2)]
    var reach = Math.max(span, size) * 0.1
    for (var i = 0; i < stops.length; i++) {
      if (Math.abs(dropped - stops[i]) <= reach) return stops[i]
    }
    return Math.max(start - size + 1, Math.min(dropped, start + span - 1))
  }

  var best = null
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    var y = along(o.y, o.h, moving.h, moving.y)
    var x = along(o.x, o.w, moving.w, moving.x)
    var candidates = [
      { x: o.x + o.w, y: y },
      { x: o.x - moving.w, y: y },
      { x: x, y: o.y + o.h },
      { x: x, y: o.y - moving.h }
    ]
    var across = (o.w + moving.w) / 2
    var upDown = (o.h + moving.h) / 2

    for (var j = 0; j < candidates.length; j++) {
      var c = { x: Math.round(candidates[j].x), y: Math.round(candidates[j].y), w: moving.w, h: moving.h }
      var free = true
      for (var k = 0; k < others.length; k++) {
        if (overlaps(c, others[k])) free = false
      }
      var distance = Math.hypot((c.x - moving.x) / across, (c.y - moving.y) / upDown)
      if (free && (best === null || distance < best.distance)) best = { x: c.x, y: c.y, distance: distance }
    }
  }
  return best ? { x: best.x, y: best.y } : { x: moving.x, y: moving.y }
}

// What to call a display: the built-in panel, or the model its EDID
// reports, with the connector as the last resort.
function displayLabel(display) {
  if (!display) return ""
  if (/^(eDP|LVDS|DSI)-/.test(display.name)) return "Built-in display"
  return display.model || display.name
}

// The displays as the panel lists them: those that are on in display order
// (`order` holds their names, display 1 first), then those that are off. Each gets
// its number, 0 while off.
function numberedDisplays(displays, order) {
  var result = displays.map(function(display) {
    var copy = Object.assign({}, display)
    copy.number = order.indexOf(display.name) + 1
    return copy
  })
  return result.sort(function(a, b) { return (a.number || 1000) - (b.number || 1000) })
}

// The command that switches display `name` off, when enabled, or back on.
// The internal panel goes through omarchy-hyprland-monitor-internal, which
// persists the choice and which clamshell respects. An external goes through
// the display module when it's managing displays (managed), which keeps it
// off through later rule changes and brings it back where it was; otherwise
// it gets a complete rule through hyprctl eval, as the Lua config refuses
// `hyprctl keyword`. The name is written into Lua, so only a plain connector
// passes.
function displayToggleCommand(name, enabled, managed) {
  if (!/^[A-Za-z0-9._-]+$/.test(String(name || ""))) return null
  if (/^(eDP|LVDS|DSI)-/.test(name)) return ["omarchy-hyprland-monitor-internal", enabled ? "off" : "on"]
  if (managed) return ["hyprctl", "eval", "omarchy_displays.set_enabled(\"" + name + "\", " + !enabled + ")"]

  var rule = enabled
    ? '{ output = "' + name + '", disabled = true }'
    : '{ output = "' + name + '", mode = "preferred", position = "auto", scale = "auto", disabled = false }'
  return ["hyprctl", "eval", "hl.monitor(" + rule + ")"]
}

// The rotations the panel offers, as Hyprland counts transforms.
function rotationOptions() {
  return [
    { transform: 0, label: "Standard" },
    { transform: 1, label: "90°" },
    { transform: 2, label: "180°" },
    { transform: 3, label: "270°" }
  ]
}

// What to call a display's transform. The flipped ones (4-7) only come from
// a rule of the user's.
function rotationLabel(transform) {
  var t = Math.max(0, Math.min(7, Math.floor(Number(transform) || 0)))
  var turn = rotationOptions()[t % 4].label
  if (t < 4) return turn
  return t === 4 ? "Flipped" : "Flipped " + turn
}

// The command that turns display `name` to `transform` through the display
// module. The name is written into Lua, so only a plain connector passes.
function rotationCommand(name, transform) {
  if (!/^[A-Za-z0-9._-]+$/.test(String(name || ""))) return null
  var t = Number(transform)
  if (t !== 0 && t !== 1 && t !== 2 && t !== 3) return null
  return ["hyprctl", "eval", "omarchy_displays.set_rotation(\"" + name + "\", " + t + ")"]
}

if (typeof module !== "undefined") {
  module.exports = {
    clampBrightness: clampBrightness,
    normalizeScale: normalizeScale,
    cleanScale: cleanScale,
    matchingScaleIndex: matchingScaleIndex,
    closestScaleIndex: closestScaleIndex,
    availableScales: availableScales,
    brightnessName: brightnessName,
    parseDisplays: parseDisplays,
    snapPosition: snapPosition,
    numberedDisplays: numberedDisplays,
    displayToggleCommand: displayToggleCommand,
    displayLabel: displayLabel,
    rotationOptions: rotationOptions,
    rotationLabel: rotationLabel,
    rotationCommand: rotationCommand
  }
}
