#!/bin/bash

# Hardware check for the first Wi-Fi join after the Broadcom firmware loads on
# an Apple Silicon Mac. Not part of ./test/shell: it needs the real chip and a
# saved network. Each trial reloads brcmfmac, which drops Wi-Fi, so run it over
# Ethernet or Thunderbolt networking, or at the Mac, as a user with
# passwordless sudo.
#
#   bash test/manual/wifi-first-join-check.sh [connection] [trials]
#
# connection defaults to the active Wi-Fi connection and trials to 10. Each
# trial reloads brcmfmac, as a boot or the resume recovery does, lets
# NetworkManager bring the connection back and needs a DHCP address within
# 45 s. FRESH=1 makes each join a first one, like adding the network from the
# network panel: iwd forgets the network and a never-used copy of the
# connection joins. Every check is fatal: a run that reaches the end has passed.
#
# To reproduce the 6 GHz stall on a Wi-Fi 6E Mac near a 6 GHz access point,
# make iwd prefer 6 GHz, run the check, then delete the file and restart iwd:
#   printf '[Rank]\nBandModifier6GHz=20.0\n' | sudo tee /etc/iwd/main.conf
#   sudo systemctl restart iwd

set -euo pipefail

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
active_wifi() { nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2 == "802-11-wireless" { print $1; exit }'; }
autoconnects() { [[ $(nmcli -g connection.autoconnect connection show "$connection") == "yes" ]]; }
# FRESH makes iwd forget the network, so NetworkManager must hold the password
# to join again. A connection mirrored from iwd has none.
stores_password() {
  [[ $(nmcli -g 802-11-wireless-security.psk-flags connection show "$connection") == 0* ]] &&
    [[ -n $(sudo -n nmcli -s -g 802-11-wireless-security.psk connection show "$connection") ]]
}
iwd_knows() { sudo -n iwctl known-networks list | sed 's/\x1b\[[0-9;]*m//g' | grep -F "  $1  " >/dev/null; }
forgotten() { ! iwd_knows "$ssid"; }

# The iwd running now has to have loaded the Apple default: a package upgrade
# reaches iwd only when it next starts.
runs_apple_default() {
  local invocation
  [[ -f /usr/lib/omarchy-mac/iwd/main.conf && ! -e /etc/iwd/main.conf ]] || return 0
  invocation=$(systemctl show -P InvocationID iwd.service)
  journalctl -q -u iwd.service _SYSTEMD_INVOCATION_ID="$invocation" -o cat |
    grep -Fx 'Loaded configuration from /usr/lib/omarchy-mac/iwd/main.conf' >/dev/null
}

leased() {
  local iface
  iface=$(brcmfmac_iface) || return 1
  [[ $(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null) == "$joining" ]] &&
    [[ -n $(ip -4 -o address show dev "$iface") ]]
}

band() {
  local freq
  freq=$(iw dev "$(brcmfmac_iface)" link | awk '/freq:/ { print int($2) }')
  if [[ -z $freq ]]; then
    echo "not associated"
  elif ((freq < 3000)); then
    echo "2.4 GHz ($freq MHz)"
  elif ((freq < 5925)); then
    echo "5 GHz ($freq MHz)"
  else
    echo "6 GHz ($freq MHz)"
  fi
}

cleanup() {
  # An abort between unload and load would leave the Mac without Wi-Fi.
  lsmod | grep -q '^brcmfmac ' || sudo -n modprobe brcmfmac || true
  if [[ ${FRESH:-0} == 1 && -n ${connection:-} ]]; then
    nmcli connection delete omarchy-first-join-check >/dev/null 2>&1 || true
    nmcli connection modify "$connection" connection.autoconnect "$autoconnect" || true
    if [[ $(nmcli -g GENERAL.STATE connection show "$connection") != "activated" ]]; then
      nmcli connection up "$connection" >/dev/null 2>&1 ||
        echo "note - join $connection from the network panel; it may ask for the password again" >&2
    fi
  fi
}

check "the platform is Apple Silicon" apple_silicon
check "the Broadcom Wi-Fi interface is present" has_brcmfmac
check "NetworkManager uses iwd" iwd_backend
check "sudo works without a password" sudo -n true
connection=${1:-$(active_wifi)}
trials=${2:-10}
check "a saved Wi-Fi connection is named" test -n "$connection"
check "iwd runs the Apple default (restart iwd or reboot after an upgrade)" runs_apple_default
if [[ ${FRESH:-0} == 1 ]]; then
  check "NetworkManager stores the password for $connection" stores_password
else
  check "$connection connects automatically" autoconnects
fi

autoconnect=$(nmcli -g connection.autoconnect connection show "$connection")
trap cleanup EXIT
for ((trial = 1; trial <= trials; trial++)); do
  joining=$connection
  nmcli device disconnect "$(brcmfmac_iface)" >/dev/null 2>&1 || true
  if [[ ${FRESH:-0} == 1 ]]; then
    nmcli connection delete omarchy-first-join-check >/dev/null 2>&1 || true
    nmcli connection modify "$connection" connection.autoconnect no
    ssid=$(nmcli -g 802-11-wireless.ssid connection show "$connection")
    sudo -n iwctl known-networks "$ssid" forget >/dev/null 2>&1 || true
    check "iwd forgot $ssid" forgotten
    nmcli connection clone "$connection" omarchy-first-join-check >/dev/null
    joining=omarchy-first-join-check
  fi
  sudo -n modprobe -r brcmfmac_wcc brcmfmac
  sleep 1
  sudo -n modprobe brcmfmac
  start=$SECONDS
  if [[ ${FRESH:-0} == 1 ]]; then
    for ((i = 0; i < 40; i++)); do
      nmcli -t -f SSID device wifi list --rescan no 2>/dev/null | grep -Fx "$ssid" >/dev/null && break
      sleep 0.5
    done
    nmcli --wait 1 connection up "$joining" >/dev/null 2>&1 || true
  fi
  for ((i = 0; i < 90; i++)); do
    leased && break
    sleep 0.5
  done
  if leased; then
    printf 'ok - trial %d: %s got an address %ds after the reload on %s\n' "$trial" "$joining" $((SECONDS - start)) "$(band)"
  else
    printf 'not ok - trial %d: %s got no address within 45 s on %s\n' "$trial" "$joining" "$(band)" >&2
    exit 1
  fi
done
