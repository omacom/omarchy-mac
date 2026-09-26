#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

lua - "$ROOT" <<'LUA' || fail "pointer crossing screens leaves monitor focus alone"
local root = arg[1]
local config = {}
hl = {
  config = function(value)
    for section, values in pairs(value) do
      config[section] = config[section] or {}
      for key, setting in pairs(values) do
        config[section][key] = setting
      end
    end
  end,
  device = function() end,
}
o = { window = function() end }
dofile(root .. "/default/hypr/input.lua")
assert(config.misc.mouse_move_focuses_monitor == false)
assert(config.input.follow_mouse == 1)
LUA
pass "pointer crossing screens leaves monitor focus alone"

bindings=$(lua - "$ROOT" <<'LUA'
local root = arg[1]
local function proxy()
  return setmetatable({}, {
    __index = function(self, key)
      local value = proxy()
      rawset(self, key, value)
      return value
    end,
    __call = function()
      return {}
    end,
  })
end
hl = {
  dsp = proxy(),
  bind = function(keys, dispatcher, opts)
    if dispatcher.monitor then
      print(keys .. "\t" .. dispatcher.monitor .. "\t" .. tostring(dispatcher.follow) .. "\t" .. opts.description)
    end
  end,
}
hl.dsp.window.move = function(args)
  return args
end
dofile(root .. "/default/hypr/helpers.lua")
dofile(root .. "/default/hypr/bindings/tiling.lua")
LUA
) || fail "tiling bindings load"

expected=$'SUPER + CTRL + SHIFT + LEFT\tl\tnil\tMove window to left monitor
SUPER + CTRL + SHIFT + RIGHT\tr\tnil\tMove window to right monitor
SUPER + CTRL + SHIFT + UP\tu\tnil\tMove window to up monitor
SUPER + CTRL + SHIFT + DOWN\td\tnil\tMove window to down monitor'
[[ $bindings == "$expected" ]] || fail "move-window-to-monitor bindings take focus with the window" "$bindings"
pass "move-window-to-monitor bindings take focus with the window"
