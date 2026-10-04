#!/bin/bash

# NetworkManager on iwd asks a secret agent, which Omarchy does not run, for a
# new key for every network it saved before, so setup gives iwd the profile
# NetworkManager writes for a new connection.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
helper="$ROOT/lib/wifi-iwd-profiles"
state="$work/iwd"
mkdir -p "$work/bin" "$work/nm"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo apple-silicon
STUB
cat >"$work/bin/NetworkManager" <<'STUB'
#!/bin/bash
[[ $* == "--print-config" ]] && printf '[device]\nwifi.backend=%s\n' "${BACKEND:-iwd}"
STUB
# nmcli lists $NM/connections as TIMESTAMP:UUID:TYPE and prints a connection's
# fields from $NM/<uuid>, one per line in the order the helper asks for them.
# Like nmcli, it prints a key as the eight characters <hidden> unless asked to
# show secrets, and escapes : and \ unless told not to.
cat >"$work/bin/nmcli" <<'STUB'
#!/bin/bash
if [[ ${*: -2:1} != uuid ]]; then
  cat "$NM/connections"
  exit
fi
script=
[[ $* == *--show-secrets* ]] || script='9s/.*/<hidden>/;'
[[ $* == *'--escape no'* ]] || script+='s/[\\:]/\\&/g'
sed "$script" "$NM/${*: -1}"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" NM="$work/nm" OMARCHY_MAC_IWD_STATE="$state"

# A saved connection: UUID, last use, then id, SSID, mode, hidden, autoconnect,
# permissions and, unless the network is open, key management, flags and key.
connection() {
  echo "$2:$1:802-11-wireless" >>"$NM/connections"
  printf '%s\n' "${@:3}" >"$NM/$1"
}
hex=$(printf '0123456789abcdef%.0s' 1 2 3 4)
connection home 300 Home 'Home Net' infrastructure no yes '' wpa-psk 0 'correct horse'
connection cafe 290 Cafe "Joe's Café" infrastructure no yes '' sae 0 sesame
connection office 280 Office Office '' no yes '' wpa-psk 0 "$hex"
connection attic 270 Attic Attic infrastructure yes no '' wpa-psk 0 'up the ladder'
connection escapes 260 Escapes Escapes infrastructure no yes '' wpa-psk 0 ' back\slash:1'
# The older connection for a network is listed first.
connection shared-old 900 'Shared old' Shared infrastructure no yes '' wpa-psk 0 old-password
connection shared-new 1000 Shared Shared infrastructure no yes '' wpa-psk 0 new-password
# None of these is NetworkManager's to hand to iwd: agent-owned, unsaved and
# missing keys, a connection limited to one user, enterprise and open networks,
# and an access point the Mac runs itself.
connection agent 250 Agent Agent infrastructure no yes '' wpa-psk 1 agent-password
connection unsaved 240 Unsaved Unsaved infrastructure no yes '' wpa-psk 2 unsaved-password
connection nokey 235 Nokey Nokey infrastructure no yes '' sae 0 ''
connection alice 230 Alice Alice infrastructure no yes user:alice wpa-psk 0 alice-password
connection campus 220 Campus Campus infrastructure no yes '' wpa-eap 0 campus-password
connection open 210 Open Open infrastructure no yes ''
connection hotspot 200 Hotspot Hotspot ap no yes '' wpa-psk 0 hotspot-password
profile() { grep -v '^#' "$state/$1.psk"; }

out=$(BACKEND=wpa_supplicant "$helper") || fail 'another backend is not an error' "$out"
[[ -z $out && ! -e $state ]] || fail 'NetworkManager on wpa_supplicant gives iwd nothing' "$out"
pass 'nothing is written unless NetworkManager is configured for iwd'

out=$("$helper") || fail 'the saved networks are carried over' "$out"
[[ $(profile 'Home Net') == $'[Security]\nPassphrase=correct horse' ]] || fail 'a passphrase is carried over' "$(profile 'Home Net')"
[[ $(stat -c %a "$state") == 700 && $(stat -c %a "$state/Home Net.psk") == 600 ]] || fail 'the profiles are private to root'
[[ $(profile '=4a6f65277320436166c3a9') == $'[Security]\nPassphrase=sesame' ]] ||
  fail 'an SSID beyond letters, digits, space, - and _ is named by its bytes, and SAE takes any passphrase'
[[ $(profile Office) == $'[Security]\nPreSharedKey='"$hex" ]] || fail 'a 64-digit hex key is a pre-shared key'
[[ $(profile Attic) == $'[Settings]\nAutoConnect=false\nHidden=true\n\n[Security]\nPassphrase=up the ladder' ]] ||
  fail 'a hidden network kept from autoconnecting stays so' "$(profile Attic)"
[[ $(profile Escapes) == '[Security]'$'\n''Passphrase=\sback\\slash:1' ]] ||
  fail 'a backslash and a leading space are escaped' "$(profile Escapes)"
grep -Fxq 'Gave iwd the saved Wi-Fi network Home Net' <<<"$out" || fail 'each carried-over network is reported' "$out"
pass 'saved WPA-PSK and SAE networks get the profile NetworkManager writes for a new connection'

[[ $(LC_ALL=C ls -A "$state") == $'=4a6f65277320436166c3a9.psk\nAttic.psk\nEscapes.psk\nHome Net.psk\nOffice.psk\nShared.psk' ]] ||
  fail 'no other connection gets a profile' "$(ls -A "$state")"
[[ $(profile Shared) == $'[Security]\nPassphrase=new-password' ]] || fail 'the most recently used connection for a network wins'
pass 'agent-owned, unsaved, missing and single-user keys, enterprise, open and access point connections get none, and the newest connection wins'

printf '[Security]\nPassphrase=changed in iwd\n' >"$state/Home Net.psk"
out=$("$helper") || fail 'setup runs again' "$out"
[[ $(<"$state/Home Net.psk") == $'[Security]\nPassphrase=changed in iwd' && -z $out ]] || fail 'a profile iwd already has stays' "$out"
pass 'a profile iwd already has stays when setup runs again'

sed -n '/^if \[\[ -z \$root \]\]; then$/,/^fi$/p' "$ROOT/bin/omarchy-mac-setup-system" |
  grep -Fxq '  "$root/usr/lib/omarchy-mac/wifi-iwd-profiles"' || fail 'system setup runs the helper on the live machine only'
pass 'system setup gives iwd the saved networks on the live machine only'
