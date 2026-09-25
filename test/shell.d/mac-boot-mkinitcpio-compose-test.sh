#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-mac-boot's 90-94 drop-ins sort after the platform baseline
# (00-omarchy-hooks.conf) and before omarchy_hooks.conf. On a Mac they must
# turn that baseline into the encrypted systemd image, and leave a legacy
# busybox encrypt line exactly as its owner set it up.
require_platform_fixtures "the Apple boot drop-ins on the platform baseline"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake_platform "$tmp/platform" apple-silicon
mkdir -p "$tmp/bin"
# No kernel modules here: the HID drop-in adds only what modinfo finds.
printf '#!/bin/bash\nexit 1\n' >"$tmp/bin/modinfo"
chmod +x "$tmp/bin/modinfo"

# The drop-ins read /etc/vconsole.conf; point them at a fixture.
compose() {
  local stock=$1 config=$tmp/buildconfig conf
  local -a conf_files=()
  mkdir -p "$tmp/conf.d"
  rm -f "$tmp/conf.d"/*.conf
  cp "$ROOT"/etc/mkinitcpio.conf.d/*.conf "$ROOT"/packages/omarchy-mac/boot/files/etc/mkinitcpio.conf.d/*.conf "$tmp/conf.d/"
  sed -i "s|/etc/vconsole.conf|$tmp/vconsole.conf|g" "$tmp/conf.d"/*.conf
  printf 'MODULES=()\nBINARIES=()\nFILES=()\nHOOKS=(%s)\n' "$stock" >"$config"
  mapfile -d '' conf_files < <(LC_ALL=C.UTF-8 find "$tmp/conf.d" -maxdepth 1 -xtype f -name '*.conf' -print0 |
    sed -z 's/.*\///' | LC_ALL=C.UTF-8 sort -zVu)
  for conf in "${conf_files[@]}"; do
    cat -- "$tmp/conf.d/$conf" >>"$config"
  done
  OMARCHY_PROC_ROOT="$tmp/platform/proc" PATH="$tmp/bin:$tmp/platform/bin:$ROOT/bin:$PATH" "$BASH" -c '
    . "$1" || exit 1
    printf "HOOKS=%s\nFILES=%s\n" "${HOOKS[*]}" "${FILES[*]}"
  ' -- "$config"
}

stock="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
apple="base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck"

printf 'KEYMAP=dk-latin1\nXKBLAYOUT=dk\n' >"$tmp/vconsole.conf"
out=$(compose "$stock") || fail "the baseline and the Apple drop-ins source cleanly"
[[ $(sed -n 's/^HOOKS=//p' <<<"$out") == "$apple" ]] ||
  fail "a Mac builds the encrypted systemd image from the baseline" "$out"
[[ $(sed -n 's/^FILES=//p' <<<"$out") == *"$tmp/vconsole.conf"* ]] || fail "a Latin layout reaches the image" "$out"
pass "on the platform baseline the Apple drop-ins add firmware, conversion and sd-encrypt once"

printf 'KEYMAP=ru\nXKBLAYOUT=ru\n' >"$tmp/vconsole.conf"
out=$(compose "$stock") || fail "a non-Latin layout sources cleanly"
[[ $(sed -n 's/^HOOKS=//p' <<<"$out") == "${apple/ sd-vconsole / }" && $(sed -n 's/^FILES=//p' <<<"$out") != *vconsole* ]] ||
  fail "a non-Latin layout stays out of the image" "$out"
pass "a non-Latin layout keeps the prompt on the US map"

legacy="base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block encrypt asahi filesystems fsck"
printf 'KEYMAP=dk-latin1\nXKBLAYOUT=dk\n' >"$tmp/vconsole.conf"
out=$(compose "$legacy") || fail "a legacy line sources cleanly"
[[ $(sed -n 's/^HOOKS=//p' <<<"$out") == "$legacy" ]] || fail "a busybox encrypt Mac keeps its own HOOKS" "$out"
pass "a legacy busybox encrypt Mac keeps its line"
