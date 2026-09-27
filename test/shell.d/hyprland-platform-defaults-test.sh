#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Hyprland loads a platform package's own defaults from default/hypr/platform in
# the packaged tree, after the user's files, so the user's settings can keep them
# out. The fixture below is such a default: a three-finger sideways workspace
# swipe that steps aside for a gesture the user set.

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

packaged="$tmpdir/packaged"
mkdir -p "$packaged/default/hypr/platform"
cat >"$packaged/default/hypr/platform/fixture-gesture.lua" <<'LUA'
if _G.fixture_gesture == false then
  return
end
for _, gesture in ipairs(o.registered_gestures or {}) do
  if gesture.fingers == 3 and not gesture.modified and (gesture.direction == "horizontal" or gesture.direction == "left" or gesture.direction == "right") then
    return
  end
end
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
LUA

# Loads the shipped hyprland.lua against a user's ~/.config/hypr and prints one
# line per gesture Hyprland accepted, then "error" for each one it rejected.
# The stub applies Hyprland 0.56's rule (CTrackpadGestures::addGesture): a
# gesture on the same fingers and mods is refused once an earlier one covers
# its direction or axis, and the refusal is a config error.
load_config() {
  local edit="${1:-}" omarchy_path="${OMARCHY_UNDER_TEST:-$ROOT}" packaged_path="${PACKAGED_UNDER_TEST:-$packaged}"
  local home
  home=$(mktemp -d "$tmpdir/home.XXXXXX")

  mkdir -p "$home/.config"
  cp -R "$ROOT/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/input.lua"

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$omarchy_path" OMARCHY_PACKAGED_PATH="$packaged_path" \
    lua <<'LUA'
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
LUA
}

swipe="3 horizontal workspace"

[[ ! -e $ROOT/default/hypr/platform ]] || fail "Omarchy ships no platform defaults of its own"
[[ -z $(PACKAGED_UNDER_TEST=$ROOT load_config) ]] || fail "without a platform package there is no default gesture" "$(PACKAGED_UNDER_TEST=$ROOT load_config)"
pass "without a platform package, Omarchy adds no gesture"

# OMARCHY_PATH stays this checkout, as in a development setup, while the
# platform package's file sits only in the packaged tree.
[[ $(load_config) == "$swipe" ]] || fail "a platform package's default loads from the packaged tree" "$(load_config)"
pass "a platform package's defaults load from the packaged tree, whatever OMARCHY_PATH points at"

output=$(load_config 'hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })')
[[ $output == "$swipe" ]] || fail "the user's own gesture keeps the platform's out" "$output"
output=$(load_config 'hl.gesture({ fingers = 3, direction = "left", action = function() end })')
[[ $output == "3 left function" ]] || fail "a user gesture on the same axis keeps the platform's out" "$output"
output=$(load_config 'hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })')
[[ $output == $'4 horizontal workspace
'"$swipe" ]] || fail "a gesture on other fingers keeps the platform's" "$output"
output=$(load_config 'hl.gesture({ fingers = 3, direction = "horizontal", mods = "SUPER", action = "move" })')
[[ $output == $'3 horizontal +M move
'"$swipe" ]] || fail "a gesture held with a modifier keeps the platform's" "$output"
for mods in '"NONE"' '""'; do
  output=$(load_config 'hl.gesture({ fingers = 3, direction = "horizontal", mods = '"$mods"', action = "workspace" })')
  [[ $output == "$swipe" ]] || fail "mods = $mods counts as no modifier" "$output"
done
pass "platform defaults load after the user's files and see the user's gestures"

output=$(load_config 'fixture_gesture = false')
[[ -z $output ]] || fail "a setting in the user's files reaches the platform defaults" "$output"
pass "a setting in the user's files reaches the platform defaults"

# ── early defaults: binds ────────────────────────────────────────────────────

# A platform package's early defaults (default/hypr/platform/defaults) load
# before Omarchy's. This fixture binds a chord Omarchy leaves free, takes over
# one Omarchy binds, and decorates menu binds with a bind that must run first.
early="$tmpdir/early"
mkdir -p "$early/default/hypr/platform/defaults"
cat >"$early/default/hypr/platform/defaults/fixture-binds.lua" <<'LUA'
if _G.omarchy_default_bindings ~= false then
  o.bind("SUPER + F12", "Platform screenshot", "platform-screenshot")
  o.bind("shift + XF86MonBrightnessUp", "Platform brightness", "platform-brightness")
end
table.insert(o.bind_decorators, function(keys, dispatcher)
  if type(dispatcher) == "string" and dispatcher:find("^omarchy%-menu") then
    -- A decorator that binds through o.bind is not decorated again.
    o.bind("TWIN + " .. keys, "Platform menu twin", dispatcher)
    hl.bind(keys, "platform-focus", {})
  end
end)
LUA

# Prints one line per bind Hyprland ends up with, in the order they run:
# keys, then the command (or "platform-focus").
load_binds() {
  local edit="${1:-}" packaged_path="${PACKAGED_UNDER_TEST:-$early}" top="${2:-}"
  local home
  home=$(mktemp -d "$tmpdir/home.XXXXXX")

  mkdir -p "$home/.config"
  cp -R "$ROOT/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/bindings.lua"
  [[ -z $top ]] || printf '%s\n%s\n' "$top" "$(cat "$home/.config/hypr/hyprland.lua")" >"$home/.config/hypr/hyprland.lua"

  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" OMARCHY_PACKAGED_PATH="$packaged_path" \
    lua <<'LUA'
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

local binds = {}
hl = setmetatable({
  dsp = setmetatable({ exec_cmd = function(cmd) return { cmd = cmd } end }, { __index = function() return proxy() end }),
  bind = function(keys, dispatcher, opts)
    -- Only commands and decorator markers are compared; other dispatchers
    -- print by kind, not by their (per-run) address.
    local command = type(dispatcher) == "table" and dispatcher.cmd or type(dispatcher) == "string" and dispatcher or type(dispatcher)
    table.insert(binds, { keys = keys, command = command })
  end,
  -- Hyprland parses a chord into a modifier mask and a key, so spelling and
  -- modifier order don't matter to unbind.
  unbind = function(keys)
    local function parsed(value)
      local parts = {}
      for raw in (value .. "+"):gmatch("([^+]*)%+") do
        local part = raw:match("^%s*(.-)%s*$"):upper()
        if part ~= "" then table.insert(parts, part) end
      end
      local key = table.remove(parts) or ""
      table.sort(parts)
      return table.concat(parts, "+") .. "+" .. key
    end
    for index = #binds, 1, -1 do
      if parsed(binds[index].keys) == parsed(keys) then
        table.remove(binds, index)
      end
    end
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
for _, bind in ipairs(binds) do
  print(bind.keys .. "\t" .. tostring(bind.command))
end
LUA
}

plain=$(PACKAGED_UNDER_TEST=$ROOT load_binds) || fail "bindings load without a platform package" "$plain"
grep -qxF $'SHIFT + XF86MonBrightnessUp\tomarchy-brightness-display 100%' <<<"$plain" ||
  fail "without a platform package Omarchy's default binds as before" "$plain"
! grep -q 'platform-' <<<"$plain" || fail "without a platform package nothing platform binds" "$plain"
pass "without a platform package the default bindings are as before"

binds=$(load_binds) || fail "bindings load with platform defaults" "$binds"
grep -qxF $'SUPER + F12\tplatform-screenshot' <<<"$binds" || fail "a platform default binds a free chord" "$binds"
[[ $(grep -ci '^SHIFT + XF86MonBrightnessUp' <<<"$binds") == 1 ]] && grep -qxF $'shift + XF86MonBrightnessUp\tplatform-brightness' <<<"$binds" ||
  fail "a platform default replaces Omarchy's default for the same chord, however it is spelled" "$binds"
diff <(grep -v -e 'platform-' -e '^TWIN + ' <<<"$binds") <(grep -v '^SHIFT + XF86MonBrightnessUp' <<<"$plain") >"$tmpdir/bind-diff" ||
  fail "every other default bind is unchanged, in the same order" "$(cat "$tmpdir/bind-diff")"
pass "a platform's early defaults bind free chords and replace Omarchy's default for theirs"

[[ $(grep -A1 -xF $'SUPER + SPACE\tplatform-focus' <<<"$binds" | tail -n 1) == $'SUPER + SPACE\tomarchy-menu toggle' ]] ||
  fail "a decorator's bind runs right before the bind it decorates" "$binds"
! grep -qxF $'SUPER + RETURN\tplatform-focus' <<<"$binds" || fail "a decorator leaves other binds alone"
grep -qxF $'TWIN + SUPER + SPACE\tomarchy-menu toggle' <<<"$binds" && ! grep -qF 'TWIN + TWIN' <<<"$binds" ||
  fail "a bind a decorator makes through o.bind is not decorated again" "$binds"
pass "a platform decorator binds what must run first, right before the binds it picks"

user=$(load_binds 'o.rebind("SHIFT + XF86MonBrightnessUp", "Mine", "my-brightness")
hl.unbind("SUPER + F12")
o.bind("SUPER + ALT + M", "My menu", "omarchy-menu toggle")') || fail "user bindings load" "$user"
grep -qxF $'SHIFT + XF86MonBrightnessUp\tmy-brightness' <<<"$user" && ! grep -q 'platform-brightness' <<<"$user" ||
  fail "the user's rebind replaces the platform's" "$user"
! grep -q '^SUPER + F12' <<<"$user" || fail "the user can unbind a platform chord" "$user"
[[ $(grep -A1 -xF $'SUPER + ALT + M\tplatform-focus' <<<"$user" | tail -n 1) == $'SUPER + ALT + M\tomarchy-menu toggle' ]] ||
  fail "the user's own menu binds are decorated too" "$user"
pass "the user's files override platform defaults, and their binds are decorated too"

off=$(load_binds '' 'omarchy_default_bindings = false') || fail "bindings load with defaults off" "$off"
! grep -qE 'platform-(screenshot|brightness)|omarchy-brightness-display 100%' <<<"$off" ||
  fail "with default bindings off neither Omarchy's nor the platform's binds are made" "$off"
pass "with default bindings off, a platform file that honors it binds nothing"
