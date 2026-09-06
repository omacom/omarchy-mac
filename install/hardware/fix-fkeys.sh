# Prefer media keys on Apple-like keyboards, with Fn for F1-F12, the way macOS
# does. The Mac media bindings depend on it: default/hypr/bindings/media.lua
# binds bare XF86MonBrightness* and SHIFT+XF86MonBrightness*, so the top row has
# to emit media keycodes without Fn for display and keyboard brightness to work.
# hid_apple is the Apple keyboard driver. Writing this on a non-Apple x86
# machine is a Mac-fork leak. Apple Silicon uses fnmode=1; x86 machines that
# actually load hid_apple keep upstream's fnmode=2. Stock Arch kernels often
# *ship* the module, so modinfo is not evidence it is in use.
hid_apple_module="${OMARCHY_HID_APPLE_MODULE_PATH:-/sys/module/hid_apple}"
hid_apple_conf="${OMARCHY_HID_APPLE_CONF_PATH:-/etc/modprobe.d/hid_apple.conf}"
fnmode=""
if omarchy-hw-apple-silicon; then
  fnmode=1
elif [[ $(omarchy-hw-arch) == "x86_64" && -d $hid_apple_module ]]; then
  fnmode=2
fi

if [[ -n $fnmode && ! -f $hid_apple_conf ]]; then
  sudo mkdir -p "$(dirname "$hid_apple_conf")"
  echo "options hid_apple fnmode=$fnmode" | sudo tee "$hid_apple_conf" >/dev/null
fi
