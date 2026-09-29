#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# update-takeover, which omarchy-lifecycle-dispatch runs before an update moves
# aside files no package owns: the Mac's boot chain and pacman configuration
# refuse the whole takeover, and so does an mkinitcpio file whose own HOOKS carry
# the asahi or busybox encrypt hook; anything else may go.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT/install" "$work/root"
takeover=$work/root/usr/lib/omarchy/mac-boot/update-takeover
[[ -x $takeover && $(stat -c %a "$takeover") == 755 ]] || fail 'the update-takeover entrypoint is staged for omarchy-lifecycle-dispatch'
fixture=$work/fixture
export OMARCHY_MAC_BOOT_ROOT=$fixture

refuses() {
  local expected=$1 status=0 output
  shift
  output=$("$takeover" /usr/share/omarchy/ok "$@" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == "$expected" ]] || fail "refused: $*" "status $status: $output"
}

"$takeover" || fail 'no path, nothing to refuse'
"$takeover" /usr/share/omarchy/default/foo /etc/xdg/omarchy.conf /usr/bin/omarchy-new ||
  fail 'files outside the platform paths may be taken over'
for path in /boot /boot/efi/limine.conf /etc/default/grub /etc/grub/themes/x /etc/limine/x /etc/pacman.conf \
  /etc/pacman.d/mirrorlist /usr/lib/initcpio /usr/lib/initcpio/install/x; do
  refuses "Refusing to replace Apple Silicon platform path: $path" "$path"
done
pass 'the boot chain, pacman configuration and initcpio refuse the takeover'

# omarchy-settings ships these on aarch64 too, so an unowned copy must not stop
# every update.
settings=(/etc/mkinitcpio.conf.d/omarchy_hooks.conf /etc/mkinitcpio.conf.d/00-omarchy-hooks.conf
  /etc/mkinitcpio.conf.d/thunderbolt_module.conf /etc/modprobe.d/omarchy-usb-autosuspend.conf
  /etc/systemd/oomd.conf.d/10-omarchy.conf /etc/systemd/zram-generator.conf /etc/tmpfiles.d/omarchy-zswap.conf
  /usr/lib/systemd/user/app.slice.d/10-oomd.conf /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf)
"$takeover" "${settings[@]}" || fail 'the drop-ins omarchy-settings ships on aarch64 may be taken over (absent)'
mkdir -p "$fixture/etc/mkinitcpio.conf.d"
printf '%s\n' '# Omarchy' 'MODULES+=(thunderbolt)' >"$fixture/etc/mkinitcpio.conf.d/thunderbolt_module.conf"
printf '%s\n' 'HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)' \
  >"$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
"$takeover" "${settings[@]}" || fail 'a drop-in without asahi or busybox encrypt may be taken over'
printf '%s\n' '#HOOKS=(base udev asahi encrypt filesystems)' 'HOOKS=(base systemd block filesystems) # encrypt' \
  >"$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
"$takeover" /etc/mkinitcpio.conf.d/omarchy_hooks.conf || fail 'commented hooks do not count'
# The HOOKS baseline's own lines sit in its branches.
if requires_runtime "an unowned copy of the runtime's HOOKS baseline may be taken over"; then
  cp "$OMARCHY_TEST_RUNTIME/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf" "$fixture/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf"
  grep -q '^ .*HOOKS=(.* encrypt ' "$fixture/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf" || fail 'the baseline fixture has its busybox branch'
  "$takeover" /etc/mkinitcpio.conf.d/00-omarchy-hooks.conf || fail 'an unowned copy of the HOOKS baseline may be taken over'
fi
pass 'the memory, USB and mkinitcpio drop-ins omarchy-settings ships on aarch64 may be taken over'

# A legacy Mac whose drop-in carries its unlock: the baseline sorts first, so
# the drop-in's line is the one its initramfs boots with.
for line in 'HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)' \
  'HOOKS=(base udev asahi block filesystems fsck)' 'HOOKS+=(encrypt)' 'HOOKS=(encrypt filesystems)' 'HOOKS=(base asahi)'; do
  printf '# Omarchy\n%s\n' "$line" >"$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  refuses "Refusing to replace /etc/mkinitcpio.conf.d/omarchy_hooks.conf: its HOOKS set how this Mac's initramfs unlocks and boots; move that HOOKS line into /etc/mkinitcpio.conf, then run omarchy update again" \
    /etc/mkinitcpio.conf.d/omarchy_hooks.conf /etc/systemd/oomd.conf.d/10-omarchy.conf
done
printf '%s\n' 'HOOKS=(base udev autodetect modconf kms keyboard keymap block encrypt filesystems fsck)' >"$fixture/etc/mkinitcpio.conf"
refuses "Refusing to replace /etc/mkinitcpio.conf: its HOOKS set how this Mac's initramfs unlocks and boots" /etc/mkinitcpio.conf
printf '%s\n' 'HOOKS=(base systemd autodetect block sd-encrypt filesystems fsck)' >"$fixture/etc/mkinitcpio.conf"
"$takeover" /etc/mkinitcpio.conf || fail 'an mkinitcpio.conf without asahi or busybox encrypt may be taken over'
pass 'an mkinitcpio file carrying the asahi or busybox encrypt hook refuses the takeover'
