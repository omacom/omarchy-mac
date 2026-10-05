# Device matching and measured fallback size for the Asahi MTP trackpad (#100).
#
# libinput's shipped [Apple Laptop Touchpad (MTP)] sets AttrSizeHint=104x75, a
# 13-inch pad. 14" and 16" Apple Silicon pads report their real size via udev
# (a 16-inch M2 Max is 157x96 mm). libinput uses AttrSizeHint only when the
# kernel does not report axis resolution; it does not change size math or
# palm rejection on an MTP pad that already reports that resolution.
#
# libinput reads /etc/libinput/local-overrides.quirks after its shipped quirks.
# Match without a vendor so the existing Apple palm-size and keyboard-integration
# quirks also apply to Asahi platform devices without ID_VENDOR. Measure the
# fallback size rather than copying the 13-inch hint; the palm-size thresholds
# are not retuned here. Keep administrator sections after our managed block:
# libinput uses the last matching value, so their overrides remain effective.

quirks_dir="${OMARCHY_LIBINPUT_QUIRKS_DIR:-/etc/libinput}"
input_root="${OMARCHY_INPUT_SYSFS:-/sys/class/input}"
compatible="${OMARCHY_APPLE_COMPATIBLE:-/proc/device-tree/compatible}"
arch="${OMARCHY_TEST_ARCH:-$(uname -m)}"

if [[ $arch == "aarch64" && -f $compatible ]] && grep -Faiq 'apple,' "$compatible"; then
  width=${OMARCHY_APPLE_MTP_WIDTH_MM:-}
  height=${OMARCHY_APPLE_MTP_HEIGHT_MM:-}

  if [[ -z $width || -z $height ]]; then
    # WIDTH_MM lives on the event node (eventN), not the parent inputN.
    for namefile in "$input_root"/event*/device/name; do
      [[ -r $namefile ]] || continue
      [[ $(<"$namefile") == "Apple MTP multi-touch" ]] || continue
      event=$(dirname "$(dirname "$namefile")")
      if command -v udevadm >/dev/null; then
        while IFS='=' read -r key value; do
          case $key in
            ID_INPUT_WIDTH_MM) width=$value ;;
            ID_INPUT_HEIGHT_MM) height=$value ;;
          esac
        done < <(udevadm info -q property -p "$event" 2>/dev/null || true)
      fi
      break
    done
  fi

  mkdir -p "$quirks_dir"
  managed_quirks=$({
    cat <<'EOF'
# BEGIN OMARCHY APPLE MTP QUIRKS
# Managed by install/hardware/apple/fix-mtp-trackpad.sh.
# Do not add MatchVendor: Asahi platform devices often have no ID_VENDOR.

[Omarchy Apple Laptop Keyboard (MTP)]
MatchUdevType=keyboard
MatchName=Apple MTP keyboard
AttrKeyboardIntegration=internal

[Omarchy Apple Laptop Touchpad (MTP)]
MatchUdevType=touchpad
MatchName=Apple MTP multi-touch
ModelAppleTouchpad=1
AttrTouchSizeRange=150:130
AttrPalmSizeThreshold=1600
EOF
    # Zero is not a valid libinput dimension and would disable all quirks.
    if [[ $width =~ ^[1-9][0-9]*$ && $height =~ ^[1-9][0-9]*$ ]]; then
      printf 'AttrSizeHint=%sx%s\n' "$width" "$height"
    fi
    printf '# END OMARCHY APPLE MTP QUIRKS\n'
  })

  python3 - "$quirks_dir/local-overrides.quirks" "$managed_quirks" <<'PY'
import os
from pathlib import Path
import stat
import sys
import tempfile

# Resolve an administrator's symlink, preserving both the link and target mode.
path = Path(sys.argv[1]).resolve()
try:
  original = path.read_bytes()
  original_stat = path.stat()
except FileNotFoundError:
  original = b""
  original_stat = None

begin = b"# BEGIN OMARCHY APPLE MTP QUIRKS"
end = b"# END OMARCHY APPLE MTP QUIRKS"
inside = False
seen = False
retained = []
for line in original.splitlines(keepends=True):
  marker = line.rstrip(b"\r\n")
  if marker == begin:
    if inside or seen:
      sys.exit(f"Refusing to replace ambiguous Omarchy MTP markers in {path}")
    inside = seen = True
  elif marker == end:
    if not inside:
      sys.exit(f"Refusing to replace unmatched Omarchy MTP marker in {path}")
    inside = False
  elif not inside:
    retained.append(line)
if inside:
  sys.exit(f"Refusing to replace unterminated Omarchy MTP block in {path}")

updated = sys.argv[2].encode() + b"\n" + b"".join(retained)
if updated != original:
  fd, temporary = tempfile.mkstemp(prefix=".omarchy-apple-mtp-", dir=path.parent)
  try:
    with os.fdopen(fd, "wb") as output:
      if original_stat:
        os.fchown(output.fileno(), original_stat.st_uid, original_stat.st_gid)
        os.fchmod(output.fileno(), stat.S_IMODE(original_stat.st_mode))
      else:
        os.fchmod(output.fileno(), 0o644)
      output.write(updated)
    os.replace(temporary, path)
  finally:
    if os.path.exists(temporary):
      os.unlink(temporary)
PY
fi
