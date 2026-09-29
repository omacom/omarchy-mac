#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

require_command lua
require_command node

# omarchy-mac fills Omarchy's platform hooks with the Mac's defaults: early
# Hyprland defaults (lid switch, capture chords, Shift+brightness on the
# keyboard backlight, menus on the built-in screen), settings (the trackpad),
# the keybindings menu's key names and the notch the bar keeps clear of. The
# runtime carries none of them. OMARCHY_TEST_RUNTIME points the test at another
# runtime layout (an upstream checkout with the same hooks) to show the package
# behaves the same.

tmpdir=$(mktemp -d)
# A versioned LUA_INIT would take precedence over the platform root seam.
unset LUA_INIT LUA_INIT_5_5 LUA_INIT_5_4
trap 'rm -rf "$tmpdir"' EXIT
runtime=${OMARCHY_TEST_RUNTIME:-$ROOT}
"$MAC/install" "$tmpdir/pkg" >/dev/null
packaged=$tmpdir/pkg
platform_root=$packaged/usr/share/omarchy-platform

# A runtime with the fixed platform root reads omarchy-mac's files from
# /usr/share/omarchy-platform, which its test seam (platform-root.lua through
# LUA_INIT) moves to a staged root; an older runtime reads the copies omarchy-mac
# also stages in its tree, through OMARCHY_PACKAGED_PATH.
if [[ -f $runtime/test/shell.d/platform-root.lua ]]; then
  platform_env() { printf '%s\n' "LUA_INIT=@$runtime/test/shell.d/platform-root.lua" "OMARCHY_TEST_PLATFORM_ROOT=$1/usr/share/omarchy-platform"; }
  key_names_path=/usr/share/omarchy-platform/key-names
else
  platform_env() { printf '%s\n' "OMARCHY_PACKAGED_PATH=$1/usr/share/omarchy"; }
  key_names_path=default/omarchy/platform/key-names
fi

mkdir -p "$tmpdir/apple-bin" "$tmpdir/other-bin"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/omarchy-hw-apple-silicon"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/other-bin/omarchy-hw-apple-silicon"
chmod +x "$tmpdir"/*-bin/omarchy-hw-apple-silicon

# Loads the runtime's hyprland.lua against a user's ~/.config/hypr and prints
# every bind ("bind<TAB>keys<TAB>command", "global <name>" for the shell's
# global shortcut, or "focus <keyboards>" for a bind scoped to keyboards), every
# device setting ("device<TAB>name") and every global tap-to-click setting
# ("tap_to_click<TAB>value").
load_config() {
  local platform=$1 staged=${2:-$packaged} edit=${3:-} home platform_vars
  mapfile -t platform_vars < <(platform_env "$staged")
  home=$(mktemp -d "$tmpdir/home.XXXXXX")
  mkdir -p "$home/.config"
  cp -R "$runtime/config/hypr" "$home/.config/hypr"
  [[ -z $edit ]] || printf '%s\n' "$edit" >>"$home/.config/hypr/input.lua"
  [[ -z ${NO_DEFAULT_BINDINGS:-} ]] || sed -i 's/^-- omarchy_default_bindings = false$/omarchy_default_bindings = false/' "$home/.config/hypr/hyprland.lua"
  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$runtime" \
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

local dsp = proxy()
rawset(dsp, "exec_cmd", function(cmd) return { cmd = cmd } end)
rawset(dsp, "global", function(name) return { cmd = "global " .. name } end)

hl = setmetatable({
  dsp = dsp,
  bind = function(keys, dispatcher, opts)
    if opts and opts.device then
      print("bind\t" .. keys .. "\tfocus " .. table.concat(opts.device.list, ","))
    elseif type(dispatcher) == "table" and dispatcher.cmd then
      print("bind\t" .. keys .. "\t" .. dispatcher.cmd)
    else
      print("bind\t" .. keys .. "\tother")
    end
  end,
  unbind = function(keys) print("unbind\t" .. keys) end,
  device = function(device) print("device\t" .. device.name) end,
  config = function(config)
    local touchpad = config.input and config.input.touchpad
    if touchpad and touchpad.tap_to_click ~= nil then
      print("tap_to_click\t" .. tostring(touchpad.tap_to_click))
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
LUA
}

apple=$(load_config apple) || fail "the config loads on a Mac with omarchy-mac" "$apple"
other=$(load_config other) || fail "the config loads elsewhere with omarchy-mac on disk" "$other"
bare=$(load_config apple "$tmpdir/none") || fail "the config loads on a Mac without omarchy-mac" "$bare"

bound() { grep -Fxq "bind"$'\t'"$2"$'\t'"$3" <<<"$1"; }

lid_on=("switch:on:Apple SMC power/lid events" "omarchy-system-lid-close")
lid_off=("switch:off:Apple SMC power/lid events" "omarchy-hyprland-monitor-clamshell")
captures=("SUPER + F12|omarchy-capture-screenshot fullscreen" "SUPER + F11|omarchy-capture-screenshot region"
  "SUPER + F10|omarchy-capture-screenshot windows" "SUPER + XF86AudioMute|omarchy-capture-screenshot windows"
  "SUPER + XF86AudioLowerVolume|omarchy-capture-screenshot region" "SUPER + XF86AudioRaiseVolume|omarchy-capture-screenshot fullscreen")

bound "$apple" "${lid_on[@]}" && bound "$apple" "${lid_off[@]}" || fail "a Mac binds its SMC lid switch" "$apple"
for capture in "${captures[@]}"; do
  bound "$apple" "${capture%%|*}" "${capture#*|}" || fail "a Mac binds ${capture%%|*} to capture" "$apple"
done
! grep -q $'^bind\tSUPER + ALT + F12\t' <<<"$apple" || fail "Super+Alt+F12 stays unbound" "$apple"
bound "$apple" "SHIFT + XF86MonBrightnessUp" "omarchy-brightness-keyboard up" &&
  bound "$apple" "SHIFT + XF86MonBrightnessDown" "omarchy-brightness-keyboard down" ||
  fail "Shift+brightness drives a Mac's keyboard backlight" "$apple"
(( $(grep -c $'^bind\tSHIFT + XF86MonBrightnessUp\t' <<<"$apple") == 1 )) ||
  fail "the Mac's Shift+brightness replaces Omarchy's display maximum instead of joining it" "$apple"
# A runtime with the settings slot loads settings/apple.lua itself; an older
# one gets it through defaults/apple.lua. Either way tapping is turned off once,
# globally, and no device setting outranks the user's global one.
[[ $(grep '^tap_to_click' <<<"$apple") == $'tap_to_click\tfalse' ]] ||
  fail "a Mac's touchpads do not tap to click, set once" "$apple"
! grep -q '^device' <<<"$apple" || fail "the Mac sets no per-device value the user's global one could not replace" "$apple"
if [[ -f $runtime/default/hypr/platform.lua ]]; then
  trackpad_line=$(grep -n '^tap_to_click' <<<"$apple" | cut -d: -f1)
  terminal_line=$(grep -n $'^bind\tSUPER + RETURN\t' <<<"$apple" | cut -d: -f1)
  [[ -n $trackpad_line && -n $terminal_line ]] && (( trackpad_line > terminal_line )) ||
    fail "with the settings slot, the Mac's trackpad settings follow Omarchy's defaults" "$apple"
fi
pass "a Mac gets its lid switch, capture chords, keyboard backlight chords and trackpad from omarchy-mac"

tapping=$(load_config apple "$packaged" 'hl.config({ input = { touchpad = { tap_to_click = true } } })') ||
  fail "the config loads with the user's tap-to-click" "$tapping"
[[ $(grep '^tap_to_click' <<<"$tapping") == $'tap_to_click\tfalse\ntap_to_click\ttrue' ]] ||
  fail "the user's global tap_to_click = true in input.lua comes after the Mac's and wins" "$tapping"
pass "the user's input.lua replaces the Mac's trackpad settings"

for output in "$other" "$bare"; do
  ! grep -q 'Apple SMC\|omarchy-capture-screenshot \(fullscreen\|region\|windows\)$\|SHIFT + XF86MonBrightness.*brightness-keyboard\|^device\|^tap_to_click\|focus apple' <<<"$output" ||
    fail "no Mac default without a Mac or without omarchy-mac" "$output"
  bound "$output" "SHIFT + XF86MonBrightnessUp" "omarchy-brightness-display 100%" || fail "Omarchy's Shift+brightness stays elsewhere" "$output"
  bound "$output" "PRINT" "omarchy-capture-screenshot" || fail "Omarchy's own capture bind stays" "$output"
done
pass "off a Mac, or on a Mac without omarchy-mac, the runtime alone adds nothing of the Mac's"

keyboards="apple-spi-keyboard,apple-mtp-keyboard"
# The runtime binds a menu or panel as a command, or (a runtime whose
# bindings say { menu = ... } and whose shell registers the shortcut) as the
# shell's global shortcut; either comes right after the focus bind.
focus_then() {
  local keys=$1 command
  shift
  for command in "$@"; do
    [[ $'\n'"$apple"$'\n' == *$'\nbind\t'"$keys"$'\tfocus '"$keyboards"$'\nbind\t'"$keys"$'\t'"$command"$'\n'* ]] && return
  done
  fail "$keys focuses the built-in screen first when typed on the MacBook keyboard" "$apple"
}
focus_then "SUPER + SPACE" "omarchy-menu toggle" "global omarchy:menu.root"
focus_then "SUPER + ESCAPE" "omarchy-menu toggle system" "global omarchy:menu.system"
focus_then "SUPER + K" "omarchy-menu-keybindings"
focus_then "SUPER + CTRL + A" "omarchy-shell shell toggle omarchy.audio" "global omarchy:panel.omarchy.audio"
focus_then "SUPER + CTRL + code:10" "omarchy-shell -q shell togglePanelAt right 1"
for keys in "SUPER + RETURN" "SUPER + CTRL + E" "SUPER + CTRL + V" "PRINT" "SUPER + F12" "SUPER + 1"; do
  ! grep -qxF "bind"$'\t'"$keys"$'\tfocus '"$keyboards" <<<"$apple" || fail "$keys keeps today's focus" "$apple"
done
pass "menus and panels typed on the MacBook keyboard focus its screen first; apps, pasting pickers and captures don't"

# A user's rebind goes through the same decoration: a menu keeps the focus
# bind, an app gets none.
rebinds=$(load_config apple "$packaged" $'o.rebind("SUPER + ESCAPE", "System menu", "omarchy-menu toggle system")\no.rebind("SUPER + SHIFT + F", "File manager", "uwsm-app -- flea")') ||
  fail "the config loads with the user's rebinds" "$rebinds"
[[ $rebinds == *$'unbind\tSUPER + ESCAPE\nbind\tSUPER + ESCAPE\tfocus '"$keyboards"$'\nbind\tSUPER + ESCAPE\tomarchy-menu toggle system'* ]] ||
  fail "rebinding a menu keeps the built-in screen focus" "$rebinds"
[[ $rebinds == *$'unbind\tSUPER + SHIFT + F\nbind\tSUPER + SHIFT + F\tuwsm-app -- flea'* ]] ||
  fail "rebinding an app opens it on the focused screen" "$rebinds"
pass "the user's rebinds keep the menu and app split"

grep -qx -- '-- omarchy_default_bindings = false' "$runtime/config/hypr/hyprland.lua" || fail "hyprland.lua documents the default bindings switch"
nodefaults=$(NO_DEFAULT_BINDINGS=1 load_config apple) || fail "the config loads without default bindings" "$nodefaults"
! grep -q 'Apple SMC\|SUPER + F12' <<<"$nodefaults" || fail "omarchy_default_bindings = false drops the Mac's binds too" "$nodefaults"
pass "omarchy_default_bindings = false turns the Mac's binds off with Omarchy's"

# The keybindings menu shows the brightness keys as the F1 and F2 they are.
[[ $(<"$platform_root/key-names") == $'XF86MonBrightnessUp F2\nXF86MonBrightnessDown F1' ]] ||
  fail "omarchy-mac names the brightness keys F2 and F1"
grep -Fq "$key_names_path" "$runtime/bin/omarchy-menu-keybindings" || fail "the keybindings menu reads the platform's key names"
pass "the keybindings menu names the Mac's brightness keys as its F-keys"

# The bar keeps clear of each MacBook panel's notch.
CUTOUTS="$platform_root/display-cutouts.json" RUNTIME="$runtime" node <<'JS'
const fs = require('fs')
const model = require(process.env.RUNTIME + '/shell/plugins/bar/BarModel.js')
const cutouts = model.parseCutouts(fs.readFileSync(process.env.CUTOUTS, 'utf8'))
const expect = (ok, what) => { if (!ok) { console.error('not ok - ' + what); process.exit(1) } }
expect(cutouts.length === 4, 'four MacBook panels')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1728, 1117, 2, 0) === 32, '16" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1512, 982, 2, 0) === 32, '14" MacBook Pro at scale 2: 32 px')
expect(model.notchFloor(cutouts, 'top', 'eDP-1', 1280, 832, 2, 0) === 28, 'MacBook Air 13.6" at scale 2: 28 px')
expect(model.notchFloor(cutouts, 'top', 'DP-1', 1728, 1117, 2, 0) === 0, 'external monitors keep no floor')
expect(model.notchFloor(cutouts, 'bottom', 'eDP-1', 1728, 1117, 2, 0) === 0, 'a bottom bar keeps no floor')
expect(model.centerBesideRight(cutouts, 'top', 'eDP-1', 1728, 1117, 2), 'the center section moves beside the right')
JS
pass "the bar keeps clear of the notch on every MacBook panel omarchy-mac describes"

# The focus bind moves to the built-in screen only when another screen has it.
focus_with() {
  PATH="$tmpdir/apple-bin:$PATH" lua - "$platform_root/hypr/defaults/apple.lua" "$1" <<'LUA'
local file, layout = arg[1], arg[2]
local focus
hl = {
  dsp = { focus = function(args) return args end, exec_cmd = function(cmd) return cmd end },
  dispatch = function(dispatcher) print("focus " .. dispatcher.monitor) end,
  device = function() end,
  config = function() end,
  bind = function(_, dispatcher, opts) if opts and opts.device then focus = dispatcher end end,
  get_monitors = function()
    local monitors = {}
    for name, focused in layout:gmatch("([%w%-]+)(%*?)") do
      monitors[#monitors + 1] = { name = name, focused = focused == "*" }
    end
    return monitors
  end,
}
o = { bind_decorators = {}, bind = function() end, shell_succeeds = function() return true end }
_G.omarchy_default_bindings = false
dofile(file)
o.bind_decorators[1]("SUPER + SPACE", "omarchy-menu toggle", {})
focus()
print("done")
LUA
}
[[ $(focus_with "DP-1* eDP-1") == $'focus eDP-1\ndone' ]] || fail "focus moves to the built-in screen from an external one"
[[ $(focus_with "DP-1 eDP-1*") == "done" ]] || fail "focus stays when the built-in screen already has it"
[[ $(focus_with "DP-1* HDMI-A-1") == "done" ]] || fail "clamshell: no built-in screen, focus stays"
[[ $(focus_with "eDP-1*") == "done" ]] || fail "built-in screen alone: nothing to do"
pass "the built-in screen focus handles external, built-in only and clamshell layouts"

# The decorator reads the command a bind runs: the dispatcher itself when it is
# one, or the command Omarchy passes fourth when the bind reaches the shell
# through its global shortcut.
decorated() {
  PATH="$tmpdir/apple-bin:$PATH" lua - "$platform_root/hypr/defaults/apple.lua" "$@" <<'LUA'
local file, dispatcher, command = arg[1], arg[2], arg[3]
hl = { device = function() end, config = function() end, bind = function(_, _, opts) if opts and opts.device then print("focus") end end }
o = { bind_decorators = {}, bind = function() end, shell_succeeds = function() return true end }
_G.omarchy_default_bindings = false
dofile(file)
if dispatcher == "global" then
  dispatcher = { global = "omarchy:shortcut" }
end
o.bind_decorators[1]("SUPER + X", dispatcher, {}, command)
LUA
}
[[ $(decorated "omarchy-menu toggle root") == "focus" ]] || fail "a menu command gets the focus bind"
[[ $(decorated global "omarchy-menu toggle 'root'") == "focus" ]] || fail "a menu reached through the shell's shortcut gets the focus bind"
[[ $(decorated "omarchy-menu toggle 'root'" "omarchy-menu toggle 'root'") == "focus" ]] || fail "a menu command passed twice gets the focus bind"
[[ $(decorated global "omarchy-shell shell toggle 'omarchy.audio'") == "focus" ]] || fail "a panel reached through the shell's shortcut gets the focus bind"
[[ -z $(decorated global "omarchy-shell shell toggle 'omarchy.emojis'") ]] || fail "the emoji picker reached through the shortcut keeps today's focus"
[[ -z $(decorated global "omarchy-shell shell toggle 'omarchy.clipboard'") ]] || fail "the clipboard reached through the shortcut keeps today's focus"
[[ -z $(decorated "omarchy-shell shell toggle omarchy.emojis") ]] || fail "the emoji picker command keeps today's focus"
[[ -z $(decorated global "omarchy-launch-browser") ]] || fail "an app keeps today's focus"
[[ -z $(decorated global) ]] || fail "an opaque dispatcher with no command keeps today's focus"
pass "the focus bind follows the command a bind runs, whether it is the dispatcher or passed alongside it"

# The built-in panel's backlight is the Retina panel's, never the Touch Bar's:
# an older runtime knows that itself, one with the platform root reads it from
# omarchy-mac's displays.conf. The copy reads a staged root in place of the
# fixed one.
backlights=$tmpdir/backlight
mkdir -p "$backlights/display-pipe" "$backlights/228600000.dsi.0" "$backlights/apple-panel-bl"
pick() {
  sed "s|/usr/share/omarchy-platform|$1|g" "$runtime/bin/omarchy-hw-display" >"$tmpdir/omarchy-hw-display"
  OMARCHY_BACKLIGHT_PATH=$backlights bash "$tmpdir/omarchy-hw-display"
}
[[ $(pick "$platform_root") == apple-panel-bl ]] || fail "a Mac's panel backlight is apple-panel-bl" "$(pick "$platform_root")"
if grep -qF /usr/share/omarchy-platform "$runtime/bin/omarchy-hw-display"; then
  [[ $(pick "$tmpdir/none") != apple-panel-bl ]] || fail "the runtime alone knows no Mac backlight; displays.conf names it"
fi
rmdir "$backlights/apple-panel-bl"
! pick "$platform_root" >/dev/null || fail "a Touch Bar backlight never stands in for the panel's" "$(pick "$platform_root")"
pass "a Mac dims its Retina panel, never the Touch Bar"

# An external monitor on a Mac is probed over DDC only when its connector has a
# ddc node: an older runtime decides that itself, one with the platform root
# from displays.conf. The copy reads a staged root and DRM class.
mkdir -p "$tmpdir/ddc-bin"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/ddc-bin/omarchy-hyprland-monitor-focused-apple"
printf '#!/bin/sh\necho "ddcutil $*" >>"$DDC_LOG"\nexit 1\n' >"$tmpdir/ddc-bin/ddcutil"
chmod +x "$tmpdir/ddc-bin/"*
probes_ddc() {
  local copy=$tmpdir/omarchy-brightness-display run
  sed -e "s|/usr/share/omarchy-platform|$1|g" -e "s|/sys/class/drm|$tmpdir/drm|g" "$runtime/bin/omarchy-brightness-display" >"$copy"
  run=$(mktemp -d "$tmpdir/run.XXXXXX")
  DDC_LOG=$run/ddc.log XDG_RUNTIME_DIR=$run PATH="$tmpdir/ddc-bin:$tmpdir/apple-bin:$runtime/bin:$PATH" bash "$copy" --monitor DP-1 >/dev/null 2>&1 || true
  [[ -s $run/ddc.log ]]
}
mkdir -p "$tmpdir/drm"
! probes_ddc "$platform_root" || fail "a Mac's monitor without a ddc node is not probed over DDC"
mkdir -p "$tmpdir/drm/card0-DP-1/ddc"
probes_ddc "$platform_root" || fail "a Mac's monitor with a ddc node is probed over DDC"
rm -r "$tmpdir/drm/card0-DP-1"
if grep -qF /usr/share/omarchy-platform "$runtime/bin/omarchy-brightness-display"; then
  probes_ddc "$tmpdir/none" || fail "the runtime alone probes every external monitor; displays.conf limits it"
fi
pass "a Mac probes an external monitor over DDC only where its connector has a ddc node"
