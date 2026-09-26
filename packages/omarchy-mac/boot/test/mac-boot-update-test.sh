#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

update="$ROOT/bin/omarchy-mac-boot-update"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
gate="$test_tmp/limine.enabled"
limine_default="$test_tmp/limine"
grub_default="$test_tmp/grub"
fstab="$test_tmp/fstab"
mkdir -p "$stub_bin"

for name in update-grub limine-update omarchy-mac-limine-deploy; do
  cat >"$stub_bin/$name" <<SH
#!/bin/bash
echo "$name \$*" >>"$calls"
[[ -z \${FAIL_$(tr - _ <<<"$name")-} ]] || exit 1
SH
  chmod +x "$stub_bin/$name"
done
cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/grub-probe"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/grub-mkconfig"
chmod +x "$stub_bin/omarchy-hw-apple-silicon" "$stub_bin/grub-probe" "$stub_bin/grub-mkconfig"
ln -s "$ROOT/bin/omarchy-mac-limine-active" "$stub_bin/omarchy-mac-limine-active"
ln -s "$ROOT/bin/omarchy-mac-limine-cmdline" "$stub_bin/omarchy-mac-limine-cmdline"

printf 'GRUB_CMDLINE_LINUX="rd.luks.name=abc=root"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$grub_default"
printf 'UUID=root-uuid / btrfs subvol=@ 0 0\n' >"$fstab"

run() {
  OMARCHY_LIMINE_GATE="$gate" OMARCHY_LIMINE_DEFAULT="$limine_default" OMARCHY_GRUB_DEFAULT="$grub_default" \
    OMARCHY_FSTAB="$fstab" PATH="$stub_bin:$PATH" bash "$update"
}

# A GRUB Mac: no gate, no Limine defaults.
: >"$calls"
run || fail "boot update on a GRUB Mac succeeds"
[[ $(cat "$calls") == "update-grub " ]] || fail "a GRUB Mac only regenerates GRUB" "$(cat "$calls")"
pass "a GRUB Mac regenerates GRUB only"

# A Limine Mac: GRUB, then the command line, the UKI and the ESP's Limine.
: >"$gate"
printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="stale"\n' >"$limine_default"
: >"$calls"
run || fail "boot update on a Limine Mac succeeds"
[[ $(cat "$calls") == $'update-grub \nlimine-update \nomarchy-mac-limine-deploy ' ]] ||
  fail "a Limine Mac still refreshes the GRUB image it carries, then rebuilds and deploys Limine" "$(cat "$calls")"
grep -Fxq 'KERNEL_CMDLINE[default]="root=UUID=root-uuid rw rootflags=subvol=@ rd.luks.name=abc=root quiet splash"' "$limine_default" ||
  fail "the Limine command line is re-derived from GRUB's defaults before limine-update" "$(cat "$limine_default")"
pass "a Limine Mac rebuilds Limine from GRUB's defaults file"

# A fresh image's first boot never booted GRUB: it leaves GRUB alone.
: >"$calls"
OMARCHY_MAC_BOOT_UPDATE_GRUB=0 run || fail "boot update without GRUB on a Limine Mac succeeds"
[[ $(cat "$calls") == $'limine-update \nomarchy-mac-limine-deploy ' ]] ||
  fail "OMARCHY_MAC_BOOT_UPDATE_GRUB=0 only rebuilds and deploys Limine" "$(cat "$calls")"
pass "a Limine Mac asked to leave GRUB alone runs no GRUB step"

# An image that never shipped GRUB: update-grub still ships with asahi-scripts,
# so the absence of GRUB's own tools is what must stop the refresh.
cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ $1 != "grub-probe" ]] && command -v "$1" >/dev/null 2>&1
SH
chmod +x "$stub_bin/omarchy-cmd-present"
mv "$stub_bin/grub-probe" "$test_tmp/grub-probe.away"
: >"$calls"
run || fail "boot update succeeds without GRUB installed"
[[ $(cat "$calls") == $'limine-update \nomarchy-mac-limine-deploy ' ]] ||
  fail "without GRUB the boot update only rebuilds and deploys Limine" "$(cat "$calls")"
mv "$test_tmp/grub-probe.away" "$stub_bin/grub-probe"
rm "$stub_bin/omarchy-cmd-present"
pass "a Mac with no GRUB needs none"

: >"$calls"
FAIL_limine_update=1 run && fail "a failed limine-update fails the boot update"
! grep -q omarchy-mac-limine-deploy "$calls" || fail "Limine is not deployed after a failed limine-update"
pass "a failed limine-update stops the boot update"
