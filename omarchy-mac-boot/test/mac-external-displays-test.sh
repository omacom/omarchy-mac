#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# While the boot splash runs on a laptop's built-in screen, the Apple display
# card's external connectors are held off; they come on for the desktop.
FILES=$ROOT/files
SCRIPT=$FILES/usr/lib/omarchy/mac-boot/external-displays
LID=$FILES/usr/lib/omarchy/mac-boot/lid-state
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
  printf '#!/bin/bash\n[[ -s %q ]] && cat %q\n' "$tmp/lid" "$tmp/lid" >"$tmp/bin/lid-state"
  printf '#!/bin/bash\necho "$*" >>%q\n' "$tmp/journal" >"$tmp/bin/logger"
  chmod +x "$tmp/bin/plymouth" "$tmp/bin/lid-state" "$tmp/bin/logger"
  rm -f "$tmp/journal"
  : >"$tmp/splash"
  echo open >"$tmp/lid"
}

displays() {
  OMARCHY_SYSFS=$sys OMARCHY_MAC_DISPLAYS_STATE=$tmp/run OMARCHY_UUID_SOURCE=$tmp/uuid \
    OMARCHY_PLYMOUTH=$tmp/bin/plymouth OMARCHY_LID_STATE=$tmp/bin/lid-state OMARCHY_LOGGER=$tmp/bin/logger bash "$SCRIPT" "$@"
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
[[ $(<"$tmp/journal") == "-t omarchy-mac-external-displays -- held card2's external displays off: HDMI-A-1 USB-1 USB-2 USB-3" ]] ||
  fail "hold logs what it held: $(cat "$tmp/journal")"
displays hold card2 && (( $(wc -l <"$tmp/run/external-displays-held") == 4 )) || fail "a replayed add holds nothing twice"
pass "an open laptop under the splash holds its external displays off"

for case in shut unknown desktop no-chassis no-splash released no-panel bad-name; do
  new_mac
  card=card2
  case $case in
    shut) echo closed >"$tmp/lid" ;;
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
  case $case in
    shut) why="the lid is closed" ;;
    unknown) why="the lid is unknown" ;;
    desktop | no-chassis) why="this Mac is not a laptop" ;;
    no-splash) why="no splash is running" ;;
    released) why="the splash is over" ;;
    no-panel) why="it has no built-in panel" ;;
    bad-name) why="" ;;
  esac
  if [[ -n $why ]]; then
    [[ $(<"$tmp/journal") == "-t omarchy-mac-external-displays -- not holding card2's external displays: $why" ]] ||
      fail "hold logs why it held nothing ($case): $(cat "$tmp/journal" 2>/dev/null)"
  else
    [[ ! -e $tmp/journal ]] || fail "a bad card name is ignored silently"
  fi
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

# ── lid ────────────────────────────────────────────────────────────────────
# The lid comes from the kernel's switch, not logind, which can start after
# the card appears. Reading a real switch is checked on hardware.
lid() { OMARCHY_SYSFS=$tmp/lsys OMARCHY_DEV=$tmp/ldev perl "$LID"; }
rm -rf "$tmp/lsys" "$tmp/ldev"
mkdir -p "$tmp/ldev/input"
out=$(lid) && fail "no input devices: the lid is unknown"
[[ -z $out ]] || fail "an unknown lid prints nothing: $out"
mkdir -p "$tmp/lsys/class/input/input0/capabilities" "$tmp/lsys/class/input/input0/event0"
echo 0 >"$tmp/lsys/class/input/input0/capabilities/sw"
lid >/dev/null && fail "a device without a lid switch is not a lid"
mkdir -p "$tmp/lsys/class/input/input3/capabilities" "$tmp/lsys/class/input/input3/event3"
echo "10 1" >"$tmp/lsys/class/input/input3/capabilities/sw"
lid >/dev/null && fail "a lid switch without its device node is unknown"
: >"$tmp/ldev/input/event3"
out=$(lid) && fail "a lid switch that won't answer EVIOCGSW is unknown"
[[ -z $out ]] || fail "a switch that can't be read prints nothing: $out"
[[ -x $LID ]] && perl -c "$LID" 2>/dev/null || fail "the lid reader is executable and parses"
(( 0x8008451b == (2 << 30 | 8 << 16 | 0x45 << 8 | 0x1b) )) || fail "EVIOCGSW reads 8 bytes"
pass "the lid is read from the kernel's switch, unknown when it can't be"

# ── wiring ─────────────────────────────────────────────────────────────────
[[ -x $SCRIPT ]] && bash -n "$SCRIPT" || fail "the script is executable and parses"
grep -Fxq 'ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="apple-drm", RUN+="/usr/lib/omarchy/mac-boot/external-displays hold %k"' "$RULES" ||
  fail "the Apple display card is held as it appears"
grep -Fxq 'ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{SYNTH_ARG_OMARCHYMACDISPLAYS}=="1", ENV{HOTPLUG}="1"' "$RULES" ||
  fail "the release's synthetic change is a hotplug (aquamarine rescans on HOTPLUG=1 only)"
grep -Fxq 'After=plymouth-quit.service plymouth-quit-wait.service omarchy-provision-owner.service omarchy-drive-recover.service' "$UNIT" ||
  fail "the release waits for the splash, which first boot holds, and for owner setup or a password reset on tty1"
grep -Fxq 'Before=display-manager.service sddm.service' "$UNIT" || fail "the release runs before the display manager"
grep -Fxq 'ExecStart=/usr/lib/omarchy/mac-boot/external-displays release' "$UNIT" || fail "the unit runs the release"
[[ $(readlink "$FILES/usr/lib/systemd/system/multi-user.target.wants/omarchy-mac-external-displays.service") == ../omarchy-mac-external-displays.service ]] ||
  fail "multi-user.target pulls the release in without an enable step"
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$tmp/units"
  cp "$UNIT" "$tmp/units/"
  mkdir -p "$tmp/probe"
  printf '[Unit]\nDefaultDependencies=no\n[Service]\nType=oneshot\nExecStart=%s\n' "$SCRIPT" >"$tmp/probe/probe.service"
  if probe_out=$(systemd-analyze verify --man=no "$tmp/probe/probe.service" 2>&1) && [[ -z $probe_out ]]; then
    systemd-analyze verify --man=no "$tmp/units/omarchy-mac-external-displays.service" 2>"$tmp/verify" ||
      ! grep -v -e 'not found' -e 'not executable' -e 'Cannot add dependency' "$tmp/verify" | grep -q . ||
      fail "the unit verifies: $(cat "$tmp/verify")"
  else
    echo 'ok - systemd-analyze cannot verify units here; unit verification not run'
  fi
fi
pass "the udev rule and the desktop release are wired"
