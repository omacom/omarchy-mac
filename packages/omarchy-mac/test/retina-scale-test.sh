#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
(( EUID != 0 )) || { pass 'fixture hardware roots are ignored as root'; exit 0; }
mkdir -p "$work/bin" "$work/proc/device-tree" "$work/sys/class/drm/card0-eDP-1"
cat > "$work/bin/omarchy-hw-apple-silicon" <<'STUB'
#!/bin/bash
[[ ${APPLE:-1} == "1" ]]
STUB
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH" HOME="$work/home" XDG_RUNTIME_DIR="$work/no-session"
export OMARCHY_PROC_ROOT="$work/proc" OMARCHY_SYS_ROOT="$work/sys"
export OMARCHY_PATH="$work/runtime"
mkdir -p "$OMARCHY_PATH/config/hypr"
cat > "$OMARCHY_PATH/config/hypr/monitors.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
LUA
unset XDG_CONFIG_HOME XDG_STATE_HOME
printf 'Apple MacBook Air (13-inch, M3, 2024)\0' > "$work/proc/device-tree/model"
printf 'connected\n' > "$work/sys/class/drm/card0-eDP-1/status"
helper="$work/root/usr/lib/omarchy-mac/retina-outputs"
[[ $("$helper") == "eDP-1" ]] || fail 'connected laptop eDP panel is selected'
[[ -z $(APPLE=0 "$helper") ]] || fail 'non-Apple platforms are excluded'
printf 'Apple Mac mini (M2, 2023)\0' > "$work/proc/device-tree/model"
[[ -z $("$helper") ]] || fail 'desktop models are excluded'
printf 'Apple MacBook Pro (16-inch, M3 Pro, 2023)\0' > "$work/proc/device-tree/model"
mkdir -p "$work/sys/class/drm/card1-DP-1"
printf 'connected\n' > "$work/sys/class/drm/card1-DP-1/status"
[[ $("$helper") == "eDP-1" ]] || fail 'external DP output is not selected'
printf 'disconnected\n' > "$work/sys/class/drm/card0-eDP-1/status"
[[ -z $("$helper") ]] || fail 'external-only configuration is unchanged'
printf 'connected\n' > "$work/sys/class/drm/card0-eDP-1/status"
pass 'panel selection excludes external, disconnected and non-laptop outputs'
mkdir -p "$work/sys/class/drm/card2-Unknown-1" "$work/sys/class/drm/card2/device/of_node" "$work/sys/bus/platform/drivers/simple-framebuffer"
ln -s "$work/sys/bus/platform/drivers/simple-framebuffer" "$work/sys/class/drm/card2/device/driver"
printf 'connected\n' > "$work/sys/class/drm/card2-Unknown-1/status"
printf 'apple,simple-framebuffer\0simple-framebuffer\0' > "$work/sys/class/drm/card2/device/of_node/compatible"
[[ $("$helper") == $'eDP-1\nUnknown-1' ]] || fail 'MacBook firmware output receives experimental default'
printf 'Apple Mac Studio (M2 Max, 2023)\0' > "$work/proc/device-tree/model"
[[ -z $("$helper") ]] || fail 'desktop framebuffer is excluded'
printf 'Apple MacBook Air (13-inch, M3, 2024)\0' > "$work/proc/device-tree/model"
printf 'disconnected\n' > "$work/sys/class/drm/card2-Unknown-1/status"
[[ $("$helper") == 'eDP-1' ]] || fail 'disconnected framebuffer is excluded'
printf 'connected\n' > "$work/sys/class/drm/card2-Unknown-1/status"
rm "$work/sys/class/drm/card2/device/driver"
ln -s "$work/sys/bus/platform/drivers/other" "$work/sys/class/drm/card2/device/driver"
[[ $("$helper") == 'eDP-1' ]] || fail 'unknown connector on another driver is excluded'
rm "$work/sys/class/drm/card2/device/driver"
ln -s "$work/sys/bus/platform/drivers/simple-framebuffer" "$work/sys/class/drm/card2/device/driver"
printf 'simple-framebuffer\0' > "$work/sys/class/drm/card2/device/of_node/compatible"
[[ $("$helper") == 'eDP-1' ]] || fail 'unidentified firmware framebuffer is excluded'
printf 'apple,simple-framebuffer\0simple-framebuffer\0' > "$work/sys/class/drm/card2/device/of_node/compatible"
pass 'simpledrm policy checks driver and Apple framebuffer identity without claiming internal detection'
monitors="$HOME/.config/hypr/monitors.lua"
marker="$HOME/.local/state/omarchy/mac-scale-configured"
mkdir -p "${monitors%/*}"
cp "$OMARCHY_PATH/config/hypr/monitors.lua" "$monitors"
env -u OMARCHY_PATH "$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
[[ ! -e $marker ]] || fail 'environment-less invocation must leave scaling pending'
cmp -s "$monitors" "$OMARCHY_PATH/config/hypr/monitors.lua" || fail 'environment-less invocation changed defaults'
"$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
lua - "$monitors" <<'LUA'
local rules = {}
hl = { monitor = function(rule) rules[rule.output] = rule.scale end, env = function() end }
dofile(arg[1])
assert(rules['eDP-1'] == 2)
assert(rules['Unknown-1'] == 2)
assert(rules[''] == 'auto')
assert(rules['DP-1'] == nil)
LUA
[[ -f $marker ]] || fail 'scale setup is recorded'
grep -q 'external/clamshell firmware boot' "$monitors" || fail 'experimental limitation missing'
cp "$monitors" "$work/once"
"$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
cmp -s "$monitors" "$work/once" || fail 'repeat setup changed scale config'
cp "$OMARCHY_PATH/config/hypr/monitors.lua" "$monitors"
"$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
cmp -s "$monitors" "$OMARCHY_PATH/config/hypr/monitors.lua" || fail 'removed rule was reinstated'
rm "$marker"
printf 'hl.monitor({ output = "", scale = 1.5 })\n' > "$monitors"
cp "$monitors" "$work/custom"
"$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
cmp -s "$monitors" "$work/custom" || fail 'existing user scale was changed'
rm "$marker" "$monitors"
ln -s "$work/once" "$monitors"
"$work/root/usr/bin/omarchy-mac-setup-user" "$work/root"
[[ -L $monitors && ! -e $marker ]] || fail 'user symlink was modified'
pass 'stock defaults gain a specific 2x rule; overrides, repeat setup and links are preserved'
