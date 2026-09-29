#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# A Danish Mac, from the vconsole.conf owner setup writes to the three places
# that read it: the Mac initramfs drop-ins that bundle it for the disk password
# prompt, the check that the built image carries it and what loads it, and the
# Hyprland input the desktop and its lock screen type with. The prompt (kbd
# KEYMAP on the console, XKB in Plymouth) and the desktop must end up on the
# same layout, since the disk password is also the login password.

require_command lua

tmpdir=$(mktemp -d)
unset LUA_INIT LUA_INIT_5_5 LUA_INIT_5_4
trap 'rm -rf "$tmpdir"' EXIT

# What systemd-firstboot --keymap=dk-latin1 writes (kbd-model-map's dk-latin1 row).
danish='KEYMAP=dk-latin1
XKBLAYOUT=dk
XKBMODEL=pc105
XKBOPTIONS=terminate:ctrl_alt_bksp'
printf '%s\n' "$danish" >"$tmpdir/vconsole.conf"

# Initramfs: the Mac chain over the stock HOOKS line, reading this vconsole.conf.
confd=$BOOT/files/etc/mkinitcpio.conf.d
mkdir -p "$tmpdir/confd"
for file in "$confd"/*.conf; do
  sed "s|/etc/vconsole.conf|$tmpdir/vconsole.conf|g" "$file" >"$tmpdir/confd/${file##*/}"
done
mapfile -t built < <(bash -c '
  HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
  FILES=()
  for file in "$1"/9*.conf; do source "$file"; done
  printf "%s\n" "${HOOKS[*]}" "${FILES[*]}"
' bash "$tmpdir/confd")
[[ ${built[0]} == *"keyboard sd-vconsole"* && ${built[0]} != *" keymap "* ]] ||
  fail "the Danish Mac image loads KEYMAP through sd-vconsole" "HOOKS=(${built[0]})"
[[ " ${built[1]} " == *" $tmpdir/vconsole.conf "* ]] ||
  fail "the Danish Mac image bundles vconsole.conf for Plymouth and sd-vconsole" "FILES=(${built[1]})"
pass "the Mac initramfs drop-ins bundle a Danish vconsole.conf and load its KEYMAP with sd-vconsole"

# The built image, as lsinitcpio -x lays it out: what sd-vconsole and the
# plymouth hook add for this vconsole.conf.
source "$BOOT/lib/boot-image-layout.sh"
image=$tmpdir/image
mkdir -p "$image/etc" "$image/usr/bin" "$image/usr/lib/systemd" \
  "$image/usr/share/kbd/keymaps/i386/qwerty" "$image/usr/share/X11/xkb/symbols"
cp "$tmpdir/vconsole.conf" "$image/etc/vconsole.conf"
: >"$image/usr/bin/loadkeys"
: >"$image/usr/bin/plymouthd"
: >"$image/usr/lib/systemd/systemd-vconsole-setup"
: >"$image/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz"
: >"$image/usr/share/X11/xkb/symbols/dk"
vconsole_layout_carried "$tmpdir/vconsole.conf" || fail "a Danish layout must be carried by the image"
boot_image_carries_vconsole "$image" "$tmpdir/vconsole.conf" || fail "the image carries the Danish vconsole.conf"
missing=$(boot_image_layout_missing "$image" "$tmpdir/vconsole.conf" 0)
[[ -z $missing ]] || fail "the image carries what loads the Danish layout" "$missing"
rm "$image/usr/share/kbd/keymaps/i386/qwerty/dk-latin1.map.gz" "$image/usr/share/X11/xkb/symbols/dk"
missing=$(boot_image_layout_missing "$image" "$tmpdir/vconsole.conf" 0)
[[ $missing == $'the dk-latin1 keymap\nthe XKB symbols for dk' ]] ||
  fail "an image without the dk-latin1 keymap or the dk symbols is caught" "$missing"
printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$image/etc/vconsole.conf"
! boot_image_carries_vconsole "$image" "$tmpdir/vconsole.conf" || fail "an image built with US is not the Danish one"
pass "the boot image check finds the Danish keymap and XKB symbols, and catches an image without them"

# Desktop: the shipped Hyprland config on a Mac, omarchy-mac staged, reading the
# same vconsole.conf. The XKB names Hyprland gets must be the ones Plymouth
# compiles from vconsole.conf (an empty model is XKB's default, pc105).
"$MAC/install" "$tmpdir/pkg" >/dev/null
mkdir -p "$tmpdir/apple-bin"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/apple-bin/omarchy-hw-apple-silicon"
chmod +x "$tmpdir/apple-bin/omarchy-hw-apple-silicon"
home=$tmpdir/home
mkdir -p "$home/.config"
cp -R "$ROOT/config/hypr" "$home/.config/hypr"
desktop=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" \
  OMARCHY_PACKAGED_PATH="$tmpdir/pkg/usr/share/omarchy" VCONSOLE="$tmpdir/vconsole.conf" \
  PATH="$tmpdir/apple-bin:$PATH" lua - <<'LUA'
local real_open = io.open
io.open = function(path, mode)
  if path == "/etc/vconsole.conf" then
    return real_open(os.getenv("VCONSOLE"), mode)
  end
  return real_open(path, mode)
end

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

local input = {}
local apple_settings = false
hl = setmetatable({
  dsp = proxy(),
  config = function(config)
    for _, key in ipairs({ "kb_layout", "kb_variant", "kb_model", "kb_options", "kb_rules", "kb_file" }) do
      if config.input and config.input[key] ~= nil then
        input[key] = config.input[key]
      end
    end
    -- Only omarchy-mac's settings turn tap-to-click off: proof they loaded.
    if config.input and config.input.touchpad and config.input.touchpad.tap_to_click == false then
      apple_settings = true
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
print(("apple=%s layout=%s variant=%s model=%s rules=%s file=%s"):format(tostring(apple_settings),
  input.kb_layout, input.kb_variant, input.kb_model, input.kb_rules, tostring(input.kb_file)))
LUA
)
[[ $desktop == "apple=true layout=dk variant= model= rules= file=nil" ]] ||
  fail "a Danish Mac's desktop types with the XKB layout its disk password prompt uses (dk, no variant, pc105)" "$desktop"
pass "a Danish Mac's desktop and lock screen use the dk layout its disk password prompt uses"
