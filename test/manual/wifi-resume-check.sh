#!/bin/bash

# Hardware check for Wi-Fi resume on an Apple Silicon Mac. Not part of
# ./test/shell: it needs the real chip, a known network with Internet access and
# a suspend. Unplug Ethernet and run it as the desktop user from a local
# session, since suspend drops SSH.
#
#   bash test/manual/wifi-resume-check.sh before
#   close the lid for at least five minutes (or run systemctl suspend), then wake
#   bash test/manual/wifi-resume-check.sh after
#
# before checks the backend, recovery setup and a working Wi-Fi baseline and
# records a journal cursor; after checks that recovery finished for the latest
# resume and that the same Wi-Fi interface carries traffic again.
# Every check is fatal: a run that reaches the end has passed.

set -euo pipefail

unit=omarchy-wifi-resume-fix.service
cursor_file=/var/tmp/omarchy-wifi-resume-check.cursor
legacy=/etc/NetworkManager/conf.d/wifi_backend.conf
# systemd-sleep logs this ID for a resume and for a failed suspend; only the
# first says "returned from sleep".
sleep_stop=MESSAGE_ID=8811e6df2a8e40f58a94cea26f8ebf14

check() {
  local description=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    exit 1
  fi
}

brcmfmac_iface() {
  local dev
  for dev in /sys/class/net/*; do
    if [[ $(basename "$(readlink -f "$dev/device/driver")") == "brcmfmac" ]]; then
      echo "${dev##*/}"
      return 0
    fi
  done
  return 1
}

has_brcmfmac() { brcmfmac_iface >/dev/null; }
apple_silicon() { [[ $(omarchy-hw-platform) == "apple-silicon" ]]; }
iwd_backend() { NetworkManager --print-config | grep -Fx 'wifi.backend=iwd' >/dev/null; }
# Setup retires only a regular file identical to the one earlier installs wrote.
legacy_not_generated() { [[ ! -f $legacy || -L $legacy ]] || ! cmp -s "$legacy" /usr/share/omarchy-mac/legacy/wifi_backend.conf; }
wifi_connected() { nmcli -t -f DEVICE,STATE device status | grep -Fx "$iface:connected" >/dev/null; }
routed_over_wifi() { ip route get 1.1.1.1 | grep -F " dev $iface " >/dev/null; }
reachable() { [[ $(nmcli networking connectivity check) == "full" ]]; }

wait_for() {
  local i
  for ((i = 0; i < 120; i++)); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

latest_resume_cursor() {
  journalctl -q --after-cursor "$cursor" "$sleep_stop" --grep 'returned from sleep' -o export |
    sed -n 's/^__CURSOR=//p' | tail -n 1
}

recovery_outcome() {
  journalctl -q --after-cursor "$resume" -u "$unit" -o cat |
    grep -E 'no reload needed|reconnected .* after reload|still not connected|failed to (unload|reload)|radio is disabled' |
    tail -n 1
}

recovery_finished() {
  [[ -n $(recovery_outcome) && $(systemctl show -P ActiveState "$unit") != "activating" ]]
}

recovery_succeeded() {
  recovery_outcome | grep -E 'no reload needed|reconnected .* after reload' >/dev/null &&
    [[ $(systemctl show -P Result "$unit") == "success" ]]
}

if [[ ${1:-} != "before" && ${1:-} != "after" ]]; then
  echo "Usage: bash $0 before|after" >&2
  exit 2
fi
check "the Broadcom Wi-Fi interface is present" has_brcmfmac
iface=$(brcmfmac_iface)

case $1 in
  before)
    check "the platform is Apple Silicon" apple_silicon
    lspci -nn | grep -E '14e4:(4425|4433|4434)' || true
    check "the add-on covers this Wi-Fi chip" /usr/lib/omarchy-mac/wifi-supported
    check "NetworkManager uses iwd" iwd_backend
    check "setup retired the generated $legacy" legacy_not_generated
    if [[ -e $legacy || -L $legacy ]]; then
      echo "note - $legacy stays as an administrator file:"
      cat "$legacy"
    fi
    check "resume recovery is enabled" systemctl is-enabled --quiet "$unit"
    check "$iface is connected" wifi_connected
    check "traffic leaves through $iface" routed_over_wifi
    check "the network is reachable" reachable
    check "names resolve" getent hosts archlinux.org
    journalctl -q -n 0 --show-cursor | sed -n 's/^-- cursor: //p' >"$cursor_file"
    check "the journal cursor is recorded" test -s "$cursor_file"
    echo "Now close the lid for at least five minutes, wake the Mac and run: bash $0 after"
    ;;
  after)
    check "a cursor from the before step exists" test -s "$cursor_file"
    cursor=$(<"$cursor_file")
    resume=$(latest_resume_cursor)
    check "the Mac resumed from sleep since the before step" test -n "$resume"
    check "resume recovery finished for the latest resume" wait_for recovery_finished
    journalctl -q --after-cursor "$resume" -u "$unit" -o cat
    check "resume recovery succeeded" recovery_succeeded
    check "$iface is connected" wait_for wifi_connected
    check "traffic leaves through $iface" routed_over_wifi
    check "the network is reachable" reachable
    check "names resolve" getent hosts archlinux.org
    rm -f "$cursor_file"
    ;;
esac
