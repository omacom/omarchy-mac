#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua
lua_bin=$(command -v lua)

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

home="$tmp_dir/home"
stub_bin="$tmp_dir/bin"
compatible="$tmp_dir/compatible"
model="$tmp_dir/model"
mkdir -p "$home" "$stub_bin"
touch "$stub_bin/voxtype"
chmod +x "$stub_bin/voxtype"
ln -s "$(command -v grep)" "$stub_bin/grep"
ln -s "$(command -v sort)" "$stub_bin/sort"

list_bindings() {
  HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_UNAME_M=aarch64 \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_APPLE_MODEL="$model" \
    PATH="$stub_bin:$ROOT/bin" \
    "$lua_bin" <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

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

local bindings = {}

hl = setmetatable({
  dsp = proxy(),
  bind = function(keys, dispatcher, opts)
    opts = opts or {}
    table.insert(bindings, { keys = keys, description = opts.description or "" })
  end,
  unbind = function(keys)
    for index = #bindings, 1, -1 do
      if bindings[index].keys == keys then
        table.remove(bindings, index)
      end
    end
  end,
  config = function() end,
  env = function() end,
  monitor = function() end,
  window_rule = function() end,
  workspace_rule = function() end,
  layer_rule = function() end,
  gesture = function() end,
  animation = function() end,
  curve = function() end,
  exec_cmd = function() end,
  dispatch = function() end,
  on = function() end,
  timer = function() end,
  get_config = function() return nil end,
  get_active_window = function() return nil end,
}, {
  __index = function()
    return function()
      return {}
    end
  end,
})

require("default.hypr.omarchy")

for _, binding in ipairs(bindings) do
  print(binding.keys .. "\t" .. binding.description)
end
LUA
}

printf 'apple,j313\0apple,t8103\0' >"$compatible"
printf 'Apple MacBook Air (M1, 2020)\0' >"$model"
m1_bindings=$(list_bindings)

grep -Fqx $'XF86LaunchA\tApps menu (F3)' <<<"$m1_bindings" ||
  fail "the M1 Air F3 key opens the Apps menu"
grep -Fqx $'XF86LaunchB\tOmarchy search (F4)' <<<"$m1_bindings" ||
  fail "the M1 Air F4 key opens Omarchy search"
grep -Fqx $'XF86Search\tOmarchy search (F4)' <<<"$m1_bindings" ||
  fail "the alternate M1 Air F4 keysym opens Omarchy search"
grep -Fqx $'XF86KbdBrightnessDown\tToggle dictation (F5)' <<<"$m1_bindings" ||
  fail "the M1 Air F5 key toggles dictation"
grep -Fqx $'XF86KbdBrightnessUp\tToggle Do Not Disturb (F6)' <<<"$m1_bindings" ||
  fail "the M1 Air F6 key toggles Do Not Disturb"
pass "the M1 Air physical F3-F6 keys run their labelled actions"

grep -Fqx $'SHIFT + XF86MonBrightnessDown\tKeyboard brightness down' <<<"$m1_bindings" ||
  fail "Shift+F1 retains keyboard-backlight control"
grep -Fqx $'SHIFT + XF86MonBrightnessUp\tKeyboard brightness up' <<<"$m1_bindings" ||
  fail "Shift+F2 retains keyboard-backlight control"
grep -Fqx $'SUPER + F10\tScreenshot Window' <<<"$m1_bindings" ||
  fail "the existing Apple F10 screenshot binding remains"
grep -Fqx $'SUPER + F11\tScreenshot Region' <<<"$m1_bindings" ||
  fail "the existing Apple F11 screenshot binding remains"
grep -Fqx $'SUPER + F12\tScreenshot Display' <<<"$m1_bindings" ||
  fail "the existing Apple F12 screenshot binding remains"
pass "M1 overrides retain keyboard lighting and Apple capture bindings"

for chord in PRINT 'ALT + PRINT' 'SUPER + PRINT' 'SUPER + CTRL + PRINT'; do
  grep -Fq "$chord"$'\t' <<<"$m1_bindings" &&
    fail "the M1 Air does not expose a dead $chord binding"
done
pass "the M1 Air omits dead Print Screen bindings"

rm "$stub_bin/voxtype"
without_voxtype=$(list_bindings)
if grep -Fq $'XF86KbdBrightnessDown\t' <<<"$without_voxtype"; then
  fail "F5 does not run a missing dictation command"
fi
grep -Fqx $'XF86KbdBrightnessUp\tToggle Do Not Disturb (F6)' <<<"$without_voxtype" ||
  fail "F6 stays available without the optional dictation package"
pass "the M1 top-row avoids a dead dictation binding when Voxtype is absent"

printf 'Apple MacBook Pro (13-inch, M1, 2020)\0' >"$model"
other_mac_bindings=$(list_bindings)

if grep -Fq $'XF86LaunchA\tApps menu (F3)' <<<"$other_mac_bindings"; then
  fail "M1 Air top-row overrides do not affect another Mac model"
fi
grep -Fqx $'XF86KbdBrightnessDown\tKeyboard brightness down' <<<"$other_mac_bindings" ||
  fail "another Mac retains the default keyboard-brightness binding"
grep -Fqx $'PRINT\tScreenshot' <<<"$other_mac_bindings" ||
  fail "another Mac retains the default Print Screen binding"
pass "M1 Air overrides are gated from other Mac models"
