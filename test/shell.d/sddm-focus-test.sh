#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command lua
lua - "$ROOT/default/sddm/hyprland.lua" <<'LUA'
local path = arg[1]
local monitors, windows, active, callback, event, enabled, dispatched
local function reset()
  monitors, windows, active, enabled, dispatched = {}, {}, nil, true, nil
  hl = {
    config = function() end,
    window_rule = function(rule) assert(rule.no_initial_focus) end,
    get_monitors = function() return monitors end,
    get_windows = function() return windows end,
    get_active_window = function() return active end,
    timer = function(fn) callback = fn; return { set_enabled = function(_, value) enabled = value end } end,
    on = function(name, fn) assert(name == "window.open"); event = fn end,
    dsp = { focus = function(value) return value end },
    dispatch = function(value) dispatched = value.window end,
  }
  dofile(path)
end
local function window(address, monitor)
  return {address=address, monitor=monitor, mapped=true, class="sddm-greeter-qt6"}
end
reset()
callback(); assert(enabled and not dispatched)
monitors = {{name="eDP-1"}}
local internal = window("0x1", monitors[1])
windows = {internal}
callback(); assert(dispatched == "address:0x1" and enabled)
active = internal; callback(); assert(not enabled)
monitors[2] = {name="USB-1"}
local external = window("0x2", monitors[2])
windows[2] = external
active = nil; dispatched = nil; event(external); callback()
assert(dispatched == "address:0x1" and enabled)
active = internal; callback(); assert(not enabled)
active = external; dispatched = nil; event(external); callback()
assert(not enabled and not dispatched, "preserve the prompt selected by the user")
reset()
monitors = {{name="HDMI-A-1"}}; windows = {window("0x3",monitors[1])}
callback(); assert(dispatched == "address:0x3")
reset()
for _ = 1,80 do callback() end
assert(not enabled and not dispatched, "startup polling must stop")
LUA
pass "greeter focus handles late outputs, manual selection, desktop fallback and timeout"
