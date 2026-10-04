#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

tmpdir=$(mktemp -d)
# A versioned LUA_INIT would take precedence over the platform root seam.
unset LUA_INIT LUA_INIT_5_5 LUA_INIT_5_4
trap 'rm -rf "$tmpdir"' EXIT

# The runtime under test (this tree, or another layout's through
# OMARCHY_TEST_RUNTIME) with omarchy-mac staged. A runtime with the fixed
# platform root loads the gesture from /usr/share/omarchy-platform, which its
# test seam (platform-root.lua through LUA_INIT) moves to the staged root; an
# older one loads the copy in its own tree, through OMARCHY_PACKAGED_PATH.
runtime=${OMARCHY_TEST_RUNTIME:-$ROOT}
"$ROOT/packages/omarchy-mac/install" "$tmpdir/pkg" >/dev/null
staged=$tmpdir/pkg

platform_env() {
  local omarchy_path=$1 root=$2
  if [[ -f $omarchy_path/test/shell.d/platform-root.lua ]]; then
    printf '%s\n' "LUA_INIT=@$omarchy_path/test/shell.d/platform-root.lua" "OMARCHY_TEST_PLATFORM_ROOT=$root/usr/share/omarchy-platform"
  else
    printf '%s\n' "OMARCHY_PACKAGED_PATH=$root/usr/share/omarchy"
  fi
}

mkdir -p "$tmpdir/apple-bin" "$tmpdir/other-bin"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/omarchy-hw-apple-silicon"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/other-bin/omarchy-hw-apple-silicon"
chmod +x "$tmpdir"/*-bin/omarchy-hw-apple-silicon

# Loads the shipped hyprland.lua against a user's ~/.config/hypr and prints one
# line per gesture Hyprland accepted, then "error" for each one it rejected.
# The stub applies Hyprland 0.56's rule (CTrackpadGestures::addGesture): a
# gesture on the same fingers and mods is refused once an earlier one covers
# its direction or axis, and the refusal is a config error.
load_config() {
  local platform="$1" edit="${2:-}" omarchy_path="${OMARCHY_UNDER_TEST:-$runtime}" staged_root="${PACKAGED_UNDER_TEST:-$staged}"
  local home platform_vars
  mapfile -t platform_vars < <(platform_env "$omarchy_path" "$staged_root")
  home=$(mktemp -d "$tmpdir/home.XXXXXX")

  mkdir -p "$home/.config"
  cp -R "$runtime/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/input.lua"
  local toggle
  for toggle in ${TOGGLES:-}; do
    mkdir -p "$home/.local/state/omarchy/toggles/hypr"
    : >"$home/.local/state/omarchy/toggles/hypr/$toggle.lua"
  done

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$omarchy_path" \
    PATH="$tmpdir/$platform-bin:$PATH" env "${platform_vars[@]}" lua <<'LUA'
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
[[ -z $(PACKAGED_UNDER_TEST=$tmpdir/none load_config apple) ]] ||
  fail "the runtime alone carries no Mac gesture" "$(PACKAGED_UNDER_TEST=$tmpdir/none load_config apple)"
[[ $(OMARCHY_UNDER_TEST=$ROOT load_config apple) == "$swipe" ]] ||
  fail "a development checkout in OMARCHY_PATH keeps the packaged gesture" "$(OMARCHY_UNDER_TEST=$ROOT load_config apple)"
[[ ! -e $ROOT/default/hypr/apple-gestures.lua && ! -e $ROOT/default/hypr/platform ]] ||
  fail "the Mac gesture is omarchy-mac's, not the runtime's"
pass "three-finger workspace swipe is on by default on Macs only, from omarchy-mac"

shipped_line=$(sed -nE 's/^-- (hl\.gesture\(\{ fingers = 3, direction = "horizontal".*)$/\1/p' "$runtime/config/hypr/input.lua")
[[ -n $shipped_line ]] || fail "input.lua still ships the workspace gesture example"
output=$(load_config apple "$shipped_line")
[[ $output == "$swipe" ]] || fail "uncommenting the shipped example keeps one gesture and no config error" "$output"
pass "uncommenting the shipped example does not duplicate the gesture"

focus_lines=$(sed -nE 's/^-- (hl\.gesture\(\{ fingers = 3, direction = "(left|right)".*)$/\1/p' "$runtime/config/hypr/input.lua")
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

[[ $(SHOW_USE_R=1 TOGGLES=display-workspaces-off load_config apple) == "$swipe"$'\nworkspace_swipe_use_r true' ]] ||
  fail "a Mac swipe steps by number, into empty workspaces" "$(SHOW_USE_R=1 TOGGLES=display-workspaces-off load_config apple)"
[[ $(SHOW_USE_R=1 load_config other) == "workspace_swipe_use_r false" ]] ||
  fail "x86 and Snapdragon keep Hyprland's own workspace stepping" "$(SHOW_USE_R=1 load_config other)"
output=$(SHOW_USE_R=1 TOGGLES=display-workspaces-off load_config apple "$shipped_line")
[[ $output == "$swipe"$'\nworkspace_swipe_use_r true' ]] ||
  fail "a user's own workspace gesture on a Mac steps by number too" "$output"
use_r_off='hl.config({ gestures = { workspace_swipe_use_r = false } })'
output=$(SHOW_USE_R=1 load_config apple "$use_r_off")
[[ $output == "$swipe"$'\nworkspace_swipe_use_r false' ]] ||
  fail "the user's workspace_swipe_use_r = false keeps Hyprland's stepping with the Mac gesture" "$output"
output=$(SHOW_USE_R=1 load_config apple "$shipped_line"$'\n'"$use_r_off")
[[ $output == "$swipe"$'\nworkspace_swipe_use_r false' ]] ||
  fail "the user's workspace_swipe_use_r = false keeps Hyprland's stepping with their own gesture" "$output"
pass "a Mac's workspace swipes step into empty workspaces; the user's workspace_swipe_use_r = false wins"

# Another runtime layout (OMARCHY_TEST_RUNTIME) may have no per-display workspaces.
if [[ -e $runtime/default/hypr/displays.lua ]]; then
  [[ $(SHOW_USE_R=1 load_config apple) == "$swipe"$'\nworkspace_swipe_use_r false' ]] ||
    fail "per-display workspaces keep the swipe on the display's own workspaces" "$(SHOW_USE_R=1 load_config apple)"
  output=$(SHOW_USE_R=1 load_config apple "$shipped_line")
  [[ $output == "$swipe"$'\nworkspace_swipe_use_r false' ]] ||
    fail "per-display workspaces keep a user's own workspace gesture on the display's workspaces" "$output"
  use_r_on='hl.config({ gestures = { workspace_swipe_use_r = true } })'
  output=$(SHOW_USE_R=1 load_config apple "$use_r_on")
  [[ $output == "$swipe"$'\nworkspace_swipe_use_r true' ]] ||
    fail "the user's workspace_swipe_use_r = true wins over per-display workspaces" "$output"
  pass "per-display workspaces keep the swipe on the display's own workspaces; the user's setting wins"
fi

grep -Fq 'omarchy_workspace_gesture = false' "$ROOT/mac-manual/content/06-keyboard.md" ||
  fail "the manual documents how to turn the Mac gesture off"
grep -Fq "$use_r_off" "$ROOT/mac-manual/content/06-keyboard.md" ||
  fail "the manual documents how to turn the Mac's stepping off"
pass "the manual documents how to turn the Mac gesture and its stepping off"
