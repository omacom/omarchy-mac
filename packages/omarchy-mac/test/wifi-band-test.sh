#!/bin/bash

# NetworkManager's iwd on Apple Silicon never starts a 6 GHz join, where the
# BCM4388 firmware passes no traffic, and an administrator's iwd configuration
# still decides instead of the package.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
"$ROOT"/install "$root"

# Arch's iwd unit, which gives iwd /etc/iwd as its configuration directory.
mkdir -p "$root/usr/lib/systemd/system"
printf '[Service]\nExecStart=/usr/lib/iwd/iwd\nConfigurationDirectory=iwd\n' >"$root/usr/lib/systemd/system/iwd.service"

# The main.conf iwd loads: the unit's last CONFIGURATION_DIRECTORY assignment
# after systemd merges its drop-ins (Environment= overrides the value
# ConfigurationDirectory= sets), split on colons, first main.conf found.
iwd_config() {
  local list dirs dir
  list=$(systemd-analyze --root="$root" cat-config systemd/system/iwd.service |
    sed -n 's/^Environment=CONFIGURATION_DIRECTORY=//p' | tail -n 1)
  IFS=: read -ra dirs <<<"${list:-/etc/iwd}"
  for dir in "${dirs[@]}"; do
    if [[ -f $root$dir/main.conf ]]; then
      echo "$root$dir/main.conf"
      return 0
    fi
  done
  return 1
}

# A band iwd scans and joins on: its [Rank] modifier is unset or nonzero.
band_enabled() {
  local config=$1 key=$2 value
  value=$(awk -F= -v key="$key" '/^\[/ { section = $0 } section == "[Rank]" && $1 == key { print $2 }' "$config")
  [[ -z $value ]] || awk -v v="$value" 'BEGIN { exit !(v + 0 != 0) }'
}

config=$(iwd_config) || fail "iwd finds a configuration on a fresh install"
[[ $config == "$root/usr/lib/omarchy-mac/iwd/main.conf" ]] || fail "iwd loads the Apple default" "$config"
! band_enabled "$config" BandModifier6GHz || fail "iwd never joins 6 GHz"
# iwd refuses to start unless 2.4 GHz and 5 GHz stay enabled.
band_enabled "$config" BandModifier2_4GHz && band_enabled "$config" BandModifier5GHz ||
  fail "iwd still joins 2.4 GHz and 5 GHz"
pass "iwd joins 2.4 GHz and 5 GHz but never 6 GHz on a fresh install"

mkdir -p "$root/etc/iwd"
printf '[General]\nAddressRandomization=network\n' >"$root/etc/iwd/main.conf"
config=$(iwd_config)
[[ $config == "$root/etc/iwd/main.conf" ]] || fail "an administrator main.conf replaces the Apple default" "$config"
band_enabled "$config" BandModifier6GHz || fail "the administrator decides about 6 GHz"
pass "an administrator's /etc/iwd/main.conf replaces the Apple default"

rm "$root/etc/iwd/main.conf"
mkdir -p "$root/etc/systemd/system/iwd.service.d"
printf '[Service]\n' >"$root/etc/systemd/system/iwd.service.d/20-omarchy-mac.conf"
config=$(iwd_config) && fail "a same-name /etc drop-in removes the Apple default" "$config"
pass "a same-name /etc drop-in removes the Apple default"
