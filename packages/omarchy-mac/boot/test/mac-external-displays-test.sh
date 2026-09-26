#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# While the boot splash runs on a laptop's built-in screen, the Apple display
# card's external connectors are held off; they come on for the desktop.
FILES=$ROOT/files
SCRIPT=$FILES/usr/lib/omarchy/mac-boot/external-displays
RULES=$FILES/usr/lib/udev/rules.d/70-omarchy-mac-external-displays.rules
UNIT=$FILES/usr/lib/systemd/system/omarchy-mac-external-displays.service

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# An M2 Max: the built-in panel, HDMI and three USB-C ports on card2, the
# boot framebuffer on card0.
new_mac() {
  sys=$tmp/sys
  rm -rf "$sys" "$tmp/run" "$tmp/bin"
  local connector
  for connector in card2-eDP-1 card2-HDMI-A-1 card2-USB-1 card2-USB-2 card2-USB-3 card0-Unknown-1; do
    mkdir -p "$sys/class/drm/$connector"
    : >"$sys/class/drm/$connector/status"
  done
  mkdir -p "$sys/class/drm/card2" "$sys/firmware/devicetree/base"
  : >"$sys/class/drm/card2/uevent"
  printf 'laptop\0' >"$sys/firmware/devicetree/base/chassis-type"
  echo 01234567-89ab-cdef-0123-456789abcdef >"$tmp/uuid"
  mkdir -p "$tmp/bin"
  printf '#!/bin/bash\n[[ -e %q ]]\n' "$tmp/splash" >"$tmp/bin/plymouth"
  printf '#!/bin/bash\necho "$*" >>%q\ncat %q\n' "$tmp/busctl.log" "$tmp/lid" >"$tmp/bin/busctl"
  chmod +x "$tmp/bin/plymouth" "$tmp/bin/busctl"
  rm -f "$tmp/busctl.log"
  : >"$tmp/splash"
  echo "b false" >"$tmp/lid"
}

displays() {
  OMARCHY_SYSFS=$sys OMARCHY_MAC_DISPLAYS_STATE=$tmp/run OMARCHY_UUID_SOURCE=$tmp/uuid \
    OMARCHY_PLYMOUTH=$tmp/bin/plymouth OMARCHY_BUSCTL=$tmp/bin/busctl bash "$SCRIPT" "$@"
}

status() { cat "$sys/class/drm/$1/status"; }
externals() { printf '%s ' "$(status card2-HDMI-A-1)" "$(status card2-USB-1)" "$(status card2-USB-2)" "$(status card2-USB-3)"; }
untouched() { [[ -z $(status card2-eDP-1) && -z $(status card0-Unknown-1) ]]; }

# ── hold ───────────────────────────────────────────────────────────────────
new_mac
displays hold card2 || fail "hold succeeds"
[[ $(externals) == "off off off off " ]] || fail "an open laptop under the splash holds every external connector off: $(externals)"
untouched || fail "the built-in panel and other cards are never held"
[[ $(<"$tmp/run/external-displays-held") == $'card2-HDMI-A-1\ncard2-USB-1\ncard2-USB-2\ncard2-USB-3' ]] ||
  fail "hold records what it held: $(cat "$tmp/run/external-displays-held")"
grep -Fxq -- '--timeout=2 get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed' "$tmp/busctl.log" ||
  fail "the lid comes from logind, bounded: $(cat "$tmp/busctl.log")"
displays hold card2 && (( $(wc -l <"$tmp/run/external-displays-held") == 4 )) || fail "a replayed add holds nothing twice"
pass "an open laptop under the splash holds its external displays off"

for case in shut unknown desktop no-chassis no-splash released no-panel bad-name; do
  new_mac
  card=card2
  case $case in
    shut) echo "b true" >"$tmp/lid" ;;
    unknown) : >"$tmp/lid" ;;
    desktop) printf 'desktop\0' >"$sys/firmware/devicetree/base/chassis-type" ;;
    no-chassis) rm "$sys/firmware/devicetree/base/chassis-type" ;;
    no-splash) rm "$tmp/splash" ;;
    released) mkdir -p "$tmp/run" && : >"$tmp/run/external-displays-released" ;;
    no-panel) rm -r "$sys/class/drm/card2-eDP-1" ;;
    bad-name) card='card2;rm' ;;
  esac
  displays hold "$card" || fail "hold succeeds ($case)"
  [[ $(externals) == "    " && ! -s $tmp/run/external-displays-held ]] || fail "hold changes nothing ($case): $(externals)"
done
pass "a shut or unknown lid, a desktop Mac, no splash, a finished splash or no built-in panel holds nothing"

# ── release ────────────────────────────────────────────────────────────────
new_mac
displays hold card2
echo detect-by-owner >"$sys/class/drm/card0-Unknown-1/status"
displays release >"$tmp/out" || fail "release succeeds"
[[ $(externals) == "detect detect detect detect " ]] || fail "release turns every held connector back on: $(externals)"
[[ -z $(status card2-eDP-1) && $(status card0-Unknown-1) == detect-by-owner ]] || fail "release touches only what hold held"
[[ $(<"$sys/class/drm/card2/uevent") == "change 01234567-89ab-cdef-0123-456789abcdef OMARCHYMACDISPLAYS=1" ]] ||
  fail "release sends the card one synthetic change: $(cat "$sys/class/drm/card2/uevent")"
[[ $(sed -n 's/^change [^ ]* //p' "$sys/class/drm/card2/uevent") =~ ^[A-Za-z0-9]+=[A-Za-z0-9]+$ ]] ||
  fail "the synthetic uevent's argument is alphanumeric, or the kernel refuses it"
[[ -e $tmp/run/external-displays-released && ! -e $tmp/run/external-displays-held ]] || fail "release marks the splash over"
grep -Fxq 'omarchy-mac-external-displays: turned the external displays on card2 back on' "$tmp/out" || fail "release logs what it did"
displays hold card2 && [[ $(externals) == "detect detect detect detect " ]] || fail "a card that appears after the release is not held"
pass "release turns the held displays on and hotplugs their card"

new_mac
displays release >/dev/null && [[ ! -s $sys/class/drm/card2/uevent && -e $tmp/run/external-displays-released ]] ||
  fail "release without anything held only marks the splash over"
new_mac
displays hold card2
chmod a-w "$sys/class/drm/card2-USB-2/status"
if displays release >/dev/null 2>"$tmp/err"; then fail "a connector that cannot be turned on fails the release"; fi
[[ $(externals) == "detect detect off detect " ]] || fail "the other connectors are still turned on: $(externals)"
[[ $(<"$tmp/run/external-displays-held") == card2-USB-2 ]] || fail "the connector stays held for a restart of the unit"
grep -Fq 'could not turn card2-USB-2 back on' "$tmp/err" || fail "the failure names the connector"
chmod u+w "$sys/class/drm/card2-USB-2/status"
displays release >/dev/null && [[ $(externals) == "detect detect detect detect " && ! -e $tmp/run/external-displays-held ]] ||
  fail "a restart turns the rest on"
new_mac
displays hold card2
rm -r "$sys/class/drm/card2"
if displays release >/dev/null 2>"$tmp/err"; then fail "a card that cannot be signalled fails the release"; fi
[[ $(externals) == "detect detect detect detect " ]] || fail "the connectors are still turned on"
grep -Fq 'could not signal card2' "$tmp/err" || fail "the failure names the card"
pass "release reports what it could not do"

# ── wiring ─────────────────────────────────────────────────────────────────
[[ -x $SCRIPT ]] && bash -n "$SCRIPT" || fail "the script is executable and parses"
grep -Fxq 'ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="apple-drm", RUN+="/usr/lib/omarchy/mac-boot/external-displays hold %k"' "$RULES" ||
  fail "the Apple display card is held as it appears"
grep -Fxq 'ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{SYNTH_ARG_OMARCHYMACDISPLAYS}=="1", ENV{HOTPLUG}="1"' "$RULES" ||
  fail "the release's synthetic change is a hotplug (aquamarine rescans on HOTPLUG=1 only)"
grep -Fxq 'After=plymouth-quit.service plymouth-quit-wait.service' "$UNIT" || fail "the release waits for the splash, which first boot holds"
grep -Fxq 'Before=display-manager.service sddm.service' "$UNIT" || fail "the release runs before the display manager"
grep -Fxq 'ExecStart=/usr/lib/omarchy/mac-boot/external-displays release' "$UNIT" || fail "the unit runs the release"
[[ $(readlink "$FILES/usr/lib/systemd/system/multi-user.target.wants/omarchy-mac-external-displays.service") == ../omarchy-mac-external-displays.service ]] ||
  fail "multi-user.target pulls the release in without an enable step"
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$tmp/units"
  cp "$UNIT" "$tmp/units/"
  systemd-analyze verify --man=no "$tmp/units/omarchy-mac-external-displays.service" 2>"$tmp/verify" ||
    ! grep -v -e 'not found' -e 'not executable' -e 'Cannot add dependency' "$tmp/verify" | grep -q . ||
    fail "the unit verifies: $(cat "$tmp/verify")"
fi
pass "the udev rule and the desktop release are wired"
