#!/bin/bash

# Hardware check for Wi-Fi resume on an Apple Silicon Mac. Not part of
# ./test/shell: it needs the real chip, a known network and a suspend. Run it as
# the desktop user from a local session, since suspend drops SSH.
#
#   bash test/manual/wifi-resume-check.sh before
#   close the lid for at least five minutes (or run systemctl suspend), then wake
#   bash test/manual/wifi-resume-check.sh after
#
# before checks the backend and recovery setup and records a journal cursor;
# after checks that recovery ran for this resume and that Wi-Fi came back.
# Every check is fatal: a run that reaches the end has passed.

set -euo pipefail

unit=omarchy-wifi-resume-fix.service
cursor_file=/var/tmp/omarchy-wifi-resume-check.cursor
legacy=/etc/NetworkManager/conf.d/wifi_backend.conf
# systemd-sleep's "returned from sleep" entry, whatever its wording.
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

apple_silicon() { [[ $(omarchy-hw-platform) == "apple-silicon" ]]; }
iwd_backend() { NetworkManager --print-config | grep -Fx 'wifi.backend=iwd' >/dev/null; }
legacy_not_generated() { [[ ! -f $legacy ]] || ! cmp -s "$legacy" /usr/share/omarchy-mac/legacy/wifi_backend.conf; }
wifi_connected() { nmcli -t -f TYPE,STATE device status | grep -Fx 'wifi:connected' >/dev/null; }
resumed() { journalctl -q --after-cursor "$cursor" "$sleep_stop" | grep . >/dev/null; }
reachable() { [[ $(nmcli networking connectivity check) == "full" ]]; }
recovery_ran() { grep -E 'no reload needed|reconnected .* after reload' <<<"$runs" >/dev/null; }
recovery_succeeded() { [[ $(systemctl show -P Result "$unit") == "success" ]]; }

wait_for_wifi() {
  local i
  for ((i = 0; i < 90; i++)); do
    wifi_connected && return 0
    sleep 1
  done
  return 1
}

case ${1:-} in
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
    check "Wi-Fi is connected" wifi_connected
    journalctl -q -n 0 --show-cursor | sed -n 's/^-- cursor: //p' >"$cursor_file"
    check "the journal cursor is recorded" test -s "$cursor_file"
    echo "Now close the lid for at least five minutes, wake the Mac and run: bash $0 after"
    ;;
  after)
    check "a cursor from the before step exists" test -s "$cursor_file"
    cursor=$(<"$cursor_file")
    check "the Mac suspended and resumed since the before step" resumed
    check "Wi-Fi reconnects within 90 seconds" wait_for_wifi
    check "the network is reachable" reachable
    check "names resolve" getent hosts archlinux.org
    runs=$(journalctl -q --after-cursor "$cursor" -u "$unit" -o cat)
    printf '%s\n' "$runs"
    check "resume recovery ran after this resume" recovery_ran
    check "resume recovery finished without failing" recovery_succeeded
    rm -f "$cursor_file"
    ;;
  *)
    echo "Usage: bash $0 before|after" >&2
    exit 2
    ;;
esac
