#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

run_lua() {
  local home="$1"
  mkdir -p "$home/.local/state/omarchy/toggles/hypr"
  HOME="$home" XDG_STATE_HOME="$home/.local/state" XDG_RUNTIME_DIR="$home" OMARCHY_PATH="$ROOT" lua -
}

model_output=$(run_lua "$tmpdir/model" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local model = require("default.hypr.displays.model")

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

local benq = "BNQ BenQ LCD T4M01236019"

-- Identity: EDID description first, connector only as the tie-breaker.
local monitors = model.identify({
  { name = "eDP-1", description = "", serial = "" },
  { name = "USB-2", description = benq, serial = "T4M01236019" },
  { name = "DP-1", description = "Dell U2720Q", serial = "0" },
})
eq(monitors[1].key, "eDP-1", "internal panel key")
eq(monitors[1].selector, "eDP-1", "internal panel selector")
eq(monitors[2].key, "desc:" .. benq, "external key")
eq(monitors[2].selector, "desc:" .. benq, "external selector")
eq(monitors[3].key, "desc:Dell U2720Q@DP-1", "zero serial joins the connector")
eq(monitors[3].selector, "DP-1", "zero serial is selected by connector")

eq(model.identify({ { name = "eDP-1", description = "BOE 0x0BCA", serial = "" } })[1].key, "eDP-1", "an internal panel with an EDID still goes by connector")

local twins = model.identify({
  { name = "USB-1", description = "LG 27UL850 ABC", serial = "ABC" },
  { name = "USB-2", description = "LG 27UL850 ABC", serial = "ABC" },
})
eq(twins[1].key, "desc:LG 27UL850 ABC@USB-1", "first twin key")
eq(twins[2].selector, "USB-2", "twins are selected by connector")
eq(model.safe_when_absent("USB-2"), false, "connector rules are unsafe while absent")
eq(model.safe_when_absent("eDP-1"), true, "the internal connector is safe while absent")
eq(model.is_virtual("FALLBACK") and model.is_virtual("HEADLESS-2"), true, "synthetic outputs")

-- Geometry and scale.
local w, h = model.logical_size(2560, 1440, 1.6, 0)
eq(w .. "x" .. h, "1600x900", "logical size")
w, h = model.logical_size(2560, 1440, 1.6, 1)
eq(w .. "x" .. h, "900x1600", "rotated logical size")
eq(model.snap_scale(1.6000000238418579), 1.6, "float32 scale snaps to k/120")
eq(model.clean_scale(1.25, 3456, 2160), 160 / 120, "1.25 is not clean on 3456x2160")
eq(model.step_scale(2, 1, 3456, 2160), 3, "step up on the MacBook panel")
eq(model.step_scale(1.6, -1, 2560, 1440), 1.25, "step down on a 1440p display")
eq(model.step_scale(4, 1, 2560, 1440), 4, "step up stops at the top")

-- Scale by real size, from EDID sizes (Oliver's MacBook and BenQ).
local panel = { key = "eDP-1", width = 3456, height = 2160, physical = 346, scale = 3 }
local desk_benq = { key = "desc:" .. benq, width = 2560, height = 1440, physical = 600, scale = 1 }
eq(model.derived_scale(desk_benq, panel), 1.25, "next to the panel at 3, the BenQ shows things as many millimetres tall at 1.25")
desk_benq.scale = 1.25
eq(model.derived_scale(panel, desk_benq), 3, "and the match is the same the other way round")
eq(model.derived_scale({ key = "x", width = 1920, height = 1080, physical = 0 }, panel), nil, "no EDID size, no derived scale")
eq(model.nearest_clean(1.49, 2560, 1440), 1.6, "nearest clean scale in either direction")
eq(model.step_scale(2.4, 1, 3456, 2160), 3, "a step up from a derived scale goes to the next preset")
eq(model.step_scale(2.4, -1, 3456, 2160), 2, "and a step down to the one below")
eq(model.derived_scale({ key = "tv", width = 1920, height = 1080, physical = 16 }, panel), nil, "an impossible EDID size counts as unknown")

-- Main and numbering.
local desk = {
  ["desc:" .. benq] = { x = 0, y = 0, w = 1600, h = 900 },
  ["eDP-1"] = { x = 1600, y = 180, w = 1152, h = 720 },
}
eq(model.main(desk), "eDP-1", "the internal panel is main")
eq(model.numbering(desk)[1], "desc:" .. benq, "display 1 is the left display")
eq(model.main({ a = { x = 5, y = 0 }, b = { x = -3, y = 0 } }), "b", "without the panel, the leftmost is main")

-- A display seen for the first time: right of main, bottoms flush.
local x, y = model.place_new({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, 1600, 900)
eq(x .. "," .. y, "1152,-180", "new display right of main, bottom-aligned")
x, y = model.place_new(desk, 1920, 1080)
eq(x .. "," .. y, "2752,-180", "new display right of main on the desk")
x, y = model.place_new({
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 },
  other = { x = 1152, y = 0, w = 1000, h = 720 },
}, 800, 600)
eq(x .. "," .. y, "2152,120", "new display goes past whatever is right of main")

-- Joining: the remembered layout, shifted so what's on stays put.
local layouts = { { positions = { ["eDP-1"] = { 1600, 180 }, ["desc:" .. benq] = { 0, 0 } } } }
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "-1600,-180", "replug lands at the remembered spot relative to main")
x, y = model.place_joining({}, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "0,0", "with nothing on, the stored position is used as is")
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "unknown", 800, 600, layouts)
eq(x .. "," .. y, "1152,120", "an unknown display gets the default spot")
local blocked = {
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 },
  third = { x = -1600, y = -180, w = 1600, h = 900 },
}
x, y = model.place_joining(blocked, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "1152,-180", "a remembered spot that is taken falls back to the default")
local mru = {
  { positions = { ["eDP-1"] = { 0, 0 }, a = { 1152, 0 } } },
  { positions = { ["eDP-1"] = { 0, 0 }, a = { -500, 0 } } },
}
x = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "a", 500, 500, mru)
eq(x, 1152, "the most recently used layout wins")
local dock = {
  { positions = { ["eDP-1"] = { 0, 0 }, a = { 1152, 0 }, b = { 2752, 0 } } },
  { positions = { ["eDP-1"] = { 0, 0 }, a = { -500, 0 } } },
}
x = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "a", 500, 500, dock)
eq(x, -500, "a layout for exactly this set beats a more recent larger one")
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "b", 1600, 900, dock)
eq(x .. "," .. y, "1152,-180", "a remembered spot that touches nothing is skipped")

-- Restore: an arranged set comes back as arranged, around the anchor.
local restored = model.restore({
  ["eDP-1"] = { x = 5000, y = 0, w = 1152, h = 720 },
  a = { x = 0, y = 0, w = 500, h = 500 },
}, "eDP-1", mru)
eq(restored.a.x, 6152, "restore shifts the stored arrangement onto the anchor")
eq(model.restore({ ["eDP-1"] = { x = 0, y = 0, w = 1, h = 1 } }, "eDP-1", mru), nil, "no stored arrangement for this set")

-- Back at another size, a display keeps the side and alignment it was stored
-- with: the BenQ was left of the panel at 1600x900, bottoms flush, and now
-- comes back at 2048x1152.
local sized = { { positions = { ["eDP-1"] = { 0, 0, 1152, 720 }, ["desc:" .. benq] = { -1600, -180, 1600, 900 } } } }
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "desc:" .. benq, 2048, 1152, sized)
eq(x .. "," .. y, "-2048,-432", "a display joining at another size keeps its side, bottoms flush")
restored = model.restore({
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 },
  ["desc:" .. benq] = { x = 9000, y = 9000, w = 2048, h = 1152 },
}, "eDP-1", sized)
eq(restored["desc:" .. benq].x .. "," .. restored["desc:" .. benq].y, "-2048,-432", "and so does an arrangement restored at other sizes")
eq(table.concat(model.remember({}, restored, 16)[1].positions["desc:" .. benq], ","), "-2048,-432,2048,1152", "a remembered spot keeps the display's size")

-- Connect: the arrangement stays in one piece.
local gap = model.connect({
  ["desc:" .. benq] = { x = -1600, y = -180, w = 1600, h = 900 },
  dell = { x = 1152, y = 0, w = 1920, h = 1080 },
}, {})
eq(gap.dell.x .. "," .. gap.dell.y, "0,-360", "a display left detached is seated beside main")
eq(gap["desc:" .. benq].x, -1600, "main stays where it is")

-- Reflow: main keeps its spot, neighbours keep side and alignment.
local new = model.reflow(desk, { ["eDP-1"] = { w = 864, h = 540 } })
eq(new["eDP-1"].x .. "," .. new["eDP-1"].y, "1600,180", "resized main keeps its position")
eq(new["desc:" .. benq].x .. "," .. new["desc:" .. benq].y, "0,-180", "neighbour stays left with bottoms flush")
new = model.reflow(desk, { ["desc:" .. benq] = { w = 2560, h = 1440 } })
eq(new["desc:" .. benq].x .. "," .. new["desc:" .. benq].y, "-960,-540", "resized neighbour re-seats against main")
local stacked = {
  ["eDP-1"] = { x = 0, y = 900, w = 1152, h = 720 },
  top = { x = -224, y = 0, w = 1600, h = 900 },
}
new = model.reflow(stacked, { top = { w = 2560, h = 1440 } })
eq(new.top.x .. "," .. new.top.y, "-704,-540", "a display above stays centred")
local drifted = {
  ["eDP-1"] = { x = 0, y = 900, w = 1152, h = 720 },
  top = { x = -225, y = 0, w = 1600, h = 900 },
}
new = model.reflow(drifted, {})
eq(new.top.x, -225, "an off-centre display keeps its exact offset")
local offset = {
  ["eDP-1"] = { x = 0, y = 900, w = 1728, h = 1080 },
  top = { x = 1500, y = 0, w = 2560, h = 900 },
}
new = model.reflow(offset, { ["eDP-1"] = { w = 1152, h = 720 } })
eq(new.top.x .. "," .. new.top.y, "1151,0", "an offset display still touches after main shrinks")
local tangled = {
  a = { x = 0, y = 0, w = 100, h = 100 },
  b = { x = 100, y = 0, w = 100, h = 50 },
  c = { x = 100, y = 50, w = 100, h = 50 },
}
new = model.reflow(tangled, { b = { w = 100, h = 100 } })
for key, rect in pairs(new) do
  assert(model.fits(new, rect, key), "reflow leaves every display touching and none overlapping: " .. key)
end
eq(new.a.x .. "," .. new.a.y, "0,0", "repair keeps main")

-- Remember: most recent first, one entry per set, bounded.
local remembered = model.remember({
  { positions = { a = { 0, 0 } } },
  { positions = { a = { 0, 0 }, b = { 1, 0 } } },
}, { a = { x = 5, y = 5 } }, 16)
eq(#remembered, 2, "same set replaces its entry")
eq(remembered[1].positions.a[1], 5, "newest first")
eq(#model.remember(remembered, { c = { x = 0, y = 0 } }, 2), 2, "bounded")

-- Plan: complete set, desc rules first, unsafe absent rules left out.
local present = {
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720, selector = "eDP-1", scale = 3, transform = 0 },
}
local known = {
  ["desc:" .. benq] = { selector = "desc:" .. benq, size = { 2560, 1440 }, scale = 1.6, transform = 0 },
  ["desc:LG@USB-1"] = { selector = "USB-1", size = { 3840, 2160 }, scale = 2, transform = 0 },
}
local rules = model.plan(present, known, layouts)
eq(#rules, 2, "absent connector-selected display gets no rule")
eq(rules[1].selector, "desc:" .. benq, "desc rules come first")
eq(rules[1].x .. "," .. rules[1].y, "-1600,-180", "absent display rule is precomputed")
eq(rules[2].selector, "eDP-1", "connector rules come last")
print("model ok")
LUA
) || fail "display model" "$model_output"
pass "display model: identity, scale, placement, restore, connect, reflow, remember, plan"

store_output=$(run_lua "$tmpdir/store" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local store = require("default.hypr.displays.store")

local state = {
  version = 1,
  displays = {
    ['desc:Odd "Name" \\ 1'] = { selector = 'desc:Odd "Name" \\ 1', size = { 2560, 1440 }, scale = 1.6, transform = 0, description = "Ünïcode\tTab" },
  },
  layouts = { { positions = { ["eDP-1"] = { 1600, 180 }, ['desc:Odd "Name" \\ 1'] = { -1600, -180 } } } },
}

local decoded = store.decode(store.encode(state))
assert(decoded, "encoded state decodes")
local display = decoded.displays['desc:Odd "Name" \\ 1']
assert(display and display.scale == 1.6 and display.size[2] == 1440, "display record round-trips")
assert(display.description == "Ünïcode\tTab", "strings round-trip")
assert(decoded.layouts[1].positions["eDP-1"][2] == 180, "positions round-trip")
assert(store.decode("{ broken") == nil, "malformed JSON is rejected")
assert(store.decode('{"a": 1} trailing') == nil, "trailing garbage is rejected")

local clean = store.sanitize({
  version = 1,
  displays = {
    ["desc:ok"] = { selector = "eDP-1", size = { 1, 1 }, scale = 2.0000001 },
    ["desc:bad"] = { selector = 3 },
    ["desc:tiny"] = { selector = "a", size = { 10, 10 }, scale = 0.004 },
    ["desc:turned"] = { selector = "b", size = { 10, 10 }, scale = 1, transform = 9 },
    ["desc:fractional"] = { selector = "c", size = { 10.5, 10 }, scale = 1 },
  },
  layouts = { { positions = { ["desc:a"] = { 0, 0 } } }, { positions = { ["desc:a"] = "x" } }, {}, { positions = { ["desc:a"] = { 0.5, 0 } } } },
})
assert(clean.displays["desc:ok"] and not clean.displays["desc:bad"], "invalid display records are dropped")
assert(not clean.displays["desc:tiny"] and not clean.displays["desc:turned"] and not clean.displays["desc:fractional"], "out-of-range values are dropped")
local blocks = store.sanitize({
  version = 1,
  displays = {
    a = { selector = "a", size = { 1, 1 }, scale = 1, block = 1 },
    b = { selector = "b", size = { 1, 1 }, scale = 1, block = 1 },
    c = { selector = "c", size = { 1, 1 }, scale = 1, block = 9999 },
  },
}).displays
assert(blocks.a == nil, "a display known only by a non-internal connector is not remembered")
local named = store.sanitize({
  version = 1,
  displays = {
    ["desc:A"] = { selector = "desc:A", size = { 1, 1 }, scale = 1, block = 1 },
    ["desc:B"] = { selector = "desc:B", size = { 1, 1 }, scale = 1, block = 1 },
    ["desc:C"] = { selector = "desc:C", size = { 1, 1 }, scale = 1, block = 9999 },
    ["USB-1"] = { selector = "USB-1", size = { 1, 1 }, scale = 1, block = 2 },
  },
  layouts = { { positions = { ["eDP-1"] = { 0, 0 }, ["USB-1"] = { 5, 0 } } }, { positions = { ["USB-1"] = { 0, 0 } } } },
})
assert(named.displays["desc:A"].block == 1 and named.displays["desc:B"].block == nil and named.displays["desc:C"].block == nil, "duplicate or wild blocks are handed out again")
assert(named.displays["USB-1"] == nil, "an external without an EDID is not remembered as a new display")
assert(#named.layouts == 0, "and a layout holding it is dropped as a whole, not kept as a laptop-only one")
local bar = store.sanitize({ version = 1, connectors = { ["USB-2"] = 1, ["eDP-1"] = 0, ["DP-1"] = 100, [3] = 2, ["HDMI-A-1"] = "x" } }).connectors
assert(bar["USB-2"] == 1 and bar["eDP-1"] == 0 and bar["DP-1"] == nil and bar["HDMI-A-1"] == nil, "the bar's connector blocks are kept when valid")
local kept = store.sanitize(store.decode(store.encode({
  version = 1, factor = 1.07, main = "desc:X", scale_mode = "each",
  displays = { ["desc:X"] = { selector = "desc:X", size = { 1, 1 }, scale = 1 } },
})))
assert(kept.main == "desc:X" and kept.scale_mode == "each", "main and the scale mode are kept")
assert(kept.factor == nil, "a desk factor from an earlier version is dropped")
assert(store.sanitize({ version = 1, scale_mode = "auto" }).scale_mode == nil, "an unknown scale mode is linked")
assert(clean.displays["desc:ok"].scale == 2, "stored scales snap to k/120")
assert(#clean.layouts == 1, "invalid layouts are dropped")
assert(#store.sanitize({ version = 99 }).layouts == 0, "unknown versions start fresh")

local path = os.getenv("HOME") .. "/displays.json"
assert(#store.load(path).layouts == 0, "a missing file is an empty state")
assert(store.save(state, path) == true, "first save writes")
assert(store.save(state, path) == false, "an unchanged save is skipped")
local loaded = store.load(path)
assert(loaded.layouts[1].positions["eDP-1"][1] == 1600, "saved state loads back")
assert(io.open(path .. ".tmp", "r") == nil, "no temp file is left behind")

local file = io.open(path, "w")
file:write('{ "version": 1, "layouts": [ oops')
file:close()
assert(#store.load(path).layouts == 0, "a corrupt file loads as an empty state")
assert(io.open(path, "r") == nil and io.open(path .. ".bad", "r"), "a corrupt file is moved aside, not overwritten")
print("store ok")
LUA
) || fail "display store" "$store_output"
pass "display store: JSON round-trip, sanitizing, corrupt files kept, write only on change"

flow_output=$(run_lua "$tmpdir/flow" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
require("default.hypr.helpers")

-- A small Hyprland: rules upsert and merge per selector, the newest match
-- wins, a connecting output takes its rule without an overlap check, added
-- fires before the output is positioned, pending rules apply in one pass per
-- frame with one overlap check, and a changed scale or mode is a modeset.
local H

local function reset_hyprland()
  H = { outputs = {}, order = {}, rules = {}, windows = {}, workspace_rules = {}, dispatched = {}, submap = "", handlers = {}, timers = {}, notes = {}, pending = false, toasts = 0, moved = {}, modesets = {}, sent = 0, focused = nil }
end
reset_hyprland()

local function logical(o)
  local w, h = o.width, o.height
  if (o.transform or 0) % 2 == 1 then
    w, h = h, w
  end
  return math.floor(w / o.scale + 0.5), math.floor(h / o.scale + 0.5)
end

local function matches(selector, o)
  if selector == o.name then
    return true
  end
  return selector:sub(1, 5) == "desc:" and o.description ~= "" and o.description:sub(1, #selector - 5) == selector:sub(6)
end

local function rule_for(o)
  for i = #H.rules, 1, -1 do
    if matches(H.rules[i].output, o) then
      return H.rules[i]
    end
  end
end

local function windows_on(id)
  local count = 0
  for _, other in pairs(H.windows) do
    count = count + (other == id and 1 or 0)
  end
  return count
end

local function view(o)
  return { name = o.name, description = o.description, serial = o.serial, width = o.width, height = o.height, x = o.x, y = o.y, scale = o.scale, transform = o.transform or 0, physical_width = o.physical or 0, active_workspace = o.active and { id = o.active, windows = windows_on(o.active) } }
end

local function fire(event, ...)
  for _, fn in ipairs(H.handlers[event] or {}) do
    fn(...)
  end
end

local function apply_rule(o)
  local rule = rule_for(o)
  local was_on, old_x, old_y, old_scale, old_mode = o.enabled, o.x, o.y, o.scale, o.mode
  o.enabled = not (rule and rule.disabled)
  if not o.enabled then
    return was_on and "off" or nil
  end
  o.scale = rule and type(rule.scale) == "number" and rule.scale or o.auto_scale
  o.mode = rule and rule.mode or "preferred"
  if was_on and (old_scale ~= o.scale or old_mode ~= o.mode) then
    H.modesets[o.name] = (H.modesets[o.name] or 0) + 1
  end
  o.transform = rule and rule.transform or 0
  local x, y
  if rule and rule.position then
    x, y = rule.position:match("^(-?%d+)x(-?%d+)$")
  end
  if x then
    o.x, o.y = tonumber(x), tonumber(y)
  else
    o.x = nil
    local right = 0
    for _, name in ipairs(H.order) do
      local other = H.outputs[name]
      if other ~= o and other.enabled and other.x then
        right = math.max(right, other.x + logical(other))
      end
    end
    o.x, o.y = right, 0
  end
  if was_on and old_x and (old_x ~= o.x or old_y ~= o.y) then
    H.moved[o.name] = (H.moved[o.name] or 0) + 1
  end
  return not was_on and "on" or nil
end

local function check_overlaps()
  local on = {}
  for _, name in ipairs(H.order) do
    if H.outputs[name].enabled then
      on[#on + 1] = H.outputs[name]
    end
  end
  for i = 1, #on do
    for j = i + 1, #on do
      local a, b = on[i], on[j]
      local aw, ah = logical(a)
      local bw, bh = logical(b)
      if a.x < b.x + bw and b.x < a.x + aw and a.y < b.y + bh and b.y < a.y + ah then
        H.toasts = H.toasts + 1
        return
      end
    end
  end
end

local function frame()
  while H.pending do
    H.pending = false
    local changes = {}
    for _, name in ipairs(H.order) do
      changes[name] = apply_rule(H.outputs[name])
    end
    for _, name in ipairs(H.order) do
      if changes[name] == "off" then
        fire("monitor.removed", view(H.outputs[name]))
      elseif changes[name] == "on" then
        fire("monitor.added", view(H.outputs[name]))
      end
    end
    check_overlaps()
    fire("monitor.layout_changed")
  end
end

hl = {
  monitor = function(rule)
    local merged = {}
    for i, old in ipairs(H.rules) do
      if old.output == rule.output then
        merged = old
        table.remove(H.rules, i)
        break
      end
    end
    for key, value in pairs(rule) do
      merged[key] = value
    end
    H.rules[#H.rules + 1] = merged
    H.pending = true
    H.sent = H.sent + 1
  end,
  get_monitors = function()
    local list = {}
    for _, name in ipairs(H.order) do
      if H.outputs[name].enabled then
        list[#list + 1] = view(H.outputs[name])
      end
    end
    return list
  end,
  get_active_window = function()
    return H.window and { monitor = view(H.outputs[H.window]) }
  end,
  get_active_monitor = function()
    return H.outputs[H.focused] and view(H.outputs[H.focused])
  end,
  get_cursor_pos = function()
    return H.cursor
  end,
  on = function(event, fn)
    H.handlers[event] = H.handlers[event] or {}
    table.insert(H.handlers[event], fn)
  end,
  timer = function(fn)
    H.timers[#H.timers + 1] = fn
  end,
  exec_cmd = function(command)
    H.notes[#H.notes + 1] = command
  end,
  config = function(values)
    H.config = values
  end,
  env = function(name, value)
    H.env = H.env or {}
    H.env[name] = value
  end,
  workspace_rule = function(rule)
    H.workspace_rules[#H.workspace_rules + 1] = rule
  end,
  dispatch = function(action)
    H.dispatched[#H.dispatched + 1] = action
    if action.submap then
      H.submap = action.submap == "reset" and "" or action.submap
    end
    for _, o in pairs(action.change_id and H.outputs or {}) do
      if o.active == tonumber(action.change_id.workspace) then
        o.active = action.change_id.id
      end
    end
  end,
  get_current_submap = function()
    return H.submap
  end,
  get_windows = function()
    local list = {}
    for address, id in pairs(H.windows) do
      list[#list + 1] = { address = address, workspace = { id = id } }
    end
    return list
  end,
  dsp = {
    focus = function(args)
      return { focus = args }
    end,
    cursor = {
      move = function(args)
        H.cursor = { x = args.x, y = args.y }
        return { cursor = args }
      end,
    },
    submap = function(name)
      return { submap = name }
    end,
    window = {
      move = function(args)
        if args.window then
          H.windows[args.window:gsub("^address:", "")] = tonumber(args.workspace)
        end
        return { move = args }
      end,
    },
    workspace = {
      move = function(args)
        return { workspace_move = args }
      end,
      change_id = function(args)
        return { change_id = args }
      end,
    },
  },
}

-- A reload clears rules, handlers and timers, then runs the config again in
-- a fresh Lua state.
local function load_config(after)
  H.rules, H.workspace_rules, H.handlers, H.timers, H.config = {}, {}, {}, {}, nil
  omarchy_displays = nil
  for _, module in ipairs({ "default.hypr.displays", "default.hypr.displays.model", "default.hypr.displays.store" }) do
    package.loaded[module] = nil
  end
  local register_rule, set_env = hl.monitor, hl.env
  require("default.hypr.displays")
  if after then
    after()
  end
  fire("config.reloaded")
  H.pending = true
  frame()
  hl.monitor, hl.env = register_rule, set_env
end

local function connect(name, description, serial, width, height, auto_scale, physical)
  local o = { name = name, description = description, serial = serial, width = width, height = height, auto_scale = auto_scale or 1, physical = physical, active = H.first_free }
  H.first_free = nil
  H.outputs[name] = o
  H.order[#H.order + 1] = name
  apply_rule(o)
  if o.enabled then
    local payload = view(o)
    payload.x, payload.y = -1, -1
    fire("monitor.added", payload)
    fire("monitor.layout_changed")
  end
  frame()
end

local function disconnect(name)
  local o = H.outputs[name]
  H.outputs[name] = nil
  for i, other in ipairs(H.order) do
    if other == name then
      table.remove(H.order, i)
      break
    end
  end
  if o.enabled then
    fire("monitor.removed", view(o))
  end
  check_overlaps()
  fire("monitor.layout_changed")
  frame()
end

-- Pending rules apply at the next frame, long before any timer fires.
local function settle()
  frame()
  while #H.timers > 0 do
    local timers = H.timers
    H.timers = {}
    for _, fn in ipairs(timers) do
      fn()
    end
    frame()
  end
end

local function pos(name)
  local o = H.outputs[name]
  return o.x .. "," .. o.y
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

local function moves(name)
  return H.moved[name] or 0
end

local function modesets(name)
  return H.modesets[name] or 0
end

local store = require("default.hypr.displays.store")

local benq = "BNQ BenQ LCD T4M01236019"
local toggles = os.getenv("HOME") .. "/.local/state/omarchy/toggles/hypr/"

-- First start with an empty store, laptop alone.
load_config()
eq(H.config.gestures.workspace_swipe_create_new, false, "the workspace swipe doesn't create workspaces outside a display's ten")
connect("eDP-1", "", "", 3456, 2160, 2)
settle()
eq(pos("eDP-1"), "0,0", "laptop alone starts at the origin")

-- A display seen for the first time: right of main, bottom-aligned. The
-- laptop doesn't move; the new display moves once, from Hyprland's auto spot.
H.focused = "eDP-1"
H.outputs["eDP-1"].active = 1
H.first_free = 2
connect("USB-1", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(pos("USB-1"), "1728,-360", "new display right of main, bottoms flush")
eq(H.outputs["USB-1"].active, 11, "a new display shows its own first workspace, not the laptop's 2")
for _, action in ipairs(H.dispatched) do
  assert(not action.focus, "and focus stays where it was")
end
eq(moves("eDP-1"), 0, "laptop stays put when a new display connects")
eq(H.toasts, 0, "no overlap toast for a new display")

-- Put it left of the laptop, the way the desk is.
assert(omarchy_displays.move("USB-1", -2560, -360), "moving it succeeds")
settle()
eq(pos("USB-1"), "-2560,-360", "placed left, bottoms flush")
eq(moves("eDP-1"), 0, "placing one display leaves the others")

-- Unplug, then replug into another port: zero moves, no second pass.
disconnect("USB-1")
settle()
eq(pos("eDP-1"), "0,0", "laptop keeps its place after unplug")
H.moved = {}
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
eq(pos("USB-2"), "-2560,-360", "replug on another port lands at the remembered spot at once")
settle()
eq(moves("USB-2") + moves("eDP-1"), 0, "replug moves nothing")
eq(H.toasts, 0, "replug raises no overlap toast")

-- SUPER+/ on the laptop: the BenQ keeps its size and so its spot, and the
-- laptop, modeset anyway, moves to stay beside it with bottoms flush.
H.moved = {}
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["eDP-1"].scale, 3, "laptop steps up to 3")
eq(pos("USB-2"), "-2560,-360", "the display that keeps its size keeps its position")
eq(moves("USB-2"), 0, "and doesn't move at all")
eq(pos("eDP-1"), "0,360", "the rescaled laptop stays right of it with bottoms flush")
eq(H.toasts, 0, "scale step raises no overlap toast")
-- Arranged for what follows: the laptop at the origin, bottoms flush.
assert(omarchy_displays.move("eDP-1", 0, 0), "main can be dragged too")
assert(omarchy_displays.move("USB-2", -2560, -720), "and the BenQ beside it")
settle()
eq(pos("eDP-1") .. " " .. pos("USB-2"), "0,0 -2560,-720", "arranged by hand")

-- The pointer keeps its spot on its display. Over the BenQ while the laptop
-- steps down, nothing under it moves; over the laptop while it steps up, it's
-- put back on the same spot of the laptop once the rules have landed; and on
-- a display dragged in the panel, it goes along.
local function cursor()
  return H.cursor.x .. "," .. H.cursor.y
end
H.cursor, H.moved, H.focused = { x = -1280, y = 0 }, {}, "eDP-1"
omarchy_displays.step_scale(-1)
settle()
eq(pos("eDP-1"), "0,-360", "the laptop at 2 stays right of the BenQ, bottoms flush")
eq(moves("USB-2"), 0, "the BenQ under the pointer doesn't move while the laptop rescales")
eq(cursor(), "-1280,0", "and the pointer on it isn't moved")
H.cursor = { x = 1296, y = 180 }
omarchy_displays.step_scale(1)
settle()
eq(pos("eDP-1"), "0,0", "the laptop at 3 again")
eq(cursor(), "864,360", "the pointer is still three quarters across and halfway down the laptop")
H.cursor = { x = -1280, y = 0 }
assert(omarchy_displays.move("USB-2", -2560, -360), "the BenQ is dragged down")
settle()
eq(cursor(), "-1280,360", "and the pointer on it goes along")
assert(omarchy_displays.move("USB-2", -2560, -720), "and back up")
settle()
H.cursor = nil

-- A tool outside the module rescales with a connector rule and position=auto
-- (what the scaling script did before it delegated). The new scale is
-- adopted and the display re-seated.
settle()
hl.monitor({ output = "USB-2", mode = "2560x1440@60", position = "auto", scale = 1.6 })
frame()
settle()
eq(H.outputs["USB-2"].scale, 1.6, "outside scale change is kept")
eq(pos("USB-2"), "-1600,-180", "outside scale change is re-seated left of main")

-- Someone arranges with hyprctl: adopted as this set's layout.
hl.monitor({ output = "USB-2", position = "-1600x0" })
frame()
settle()
eq(pos("USB-2"), "-1600,0", "outside move is kept")
eq(store.load().layouts[1].positions["desc:" .. benq][2], 0, "outside move is remembered")

-- A reload changes nothing.
H.moved = {}
load_config()
settle()
eq(moves("USB-2") + moves("eDP-1"), 0, "reload moves nothing")

-- Next boot, docked: the rules from the store put both displays in place in
-- their first modeset.
reset_hyprland()
load_config()
connect("eDP-1", "", "", 3456, 2160, 2)
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(pos("eDP-1"), "0,0", "boot: laptop at its remembered spot")
eq(pos("USB-2"), "-1600,0", "boot: BenQ at its remembered spot")
eq(H.outputs["USB-2"].scale, 1.6, "boot: BenQ at its remembered scale")
eq(moves("eDP-1") + moves("USB-2"), 0, "boot moves nothing")

-- Boot docked with the lid closed: the clamshell toggle disables the panel
-- after this module; no runtime rule may switch it back on.
local flag = io.open(toggles .. "internal-monitor-clamshell.lua", "w")
flag:write('hl.monitor({ output = "eDP-1", disabled = true })\n')
flag:close()
load_config(function()
  hl.monitor({ output = "eDP-1", disabled = true })
end)
settle()
eq(H.outputs["eDP-1"].enabled, false, "clamshell keeps the panel off")
H.focused = "USB-2"
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["eDP-1"].enabled, false, "a later change doesn't switch the closed panel back on")
omarchy_displays.step_scale(-1)
settle()
os.remove(toggles .. "internal-monitor-clamshell.lua")

-- Lid opens: the clamshell toggle is gone and the config reloads. The panel
-- comes back beside the BenQ without the BenQ moving.
H.moved = {}
load_config()
settle()
eq(H.outputs["eDP-1"].enabled, true, "panel back on")
eq(pos("eDP-1"), "0,0", "panel returns to its remembered spot beside the BenQ")
eq(moves("USB-2"), 0, "the BenQ stays put when the panel returns")

-- Synthetic outputs are ignored.
connect("FALLBACK", "", "", 1920, 1080, 1)
assert(not omarchy_displays.status():find("FALLBACK"), "FALLBACK is ignored")
disconnect("FALLBACK")

-- Mirroring: nothing is registered while the mirror toggle exists, and the
-- scripts fall back to their own behaviour.
flag = io.open(toggles .. "internal-monitor-mirror.lua", "w")
flag:write("-- mirror\n")
flag:close()
load_config()
local mirror_module = require("default.hypr.displays")
eq(omarchy_displays, nil, "the API is not offered while mirroring")
local sent = H.sent
mirror_module.step_scale(1)
mirror_module.move("USB-2", 0, 0)
eq(H.sent, sent, "no rules while mirroring")
os.remove(toggles .. "internal-monitor-mirror.lua")
load_config()
settle()
eq(H.outputs["eDP-1"].scale, 3, "after mirroring the laptop is back at its remembered scale")
eq(pos("USB-2"), "-1600,0", "after mirroring the BenQ is back at its remembered spot")

-- A display without a usable serial is selected by connector. When it
-- leaves, its rule is reset, so the next monitor on that port starts clean.
connect("USB-3", "SAM TV", "0", 1920, 1080, 1)
settle()
H.focused = "USB-3"
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["USB-3"].scale, 1.25, "the TV steps up")
disconnect("USB-3")
settle()
connect("USB-3", "GSM LG XYZ", "XYZ", 1920, 1080, 1)
settle()
eq(H.outputs["USB-3"].scale, 1, "a new display on that port doesn't inherit the old connector rule")
eq(store.load().displays["desc:SAM TV@USB-3"].connector, nil, "only the display last seen on a connector keeps it")
disconnect("USB-3")
settle()

-- Three displays: BenQ | laptop | Dell. When the middle one goes away the
-- others close up, and when it returns the arranged set comes back.
connect("USB-4", "DEL U2723QE ABC", "ABC", 3840, 2160, 2)
settle()
eq(pos("USB-4"), "1152,-360", "Dell goes right of main")
assert(omarchy_displays.move("USB-4", 1152, -360), "arrange the three")
settle()
H.moved = {}
disconnect("eDP-1")
settle()
eq(pos("USB-2"), "-1600,0", "the BenQ stays when the middle display goes")
eq(pos("USB-4"), "0,-180", "the Dell closes up beside the BenQ")
connect("eDP-1", "", "", 3456, 2160, 2)
settle()
eq(pos("USB-2"), "-1600,0", "the BenQ stays when the middle display returns")
eq(pos("eDP-1"), "0,0", "the laptop returns to the middle")
eq(pos("USB-4"), "1152,-360", "the Dell returns to the right")
eq(H.toasts, 0, "no overlap toast through all of it")

-- The Monitor panel hands its scale to the module: the same scale again
-- changes nothing, a new one keeps the display in place.
sent = H.sent
omarchy_displays.set_scale("USB-4", 2)
eq(H.sent, sent, "setting the current scale sends nothing")
H.modesets = {}
omarchy_displays.set_scale("USB-4", 1.6)
settle()
eq(pos("USB-4"), "1152,-630", "the Dell keeps its side and bottom edge at 1.6")
eq(modesets("USB-4"), 1, "one modeset for the rescaled display")
eq(modesets("eDP-1") + modesets("USB-2"), 0, "no modeset for the others")

-- Workspaces: each display owns ten ids, the laptop 1-10, then in the order
-- displays were first seen. They're pinned to the display's identity, not
-- persistent, and every display known to the store is pinned at load, even
-- one that isn't connected.
local function rules_for(workspace)
  local found = {}
  for _, rule in ipairs(H.workspace_rules) do
    if rule.workspace == workspace then
      found[#found + 1] = rule
    end
  end
  return found
end

load_config()
settle()
eq(#rules_for("1"), 1, "the laptop's first slot is pinned once")
eq(rules_for("1")[1].monitor, "eDP-1", "the laptop's slots are pinned to the panel")
eq(rules_for("1")[1].default, true, "slot 1 is the display's default workspace")
eq(rules_for("5")[1].persistent, nil, "empty workspaces go away, as before")
eq(rules_for("11")[1].monitor, "desc:" .. benq, "the BenQ's slots are pinned by identity, on any port")
eq(#rules_for("21"), 0, "the TV, selected by connector, has a block but no pinned slots")
eq(rules_for("41")[1].monitor, "desc:DEL U2723QE ABC", "the Dell got the next free block after the TV and the LG")
for _, rule in ipairs(H.workspace_rules) do
  assert(rule.monitor ~= "USB-3", "a display selected by connector is not pinned")
end
local pinned = #H.workspace_rules
omarchy_displays.move("USB-4", 1152, -360)
settle()
eq(#H.workspace_rules, pinned, "a later change doesn't pin anything again")

H.focused = "USB-2"
eq(omarchy_displays.slot(3), "13", "SUPER+3 on the BenQ is its third slot")
H.focused = "eDP-1"
eq(omarchy_displays.slot(10), "10", "SUPER+0 on the laptop is workspace 10, as before")
H.window = "USB-2"
eq(omarchy_displays.slot(1, true), "11", "SUPER+SHIFT+1 uses the display the window is on, not the one under the pointer")
H.window = nil
H.dispatched = {}

-- SUPER+D, then a number: display 1 is the leftmost.
omarchy_displays.choose_display()
eq(H.submap, "display", "SUPER+D enters the display submap")
omarchy_displays.send_window(1)
eq(H.dispatched[#H.dispatched].move.monitor, "USB-2", "display 1 is the BenQ on the left")
eq(H.submap, "", "sending leaves the submap")
H.submap = "display"
settle()
eq(H.submap, "", "the submap is left after 1.5 s")
omarchy_displays.choose_display()
local timers = H.timers
H.timers = {}
omarchy_displays.choose_display()
timers[1]()
eq(H.submap, "display", "an earlier timer doesn't cut a new SUPER+D short")
settle()

-- Windows of a display that's gone come over to main's active workspace
-- and go home when it's back; a window moved meanwhile stays where it is.
-- The other displays' windows stay put.
H.outputs["eDP-1"].active = 2
H.windows = { lap = 1, a = 11, b = 13, dell = 41 }
disconnect("USB-2")
settle()
eq(H.windows.a .. " " .. H.windows.b, "2 2", "the BenQ's windows come over to the laptop's active workspace")
eq(H.windows.lap .. " " .. H.windows.dell, "1 41", "the other displays' windows stay put")
H.windows.b = 3
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(H.windows.a, 11, "back on the BenQ when it returns")
eq(H.windows.b, 3, "a window moved meanwhile stays where it was put")

-- A display that comes back on without a mode yet (0x0) is not gone: its
-- windows stay home.
H.windows = { a = 11 }
H.outputs["USB-2"].width, H.outputs["USB-2"].height = 0, 0
fire("monitor.layout_changed")
eq(H.windows.a, 11, "a display still coming up keeps its windows")
H.outputs["USB-2"].width, H.outputs["USB-2"].height = 2560, 1440
fire("monitor.layout_changed")
settle()

-- An external that comes back without an EDID, on the connector it was last
-- seen on, is still recognised: same place, same workspaces.
H.windows = { a = 11 }
disconnect("USB-2")
settle()
H.dispatched = {}
connect("USB-2", "", "", 1024, 768, 1)
settle()
eq(H.windows.a, 11, "the BenQ without its EDID gets its windows back")
local moved_home
for _, action in ipairs(H.dispatched) do
  moved_home = moved_home or (action.workspace_move and action.workspace_move.workspace == "11" and action.workspace_move.monitor == "USB-2")
end
assert(moved_home, "and its workspace, which no rule pins to it by connector")
assert(omarchy_displays.status():find("desc:" .. benq, 1, true), "and is known as the BenQ")
eq(store.load().displays["desc:" .. benq].size[1], 2560, "its fallback mode doesn't replace the BenQ's own")
eq(store.load().connectors["USB-2"], 1, "the bar finds its block by connector")
disconnect("USB-2")
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(H.outputs["USB-2"].scale, 1.6, "with its EDID back, the BenQ keeps its scale")
H.windows = {}

-- Scale: a display seen for the first time shows things the same real size
-- as main. Linked, a change on any display takes the others to the same real
-- size, and it doesn't matter which one is changed. Per display, each keeps
-- its own scale. The mode is remembered until it's changed; SUPER+CTRL+/
-- matches everything to main.
H.outputs["eDP-1"].physical = 346
connect("USB-7", "SAM Odyssey G7 H4ZR", "H4ZR", 2560, 1440, 1, 597)
settle()
eq(H.outputs["USB-7"].scale, 1.25, "a new 27-inch 1440p shows things the size they are on the panel at 3")
eq(omarchy_displays.scale_mode(), "linked", "scaling is linked until Per display is chosen")
H.focused = "eDP-1"
omarchy_displays.step_scale(-1)
settle()
eq(H.outputs["eDP-1"].scale, 2, "the panel steps down to 2")
eq(H.outputs["USB-7"].scale, 100 / 120, "the Odyssey follows it down, to 0.83")
H.focused = "USB-7"
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["USB-7"].scale, 1, "SUPER+/ on the Odyssey takes it to 1")
eq(H.outputs["eDP-1"].scale, 2.4, "linked, the panel follows it to the same real size (2.4, the nearest clean scale)")
omarchy_displays.set_scale("eDP-1", 2.4)
settle()
eq(H.outputs["USB-7"].scale, 1, "setting the panel to that brings the same pair: it doesn't matter which display is set")
omarchy_displays.set_scale("eDP-1", 2)
settle()
eq(H.outputs["USB-7"].scale, 100 / 120, "and back with the panel")
local sent = H.sent
local preview = store.decode(omarchy_displays.linked_preview())
eq(preview["USB-7"]["1.25"]["eDP-1"], 3, "the Monitor panel's preview has the panel at 3 for the Odyssey at 1.25")
eq(preview["USB-7"]["1.25"]["USB-7"], 1.25, "and the Odyssey itself at 1.25")
eq(preview["eDP-1"]["3"]["USB-7"], 1.25, "and the Odyssey at 1.25 for the panel at 3")
eq(H.sent, sent, "a preview sends no rules")
omarchy_displays.set_scale_mode("each")
eq(next(store.decode(omarchy_displays.linked_preview())), nil, "per display, nothing else changes, so there's nothing to preview")
omarchy_displays.set_scale("USB-7", 1.6)
settle()
eq(H.outputs["USB-7"].scale, 1.6, "per display, the Odyssey is set on its own")
eq(H.outputs["eDP-1"].scale, 2, "and the panel is left alone")
H.focused = "eDP-1"
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["eDP-1"].scale, 3, "the panel steps up to 3")
eq(H.outputs["USB-7"].scale, 1.6, "per display, the Odyssey keeps its scale when main changes")
load_config()
settle()
eq(omarchy_displays.scale_mode(), "each", "Per display is remembered")
eq(H.outputs["USB-7"].scale, 1.6, "and a reload keeps each display's own scale, not the 1.25 that matches main")
omarchy_displays.set_scale("USB-7", 2)
settle()
eq(H.outputs["eDP-1"].scale, 3, "per display, another display's scale leaves main alone")
eq(omarchy_displays.main_name(), "eDP-1", "main is the panel")
omarchy_displays.match_all()
settle()
eq(H.outputs["USB-7"].scale, 1.25, "match all takes the Odyssey to the same real size as main at 3")
eq(omarchy_displays.scale_mode(), "each", "matching everything to main keeps Per display")
omarchy_displays.set_scale_mode("linked")
eq(omarchy_displays.scale_mode(), "linked", "Linked is chosen again")
H.focused = "eDP-1"
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["USB-7"].scale, 200 / 120, "linked, the Odyssey follows the panel up to 4, at 1.67")
omarchy_displays.step_scale(-1)
settle()
eq(H.outputs["USB-7"].scale, 1.25, "and back down")
disconnect("USB-7")
settle()

-- The Monitor panel: dragging moves a display where it was dropped, and main
-- can be chosen.
eq(omarchy_displays.move("USB-2", 0, 0), false, "a drop onto another display is refused")
assert(omarchy_displays.move("USB-2", -1600, 0), "a free spot is taken")
settle()
eq(pos("USB-2"), "-1600,0", "the BenQ is where it was dropped")
eq(store.load().layouts[1].positions["desc:" .. benq][2], 0, "and that's remembered")
omarchy_displays.set_main("USB-2")
settle()
eq(store.load().main, "desc:" .. benq, "the chosen main is stored")
assert(omarchy_displays.status():find("USB%-2%) [^\n]* main"), "the BenQ is main now")
H.outputs["USB-2"].active = 11
H.windows = { lap = 3 }
disconnect("eDP-1")
settle()
eq(H.windows.lap, 11, "the laptop's windows come over to the chosen main")
connect("eDP-1", "", "", 3456, 2160, 2, 346)
settle()
omarchy_displays.set_main("eDP-1")
settle()
H.windows = {}

-- A display switched off in the Monitor panel stays off through later
-- changes and a reload, and comes back on at its remembered spot and scale.
omarchy_displays.set_enabled("USB-2", false)
settle()
eq(H.outputs["USB-2"].enabled, false, "the panel switches the BenQ off")
H.focused = "eDP-1"
omarchy_displays.step_scale(1)
settle()
omarchy_displays.set_main("eDP-1")
settle()
eq(H.outputs["USB-2"].enabled, false, "a scale step elsewhere doesn't switch it back on")
load_config()
settle()
eq(H.outputs["USB-2"].enabled, false, "nor does a reload")
omarchy_displays.step_scale(-1)
settle()
omarchy_displays.set_enabled("USB-2", true)
settle()
eq(H.outputs["USB-2"].enabled, true, "switched back on")
eq(pos("USB-2") .. " " .. H.outputs["USB-2"].scale, "-1600,0 1.6", "at its remembered spot and scale")

-- A hand-written connector rule still wins after its display was unplugged
-- and the module sent its own rule for it meanwhile.
load_config(function()
  hl.monitor({ output = "USB-2", mode = "2560x1440@60", scale = 1.25, position = "auto" })
end)
settle()
disconnect("USB-2")
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(H.outputs["USB-2"].mode, "2560x1440@60", "the user's connector rule is still the newest match")
load_config()
settle()

-- A rule the user writes for a display in monitors.lua is left alone: later
-- changes never send a module rule for it that would win over the user's.
load_config(function()
  hl.monitor({ output = "desc:BNQ BenQ LCD", mode = "2560x1440@60", scale = 1.6, position = "auto" })
end)
settle()
H.focused = "eDP-1"
omarchy_displays.step_scale(1)
settle()
local newest
for i = #H.rules, 1, -1 do
  if H.rules[i].output:sub(1, 13) == "desc:BNQ BenQ" then
    newest = H.rules[i]
    break
  end
end
eq(newest.mode, "2560x1440@60", "the user's rule for the BenQ stays the newest match")
load_config()
settle()

-- GDK_SCALE follows main's scale, rounded, unless the config sets it.
H.focused = "eDP-1"
omarchy_displays.set_scale("eDP-1", 2)
settle()
eq(H.env.GDK_SCALE, "2", "GDK_SCALE follows main at 2")
omarchy_displays.set_scale("eDP-1", 3)
settle()
eq(H.env.GDK_SCALE, "3", "and at 3")
load_config(function()
  hl.env("GDK_SCALE", "1")
end)
settle()
omarchy_displays.set_scale("eDP-1", 4)
settle()
eq(H.env.GDK_SCALE, "1", "a GDK_SCALE set in the config stays")
load_config()
settle()

-- Someone's own solution comes first. displays-off: the module does nothing
-- and SUPER+/ runs the scaling script as before Omarchy had display handling.
flag = io.open(toggles .. "displays-off.lua", "w")
flag:write("-- off\n")
flag:close()
load_config()
local off_module = require("default.hypr.displays")
eq(omarchy_displays, nil, "with displays-off there is no display API")
sent = H.sent
H.notes = {}
off_module.step_scale(1)
eq(H.sent, sent, "with displays-off no monitor rule is sent")
eq(H.notes[1], "omarchy-hyprland-monitor-scaling up", "SUPER+/ falls back to the scaling script")
eq(#H.workspace_rules, 0, "with displays-off no workspace is pinned")
eq(store.load().global_workspaces, true, "and the bar shows global workspaces")
local leftmost
for _, name in ipairs(H.order) do
  leftmost = (not leftmost or H.outputs[name].x < H.outputs[leftmost].x) and name or leftmost
end
off_module.choose_display()
off_module.send_window(1)
eq(H.dispatched[#H.dispatched].move.monitor, leftmost, "SUPER+D 1 still sends to the leftmost display")
os.remove(toggles .. "displays-off.lua")

-- display-workspaces-off: displays are still arranged and scaled, but
-- workspaces stay global and nothing is pinned or moved.
flag = io.open(toggles .. "display-workspaces-off.lua", "w")
flag:write("-- off\n")
flag:close()
load_config()
settle()
H.focused = "USB-2"
eq(omarchy_displays.slot(3), "3", "SUPER+3 is workspace 3 wherever it is")
eq(#H.workspace_rules, 0, "no workspace is pinned")
eq(store.load().global_workspaces, true, "the store tells the bar to show global workspaces")
eq(store.load().displays["desc:" .. benq].block, 1, "each display keeps its block for when they're per display again")
eq(H.config, nil, "the workspace swipe is left as it is")
H.windows = { a = 3 }
disconnect("USB-2")
settle()
eq(H.windows.a, 3, "a lost display's windows are left to Hyprland")
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
assert(omarchy_displays.status():find("desc:" .. benq, 1, true), "the arrangement still works")
os.remove(toggles .. "display-workspaces-off.lua")
H.windows = {}
load_config()
settle()

-- A display that isn't connected is still pinned at load, so its windows go
-- home the moment it connects.
disconnect("USB-4")
settle()
load_config()
eq(rules_for("41")[1].monitor, "desc:DEL U2723QE ABC", "an absent display's slots are pinned at load")

-- Blocks survive a reload and a restart.
local saved = store.load()
eq(saved.displays["eDP-1"].block, 0, "the laptop's block is stored")
eq(saved.displays["desc:" .. benq].block, 1, "the BenQ's block is stored")

-- The first start on a running desktop with both displays on: the laptop gets
-- 1-10 even though the BenQ's identity sorts first.
os.remove(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
reset_hyprland()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
connect("eDP-1", "", "", 3456, 2160, 2)
load_config()
settle()
eq(store.load().displays["eDP-1"].block, 0, "the laptop gets 1-10")
eq(store.load().displays["desc:" .. benq].block, 1, "the BenQ gets 11-20")

-- The first start docked with the lid closed: the panel is off, but its
-- block stays free for it.
os.remove(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
reset_hyprland()
flag = io.open(toggles .. "internal-monitor-clamshell.lua", "w")
flag:write("-- clamshell\n")
flag:close()
load_config()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(store.load().displays["desc:" .. benq].block, 1, "in clamshell the external still gets 11-20")
os.remove(toggles .. "internal-monitor-clamshell.lua")

-- A Mac without an internal panel: the first display gets 1-10.
os.remove(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
reset_hyprland()
load_config()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(store.load().displays["desc:" .. benq].block, 0, "without an internal panel the first display gets 1-10")

-- A model once seen as twins isn't pinned by description, which would catch
-- both twins. Rules can't be taken back at runtime, so that holds from the
-- next load on.
connect("USB-5", "LG 27UL850 ABC", "ABC", 3840, 2160, 2)
connect("USB-6", "LG 27UL850 ABC", "ABC", 3840, 2160, 2)
settle()
disconnect("USB-6")
settle()
load_config()
for _, rule in ipairs(H.workspace_rules) do
  assert(rule.monitor ~= "desc:LG 27UL850 ABC", "a model seen as twins isn't pinned by description")
end

-- The lid closed and the last display unplugged: nothing is on, and the
-- next display to connect is seated as usual.
os.remove(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
reset_hyprland()
load_config()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
disconnect("USB-2")
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
assert(omarchy_displays.status():find("desc:" .. benq, 1, true), "a display connects again after none was on")

-- Where the module put displays is remembered too: the middle one of three
-- goes back to the middle when it's unplugged and plugged in again.
os.remove(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
reset_hyprland()
load_config()
connect("eDP-1", "", "", 3456, 2160, 2)
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
connect("USB-4", "DEL U2723QE ABC", "ABC", 3840, 2160, 2)
settle()
local middle, right = pos("USB-2"), pos("USB-4")
disconnect("USB-2")
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(pos("USB-2") .. " " .. pos("USB-4"), middle .. " " .. right, "the middle display returns to the middle")

-- A display that comes back at another scale keeps its side: the BenQ is
-- put left of the laptop, unplugged, the laptop is rescaled, and the BenQ
-- is plugged back in, matched to it at a new size.
disconnect("USB-4")
settle()
H.outputs["eDP-1"].physical, H.outputs["USB-2"].physical = 346, 600
local function beside()
  local lap, b = H.outputs["eDP-1"], H.outputs["USB-2"]
  local lw, lh = logical(lap)
  local bw, bh = logical(b)
  return (b.x + bw == lap.x and b.y + bh == lap.y + lh) and "left, bottoms flush" or (pos("USB-2") .. " beside " .. pos("eDP-1"))
end
local lw, lh = logical(H.outputs["eDP-1"])
local bw, bh = logical(H.outputs["USB-2"])
assert(omarchy_displays.move("USB-2", H.outputs["eDP-1"].x - bw, H.outputs["eDP-1"].y + lh - bh), "the BenQ goes left of the laptop")
settle()
eq(beside(), "left, bottoms flush", "the BenQ is left of the laptop")
local before = H.outputs["USB-2"].scale
disconnect("USB-2")
settle()
H.focused = "eDP-1"
omarchy_displays.step_scale(1)
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1, 600)
settle()
assert(H.outputs["USB-2"].scale ~= before, "the BenQ comes back at another scale, matched to the laptop")
eq(beside(), "left, bottoms flush", "and still left of the laptop, bottoms flush")
load_config()
settle()
eq(beside(), "left, bottoms flush", "and a reload keeps it there")

-- A display turned in the panel keeps its side and its bottom edge, and the
-- laptop beside it doesn't move. The turn is remembered for that display,
-- through an unplug and a reload; a turn the panel doesn't offer is ignored.
H.moved, H.focused = {}, "eDP-1"
local laptop_at = pos("eDP-1")
omarchy_displays.set_rotation("USB-2", 1)
local first_rule
for i = #H.rules, 1, -1 do
  if H.rules[i].output == "desc:" .. benq then
    first_rule = H.rules[i].position
    break
  end
end
settle()
eq(H.outputs["USB-2"].transform, 1, "the BenQ is turned 90°")
bw, bh = logical(H.outputs["USB-2"])
assert(bh > bw, "and stands upright")
eq(beside(), "left, bottoms flush", "still left of the laptop, bottoms flush")
eq(first_rule, H.outputs["USB-2"].x .. "x" .. H.outputs["USB-2"].y, "the first rule sent already puts it there")
eq(pos("eDP-1") .. " " .. moves("eDP-1"), laptop_at .. " 0", "the laptop doesn't move")
eq(store.load().displays["desc:" .. benq].transform, 1, "the turn is remembered for the BenQ")
assert(omarchy_displays.status():find("USB%-2%) [^\n]* transform 1"), "and shows in the status")
local sent_before = H.sent
omarchy_displays.set_rotation("USB-2", 1)
omarchy_displays.set_rotation("USB-2", 5)
omarchy_displays.set_rotation("USB-2", 1.5)
omarchy_displays.set_rotation("USB-9", 3)
settle()
eq(H.sent, sent_before, "the same turn again, a flip, a fraction or an unknown display sends nothing")
disconnect("USB-2")
settle()
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1, 600)
settle()
eq(H.outputs["USB-2"].transform, 1, "the BenQ comes back turned")
eq(beside(), "left, bottoms flush", "on its side")
load_config()
settle()
eq(H.outputs["USB-2"].transform .. " " .. beside(), "1 left, bottoms flush", "and a reload keeps it so")

-- The built-in display turns too. A half turn changes no size, so nothing
-- moves; turned back, the BenQ is standard again beside the laptop.
H.moved = {}
omarchy_displays.set_rotation("eDP-1", 2)
settle()
eq(H.outputs["eDP-1"].transform, 2, "the built-in display turns too")
eq(moves("eDP-1") + moves("USB-2"), 0, "a half turn moves nothing")
omarchy_displays.set_rotation("eDP-1", 0)
settle()
omarchy_displays.set_rotation("USB-2", 0)
settle()
eq(H.outputs["eDP-1"].transform + H.outputs["USB-2"].transform, 0, "both back to standard")
eq(beside(), "left, bottoms flush", "and the BenQ still left of the laptop, bottoms flush")

print(omarchy_displays.status())
print("flow ok")
LUA
) || fail "display arrangement flow" "$flow_output"
pass "display arrangement: first sight, place, replug, scale, rotation, outside changes, reload, boot, clamshell, mirror, ports, three displays, workspaces"
