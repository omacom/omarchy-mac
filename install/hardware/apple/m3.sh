# M3-generation Macs on the public Asahi kernel: the SoC boots, but the Asahi
# GPU driver does not know the M3 GPU (G15) yet and the display driver is not
# wired to the M3 device trees, so the desktop runs on the firmware framebuffer
# with Mesa's llvmpipe. Nothing here is M3-specific in the sense of packages:
# what this leaf does is record the state so the session config can adapt, and
# say so on the console, where the person installing can still read it.
#
# The record is the SoC command itself, run at session start
# (default/hypr/apple.lua): the day a kernel binds the GPU driver, the same
# check flips and the software-rendering settings drop away without a
# migration. This leaf exists for the parts that are not per-session.

omarchy-hw-apple-soc --is m3 >/dev/null 2>&1 || return 0

echo "Apple M3-generation SoC ($(omarchy-hw-apple-soc --codename)) detected."

if omarchy-hw-apple-soc --gpu; then
  echo "The Asahi GPU driver is bound; leaving rendering to it."
  return 0
fi

echo "No Asahi GPU driver for this SoC yet: Hyprland will render in software"
echo "(llvmpipe) on the firmware framebuffer. Expect no brightness control, no"
echo "external displays, and a slower desktop until Asahi ships M3 display and"
echo "GPU support. See docs/apple-m3.md."

# The firmware framebuffer runs at the panel's native resolution, and llvmpipe
# pays for every pixel. Halve the work by default; monitors.lua can raise it.
# Written as a Hyprland config include rather than a hyprland.lua edit, so the
# user's config stays theirs and the file is simply removable.
state_dir=/etc/omarchy
sudo mkdir -p "$state_dir"
printf 'soc=%s\ncodename=%s\ngpu=none\n' "$(omarchy-hw-apple-soc)" "$(omarchy-hw-apple-soc --codename)" |
  sudo tee "$state_dir/apple-soc" >/dev/null
