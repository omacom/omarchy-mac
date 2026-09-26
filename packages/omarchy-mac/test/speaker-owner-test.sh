#!/bin/bash
# speakersafetyd has one owner across the two Mac packages: this package's
# preset. The boot package (../boot, omarchy-mac-boot) no longer enables it from
# its preset or its first-boot hand-off. A fresh image and an upgrade from
# omarchy-mac-boot 20260925-3/-4, which enabled it from both, must each end with
# it enabled by exactly one link, checked with real systemctl --root.
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
boot=$ROOT/boot
first_boot=$boot/files/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot
real_systemctl=$(command -v systemctl) || fail 'systemctl is available'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/first-boot-bin"
printf '#!/bin/bash\necho apple-silicon\n' >"$work/bin/omarchy-hw-platform"
printf '#!/bin/bash\necho 14e4:4433\n' >"$work/bin/lspci"
# First boot enables units on the live system; here they land in the image root.
cat >"$work/first-boot-bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >>"\$FIRST_BOOT_CALLS"
exec "$real_systemctl" --root="\$OMARCHY_MAC_FIRST_BOOT_ROOT" "\$@"
STUB
chmod +x "$work/bin/"* "$work/first-boot-bin/systemctl"

# omarchy-mac-boot 20260925-3 and -4 (quattro-upstream f7ea7ecc8 and 84352fdb8).
old_boot_preset='enable omarchy-vendor-firmware.service
enable speakersafetyd.service
enable NetworkManager.service
enable systemd-resolved.service
enable systemd-timesyncd.service
enable omarchy-mac-first-boot.service'

# An image root with both packages and the units their presets name. Arch
# disables every unit no preset names.
image() {
  local root=$1 unit
  "$ROOT/install" "$root"
  "$boot/install" "$root"
  mkdir -p "$root/usr/lib/systemd/system" "$root/usr/share/omarchy/install/provisioning" "$root/var/log"
  for unit in speakersafetyd NetworkManager systemd-resolved systemd-timesyncd sddm; do
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
      >"$root/usr/lib/systemd/system/$unit.service"
  done
  echo 'disable *' >"$root/usr/lib/systemd/system-preset/99-default.preset"
  printf '[Service]\nExecStart=/usr/bin/true\n' >"$root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  printf '#!/bin/bash\n' >"$root/usr/bin/omarchy-provision-owner"
  chmod 755 "$root/usr/bin/omarchy-provision-owner"
}

# What omarchy-mac-installer's image builder does (build-mac-image apply_presets):
# systemctl preset for every unit an 80-omarchy-mac*.preset or
# 80-omarchy-apple.preset enables.
apply_image_presets() {
  local root=$1 units
  mapfile -t units < <(cat "$root"/usr/lib/systemd/system-preset/80-omarchy-mac*.preset \
    "$root/usr/lib/systemd/system-preset/80-omarchy-apple.preset" | awk '$1 == "enable" { print $2 }' | sort -u)
  "$real_systemctl" --root="$root" preset "${units[@]}" >/dev/null 2>&1
}

# The real first-boot hand-off that enables the display manager.
first_boot_handoff() {
  : >"$work/first-boot-calls"
  env OMARCHY_MAC_FIRST_BOOT_ROOT="$1" FIRST_BOOT_CALLS="$work/first-boot-calls" PATH="$work/first-boot-bin:$PATH" \
    bash -c 'source "$1"; stage_provisioning' _ "$first_boot" >/dev/null 2>&1
}

# The deferred audio step's omarchy-setup-mac --system.
setup() { PATH="$work/bin:$PATH" "$1/usr/bin/omarchy-mac-setup-system" "$1" >/dev/null 2>&1; }

enabled_once() {
  local root=$1
  [[ $("$real_systemctl" --root="$root" is-enabled speakersafetyd.service 2>/dev/null) == enabled ]] || return 1
  [[ $(find "$root/etc/systemd/system" -path '*.wants/speakersafetyd.service' | wc -l) == 1 ]] || return 1
  [[ $(readlink "$root/etc/systemd/system/multi-user.target.wants/speakersafetyd.service") == /usr/lib/systemd/system/speakersafetyd.service ]]
}

only_owner() {
  [[ $(grep -lE '^[[:space:]]*enable[[:space:]]+speakersafetyd' "$1"/usr/lib/systemd/system-preset/*.preset |
    xargs -n1 basename) == 80-omarchy-mac-audio.preset ]]
}

# Fresh image: the builder's presets, first boot, then the deferred audio step.
root=$work/fresh
image "$root"
only_owner "$root" || fail 'only omarchy-mac presets speakersafetyd'
apply_image_presets "$root"
enabled_once "$root" || fail 'the image presets enable speakersafetyd once'
first_boot_handoff "$root" || fail 'first boot hands off' "$(cat "$work/first-boot-calls")"
[[ $(<"$work/first-boot-calls") == 'enable sddm.service' ]] || fail 'first boot enables only the display manager' "$(cat "$work/first-boot-calls")"
[[ -L $root/etc/systemd/system/multi-user.target.wants/sddm.service ]] || fail 'first boot enables sddm'
setup "$root"
[[ -f $root/var/lib/omarchy-mac/speaker-safety-configured ]] || fail 'the audio step applies the preset'
enabled_once "$root" || fail 'a fresh Mac ends with speakersafetyd enabled once'
pass 'a fresh image enables speakersafetyd once, from omarchy-mac alone'

root=$work/unowned
image "$root"
rm "$root/usr/lib/systemd/system-preset/80-omarchy-mac-audio.preset"
apply_image_presets "$root"
first_boot_handoff "$root" || fail 'first boot hands off without omarchy-mac'
[[ $("$real_systemctl" --root="$root" is-enabled speakersafetyd.service 2>/dev/null) == disabled ]] ||
  fail 'without omarchy-mac nothing in the boot package enables speakersafetyd'
pass 'the boot package neither presets nor enables speakersafetyd'

# Upgrade from -3/-4: that image enabled it through both presets and first boot.
# $2: whether omarchy-mac's setup had run (its audio step may still be queued).
old_mac() {
  local root=$1
  image "$root"
  printf '%s\n' "$old_boot_preset" >"$root/usr/lib/systemd/system-preset/80-omarchy-mac.preset"
  apply_image_presets "$root"
  "$real_systemctl" --root="$root" enable speakersafetyd.service sddm.service >/dev/null 2>&1
  if [[ $2 == configured ]]; then setup "$root"; fi
  enabled_once "$root" || fail "the old $2 Mac starts enabled once"
}

upgrade() {
  "$ROOT/install" "$1"
  "$boot/install" "$1"
}

for state in configured unconfigured; do
  root=$work/upgrade-$state
  old_mac "$root" "$state"
  upgrade "$root"
  only_owner "$root" || fail "after the upgrade only omarchy-mac presets speakersafetyd ($state)"
  enabled_once "$root" || fail "the upgrade leaves speakersafetyd enabled ($state)"
  setup "$root"
  enabled_once "$root" || fail "omarchy-mac setup after the upgrade keeps it enabled ($state)"
  "$real_systemctl" --root="$root" preset speakersafetyd.service >/dev/null 2>&1
  enabled_once "$root" || fail "reapplying its preset keeps it enabled ($state)"
  "$real_systemctl" --root="$root" preset-all >/dev/null 2>&1 || fail "preset-all runs ($state)"
  enabled_once "$root" || fail "preset-all keeps it enabled ($state)"
done
pass 'an upgrade from omarchy-mac-boot -3/-4 keeps speakersafetyd enabled once, even through preset-all'

# An administrator's disable before the upgrade stays.
root=$work/upgrade-disabled
old_mac "$root" configured
"$real_systemctl" --root="$root" disable speakersafetyd.service >/dev/null 2>&1
upgrade "$root"
setup "$root"
[[ $("$real_systemctl" --root="$root" is-enabled speakersafetyd.service 2>/dev/null) == disabled ]] ||
  fail 'an explicit disable survives the upgrade'
pass 'an explicit disable survives the upgrade'
