# Hardware video decode on Apple Silicon needs avd-fw from Asahi ALARM and
# libva-v4l2_request-avd from [omarchy]. Images install both from
# install/omarchy-apple.packages; this leaf covers installs made before that.
#
# The kernel already has the driver: CONFIG_VIDEO_APPLE_AVD=m, and it autoloads
# and autoprobes on its own. What it does not have is firmware. Asahi wrote a
# clean MIT-licensed replacement for the Apple Video Decoder rather than
# extracting Apple's, packaged as avd-fw. Without it the driver gives up at
# probe, asking for the blob that matches the SoC (an M2 Max here):
#
#   avd 287080000.avd: Direct firmware load for apple/avd-fw-v3-t1.bin failed with error -2
#   avd 287080000.avd: probe with driver avd failed with error -2
#
# avd-fw supplies every SoC's blob and the decoder appears as a /dev/video*
# device.
#
# Firmware alone is not enough to be useful. AVD is a *stateless* decoder,
# which almost nothing on the desktop speaks -- ffmpeg's v4l2m2m decoders are
# stateful and will never negotiate with it. libva-v4l2_request-avd is the
# VA-API translation layer that bridges the two, and it installs itself as
# asahi_drv_video.so, which is the name libva derives from the DRM render node
# here, so applications find the decoder with no environment variable set.
#
# What this buys: about 84% less CPU time spent decoding. The power saving is
# real but modest -- roughly 0.2 W off a machine drawing about 7.8 W during
# playback. mpv, ffmpeg and GStreamer benefit. Arch Linux ARM's Chromium has
# VA-API compiled out, but Chromium-family builds that keep it, such as Brave,
# render green frames through this driver, so the browser-video-decode user
# leaf turns decode off in their flags.
#
# The decoder only probes at boot, so nothing here rebinds it: the reboot that
# follows setup is what brings it up. The migration that reuses this leaf on an
# existing install asks for that reboot, which is what the changed flag is for.

OMARCHY_AVD_PACKAGES_CHANGED=0

# aarch64 is not enough: a Raspberry Pi must not get the Asahi video stack.
omarchy-hw-apple-silicon || return 0

if omarchy-pkg-missing avd-fw libva-v4l2_request-avd; then
  echo "Installing Apple Silicon hardware video decode"
  omarchy-pkg-add avd-fw libva-v4l2_request-avd ||
    echo "Warning: hardware video decode packages could not be installed; video decodes in software."

  # A warning rather than a failure: hardware setup runs under set -e, and
  # software decode is a working fallback, not a broken machine.
  if omarchy-pkg-present avd-fw libva-v4l2_request-avd; then
    OMARCHY_AVD_PACKAGES_CHANGED=1
  else
    echo "Warning: the hardware video decode stack is incomplete; video decodes in software." >&2
  fi
fi
