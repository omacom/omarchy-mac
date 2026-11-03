#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/apple-bin" "$tmpdir/other-bin"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/omarchy-hw-apple"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/other-bin/omarchy-hw-apple"
chmod +x "$tmpdir"/*-bin/omarchy-hw-apple

# Loads the shipped hyprland.lua against a user's ~/.config/hypr and prints one
# line per gesture Hyprland accepted, then "error" for each one it rejected.
# The stub applies Hyprland 0.56's rule (CTrackpadGestures::addGesture): a
# gesture on the same fingers and mods is refused once an earlier one covers
# its direction or axis, and the refusal is a config error.
load_config() {
  local platform="$1" edit="${2:-}"
  local home
  home=$(mktemp -d "$tmpdir/home.XXXXXX")

  mkdir -p "$home/.config"
  cp -R "$ROOT/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/input.lua"

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" \
    PATH="$tmpdir/$platform-bin:$PATH" lua <<'LUA'
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

local aliases = { l = "left", r = "right", u = "up", d = "down", horiz = "horizontal", vert = "vertical" }
local axes = {
  left = "horizontal", right = "horizontal", horizontal = "horizontal",
  up = "vertical", down = "vertical", vertical = "vertical",
  swipe = "swipe",
}
local accepted = {}

-- KeybindManager::stringToModMask: any string naming no modifier is mask zero.
local function mod_mask(mods)
  local mask = {}
  mods = (mods or ""):upper()
  for name, bit in pairs({ SHIFT = "S", CAPS = "C", CTRL = "T", CONTROL = "T", ALT = "A", SUPER = "M", WIN = "M", META = "M" }) do
    if mods:find(name, 1, true) then
      mask[bit] = true
    end
  end
  local bits = {}
  for bit in pairs(mask) do
    table.insert(bits, bit)
  end
  table.sort(bits)
  return table.concat(bits)
end

hl = setmetatable({
  dsp = proxy(),
  config = function(config)
    if config.gestures and config.gestures.workspace_swipe_use_r ~= nil then
      use_r = config.gestures.workspace_swipe_use_r
    end
  end,
  gesture = function(gesture)
    local direction = gesture.direction:lower()
    direction = aliases[direction] or direction
    local axis = axes[direction]
    local mods = mod_mask(gesture.mods)

    for _, g in ipairs(accepted) do
      if g.fingers == gesture.fingers and g.mods == mods and
        (g.direction == axis or g.direction == direction or
          ((axis == "horizontal" or axis == "vertical") and g.direction == "swipe")) then
        print("error")
        return
      end
    end

    table.insert(accepted, { fingers = gesture.fingers, direction = direction, mods = mods })
    local action = type(gesture.action) == "string" and gesture.action or "function"
    print(gesture.fingers .. " " .. direction .. " " .. (mods ~= "" and "+" .. mods .. " " or "") .. action)
  end,
  get_config = function() return nil end,
  get_active_window = function() return nil end,
  get_monitors = function() return {} end,
}, {
  __index = function()
    return function()
      return {}
    end
  end,
})

dofile(os.getenv("HOME") .. "/.config/hypr/hyprland.lua")
if os.getenv("SHOW_USE_R") then
  print("workspace_swipe_use_r " .. tostring(use_r == true))
end
LUA
}

swipe="3 horizontal workspace"

[[ $(load_config apple) == "$swipe" ]] || fail "a Mac swipes between workspaces with three fingers" "$(load_config apple)"
[[ -z $(load_config other) ]] || fail "x86 and Snapdragon keep no default gesture" "$(load_config other)"
pass "three-finger workspace swipe is on by default on Macs only"

shipped_line=$(sed -nE 's/^-- (hl\.gesture\(\{ fingers = 3, direction = "horizontal".*)$/\1/p' "$ROOT/config/hypr/input.lua")
[[ -n $shipped_line ]] || fail "input.lua still ships the workspace gesture example"
output=$(load_config apple "$shipped_line")
[[ $output == "$swipe" ]] || fail "uncommenting the shipped example keeps one gesture and no config error" "$output"
pass "uncommenting the shipped example does not duplicate the gesture"

focus_lines=$(sed -nE 's/^-- (hl\.gesture\(\{ fingers = 3, direction = "(left|right)".*)$/\1/p' "$ROOT/config/hypr/input.lua")
(( $(wc -l <<<"$focus_lines") == 2 )) || fail "input.lua still ships the focus gesture examples" "$focus_lines"
output=$(load_config apple "$focus_lines")
[[ $output == $'3 left function\n3 right function' ]] || fail "three-finger focus gestures replace the workspace swipe" "$output"
pass "a user's own three-finger sideways gestures replace the default"

output=$(load_config apple 'hl.gesture({ fingers = 3, direction = "swipe", action = "move" })')
[[ $output == "3 swipe move" ]] || fail "a three-finger swipe gesture replaces the workspace swipe" "$output"
output=$(load_config apple 'hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })')
[[ $output == $'4 horizontal workspace\n'"$swipe" ]] || fail "a four-finger gesture keeps the three-finger default" "$output"
output=$(load_config apple 'hl.gesture({ fingers = 3, direction = "up", action = "fullscreen" })')
[[ $output == $'3 up fullscreen\n'"$swipe" ]] || fail "a vertical gesture keeps the sideways default" "$output"
output=$(load_config apple 'hl.gesture({ fingers = 3, direction = "horizontal", mods = "SUPER", action = "move" })')
[[ $output == $'3 horizontal +M move\n'"$swipe" ]] || fail "a gesture held with a modifier keeps the default" "$output"
pass "gestures on other fingers, axes or modifiers keep the default"

for mods in '"NONE"' '""' '" "'; do
  output=$(load_config apple 'hl.gesture({ fingers = 3, direction = "horizontal", mods = '"$mods"', action = "workspace" })')
  [[ $output == "$swipe" ]] || fail "mods = $mods counts as no modifier and replaces the default" "$output"
done
pass "a modifier string naming no modifier still replaces the default"

output=$(load_config apple 'omarchy_workspace_gesture = false')
[[ -z $output ]] || fail "omarchy_workspace_gesture = false turns the default off" "$output"
pass "omarchy_workspace_gesture = false turns the default off"

[[ $(SHOW_USE_R=1 load_config apple) == "$swipe"$'\nworkspace_swipe_use_r true' ]] ||
  fail "a Mac swipe steps by number, into empty workspaces" "$(SHOW_USE_R=1 load_config apple)"
[[ $(SHOW_USE_R=1 load_config other) == "workspace_swipe_use_r false" ]] ||
  fail "x86 keeps Hyprland's own workspace stepping" "$(SHOW_USE_R=1 load_config other)"
output=$(SHOW_USE_R=1 load_config apple "$focus_lines")
[[ $output == $'3 left function\n3 right function\nworkspace_swipe_use_r false' ]] ||
  fail "a user's own gesture keeps Hyprland's stepping" "$output"
output=$(SHOW_USE_R=1 load_config apple 'omarchy_workspace_gesture = false')
[[ $output == "workspace_swipe_use_r false" ]] ||
  fail "omarchy_workspace_gesture = false keeps Hyprland's stepping" "$output"
pass "a Mac's workspace swipe steps into empty workspaces, only with Omarchy's own gesture"

grep -Fq 'omarchy_workspace_gesture = false' "$ROOT/manual/34-keyboard-mouse-trackpad.md" ||
  fail "the manual documents how to turn the Mac gesture off"
pass "the manual documents how to turn the Mac gesture off"
