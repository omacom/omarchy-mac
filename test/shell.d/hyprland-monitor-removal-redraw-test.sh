#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

grep -Fx 'require("default.hypr.monitor-removal-redraw")' "$ROOT/default/hypr/omarchy.lua" >/dev/null ||
  fail "the Omarchy Hyprland config loads the monitor removal redraw"
pass "the Omarchy Hyprland config loads the monitor removal redraw"

OMARCHY_PATH="$ROOT" lua - <<'LUA' || fail "windows from an unplugged monitor are resized once, unseen, when they show"
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local handlers, timers, borders = {}, {}, {}
local monitors, windows

hl = {
  on = function(event, callback)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], callback)
  end,
  timer = function(callback, opts)
    assert(opts.type == "oneshot" and opts.timeout > 0)
    table.insert(timers, callback)
  end,
  get_monitors = function()
    return monitors
  end,
  get_windows = function()
    return windows
  end,
  get_config = function(name)
    return name == "general.border_size" and 2 or nil
  end,
  dispatch = function(action)
    table.insert(borders, action.window:gsub("^address:", "") .. "=" .. action.value)
  end,
  dsp = {
    window = {
      set_prop = function(args)
        assert(args.prop == "border_size")
        return args
      end,
    },
  },
}

local function fire(event, ...)
  for _, callback in ipairs(handlers[event] or {}) do
    callback(...)
  end
end

local function settle()
  while #timers > 0 do
    local due = timers
    timers = {}
    for _, callback in ipairs(due) do
      callback()
    end
  end
end

local function took()
  table.sort(borders)
  local result = table.concat(borders, " ")
  borders = {}
  return result
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", what, expected, actual), 2)
  end
end

require("default.hypr.monitor-removal-redraw")

-- The BenQ was unplugged: its windows a and b came over to the laptop, a on
-- the workspace in front and b on one behind it; c was on the laptop already.
monitors = { { name = "eDP-1", active_workspace = { id = 1 } } }
windows = {
  { address = "a", workspace = { id = 1 } },
  { address = "b", workspace = { id = 12 } },
  { address = "c", workspace = { id = 1 } },
}
fire("monitor.removed", { name = "USB-1" })
eq(took(), "", "nothing is resized before the removal has reached the clients")
settle()
eq(took(), "a=3 a=unset c=3 c=unset", "the windows showing get a pixel more border and then their own back")

fire("workspace.active", { id = 1 })
settle()
eq(took(), "", "a window is resized only once")

-- A window opened since isn't touched; b shows when its workspace is switched to.
windows[#windows + 1] = { address = "d", workspace = { id = 12 } }
monitors[1].active_workspace = { id = 12 }
fire("workspace.active", { id = 12 })
settle()
eq(took(), "b=3 b=unset", "a window behind gets it once its workspace shows")

-- A window closed before it showed is let go.
fire("monitor.removed", { name = "USB-2" })
windows = { { address = "e", workspace = { id = 3 } } }
settle()
fire("workspace.active", { id = 3 })
monitors[1].active_workspace = { id = 3 }
settle()
eq(took(), "", "windows closed before they showed are let go, and one opened since isn't touched")
fire("workspace.active", { id = 3 })
settle()
eq(took(), "", "nothing is left waiting")
print("redraw ok")
LUA
pass "windows from an unplugged monitor are resized once, unseen, when they show"
