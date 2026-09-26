#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Prints one line per hl.bind: keys, then "focus <devices>" for a bind scoped to
# keyboards, or the exec command for a launcher.
load_bindings() {
  local apple="$1"

  lua - "$ROOT" "$apple" <<'LUA'
local root, apple = arg[1], arg[2] == "1"
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
  on = function() end,
  unbind = function(keys)
    print("unbind\t" .. keys)
  end,
  bind = function(keys, dispatcher, opts)
    if opts and opts.device then
      assert(opts.device.inclusive == true, "focus bind only matches the listed keyboards")
      assert(dispatcher == o.focus_builtin_screen, "focus bind runs the built-in screen focus")
      print(keys .. "\tfocus " .. table.concat(opts.device.list, ","))
    elseif type(dispatcher) == "table" and dispatcher.cmd then
      print(keys .. "\t" .. dispatcher.cmd)
    else
      print(keys .. "\tother")
    end
  end,
}
hl.dsp.exec_cmd = function(cmd)
  return { cmd = cmd }
end
dofile(root .. "/default/hypr/helpers.lua")
local probes = 0
o.shell_succeeds = function(command)
  if command == "omarchy-hw-apple-silicon" then
    probes = probes + 1
  end
  return apple
end
o.preinstalled_bindings_enabled = function()
  return true
end
dofile(root .. "/default/hypr/bindings/applications.lua")
dofile(root .. "/default/hypr/bindings/utilities.lua")
dofile(root .. "/default/hypr/bindings/tiling.lua")
o.bind("SUPER + F9", "Power menu (locked)", "omarchy-menu toggle system", { locked = true })
o.rebind("SUPER + SHIFT + F", "File manager", { launch = "flea" })
assert(probes <= 2, "hardware probe runs once per config load, not per bind (" .. probes .. ")")
LUA
}

apple=$(load_bindings 1) || fail "bindings load on Apple Silicon" "$apple"
other=$(load_bindings 0) || fail "bindings load elsewhere" "$other"

keyboards="apple-spi-keyboard,apple-mtp-keyboard"

expect_focus_then() {
  local keys="$1" command="$2"
  local want=$'\n'"$keys"$'\tfocus '"$keyboards"$'\n'"$keys"$'\t'"$command"$'\n'

  [[ $'\n'"$apple"$'\n' == *"$want"* ]] || fail "$keys focuses the built-in screen first when typed on the MacBook keyboard" "$apple"
}

expect_focus_then "SUPER + SPACE" "omarchy-menu toggle"
expect_focus_then "SUPER + ALT + SPACE" "omarchy-menu toggle apps"
expect_focus_then "SUPER + CTRL + E" "omarchy-shell shell toggle omarchy.emojis"
expect_focus_then "SUPER + K" "omarchy-menu-keybindings"
expect_focus_then "SUPER + CTRL + Q" "omacalc"
expect_focus_then "SUPER + RETURN" "omarchy-launch-terminal"
expect_focus_then "SUPER + SHIFT + A" "omarchy-launch-webapp 'https://chatgpt.com'"
expect_focus_then "SUPER + SHIFT + ALT + M" "omarchy-launch-or-focus-tui 'cliamp'"
expect_focus_then "SUPER + SHIFT + W" "uwsm-app -- omawrite"
expect_focus_then "SUPER + CTRL + code:10" "omarchy-shell -q shell togglePanelAt right 1"
expect_focus_then "SUPER + SHIFT + CTRL + A" "omarchy-agent --pick"
pass "launchers typed on the MacBook keyboard focus the built-in screen first"

[[ $apple == *$'unbind\tSUPER + SHIFT + F\nSUPER + SHIFT + F\tfocus '"$keyboards"$'\nSUPER + SHIFT + F\tuwsm-app -- flea'* ]] ||
  fail "rebinding a launcher keeps the built-in screen focus" "$apple"
pass "rebinding a launcher keeps the built-in screen focus"

for keys in "SUPER + F9" "SUPER + BACKSPACE" "SUPER + CTRL + N" "PRINT" "ALT + PRINT" "SUPER + F12" "SUPER + LEFT" "SUPER + 1"; do
  grep -qxF "$keys"$'\tfocus '"$keyboards" <<<"$apple" && fail "$keys is not a launcher and keeps today's focus" "$apple"
done
pass "toggles, captures, locked and tiling binds keep today's focus"

grep -q $'\tfocus ' <<<"$other" && fail "no keyboard-scoped binds off Apple Silicon" "$other"
grep -qxF $'SUPER + SPACE\tomarchy-menu toggle' <<<"$other" || fail "off Apple Silicon the launchers still bind" "$other"
pass "no keyboard-scoped binds off Apple Silicon"

focus_with() {
  lua - "$ROOT" "$1" <<'LUA'
local root, layout = arg[1], arg[2]
hl = {
  dsp = {
    focus = function(args)
      return args
    end,
  },
  dispatch = function(dispatcher)
    print("focus " .. dispatcher.monitor)
  end,
  get_monitors = function()
    local monitors = {}
    for name, focused in layout:gmatch("([%w%-]+)(%*?)") do
      monitors[#monitors + 1] = { name = name, focused = focused == "*" }
    end
    return monitors
  end,
}
dofile(root .. "/default/hypr/helpers.lua")
o.focus_builtin_screen()
print("done")
LUA
}

[[ $(focus_with "DP-1* eDP-1") == $'focus eDP-1\ndone' ]] || fail "focus moves to the built-in screen from an external one"
[[ $(focus_with "DP-1 eDP-1*") == "done" ]] || fail "focus stays when the built-in screen already has it"
[[ $(focus_with "DP-1* HDMI-A-1") == "done" ]] || fail "clamshell: no built-in screen, focus stays"
[[ $(focus_with "eDP-1*") == "done" ]] || fail "built-in screen alone: nothing to do"
pass "built-in screen focus handles external, built-in only and clamshell layouts"
