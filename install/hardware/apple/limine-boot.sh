# Limine in front of U-Boot on Apple Silicon: the x86 Omarchy boot experience.
#
# U-Boot (the Mac's UEFI) boots ESP:/EFI/BOOT/BOOTAA64.EFI. This leaf puts
# Limine there. The Asahi update-grub (run by the asahi-scripts pacman hook on
# every kernel update) is retargeted to a file under /boot/grub so it never
# writes over Limine; GRUB itself is no longer part of the boot. Limine's
# configuration is Omarchy's (an ESP at /boot/efi, the kernel command line
# derived from GRUB's defaults file by omarchy-mac-limine-cmdline before every
# rebuild), and the x86 tooling does the rest: limine-update builds the UKI
# with the aarch64 systemd-stub and writes the entries, limine-snapper-sync
# the snapshot entries. Only a menu that already boots the kernel replaces
# GRUB in the U-Boot slot; a pacman hook keeps the ESP's Limine current,
# since the limine package's own hook deploys nothing on aarch64. Gated on
# /var/lib/omarchy/limine.enabled (shipped by the image). Every step is
# idempotent.
omarchy-hw-apple-silicon || return 0
[[ ${OMARCHY_MAC_IMAGE_BUILD:-} != 1 ]] || return 0

gate=${OMARCHY_LIMINE_GATE:-/var/lib/omarchy/limine.enabled}
[[ -e $gate ]] || return 0

esp=${OMARCHY_ESP:-/boot/efi}
limine_efi=${OMARCHY_LIMINE_EFI:-/usr/share/limine/BOOTAA64.EFI}
limine_conf_source=${OMARCHY_LIMINE_CONF_SOURCE:-${OMARCHY_PATH}/default/limine/limine.conf}
grub_default=${OMARCHY_GRUB_DEFAULT:-/etc/default/grub}
update_grub_default=${OMARCHY_UPDATE_GRUB_DEFAULT:-/etc/default/update-grub}
limine_default=${OMARCHY_LIMINE_DEFAULT:-/etc/default/limine}
boot_hooks_dir=${OMARCHY_LIMINE_BOOT_HOOKS_DIR:-/etc/boot/hooks/pre.d}
pacman_hooks_dir=${OMARCHY_PACMAN_HOOKS_DIR:-/etc/pacman.d/hooks}
systemd_dir=${OMARCHY_SYSTEMD_DIR:-/etc/systemd/system}
grub_target=${OMARCHY_GRUB_TARGET:-/boot/grub/grub-aa64.efi}
kernel=$(omarchy-mac-kernel) || return 1

if [[ ! -f $limine_efi ]]; then
  echo "limine is not installed; leaving GRUB in place" >&2
  return 0
fi
[[ -f $grub_default ]] || { echo "No $grub_default; cannot derive the kernel command line" >&2; return 0; }
[[ -f $limine_conf_source ]] || { echo "No $limine_conf_source; leaving GRUB in place" >&2; return 0; }
findmnt -no TARGET "$esp" >/dev/null 2>&1 || { echo "The ESP is not mounted at $esp; leaving GRUB in place" >&2; return 0; }

# Keep the previously bootable menu, UKIs and defaults until deployment.
# This also protects a Mac that already boots Limine when a rebuild fails.
limine_backup=$(mktemp -d) || return 1
limine_managed=("$limine_default" "$esp/limine.conf" "$esp/EFI/Linux"
  "$boot_hooks_dir/20-omarchy-mac-cmdline")
for index in "${!limine_managed[@]}"; do
  file=${limine_managed[index]}
  if sudo test -e "$file" || sudo test -L "$file"; then
    sudo cp -a -- "$file" "$limine_backup/$index" || { sudo rm -rf "$limine_backup"; return 1; }
  fi
done

# A failed activation puts everything back: GRUB's update target (and a
# regeneration into the U-Boot slot when it was retargeted here) and the
# Limine defaults this run created, so the Mac does not count as a Limine
# Mac while GRUB still boots it.
# Returns 0: a decline is not a failed install step, and the ERR trap must not
# fire a second rollback on the way out of the caller.
grub_installed() {
  command -v "${OMARCHY_GRUB_PROBE:-grub-probe}" >/dev/null 2>&1 &&
    command -v "${OMARCHY_GRUB_MKCONFIG:-grub-mkconfig}" >/dev/null 2>&1
}

limine_boot_fail() {
  echo "limine-boot: $*; GRUB stays the boot loader" >&2
  if (( update_grub_default_changed )); then
    if [[ -n $update_grub_default_before ]]; then
      printf '%s\n' "$update_grub_default_before" | sudo tee "$update_grub_default" >/dev/null
    else
      sudo rm -f "$update_grub_default"
    fi
    sudo "${OMARCHY_UPDATE_GRUB:-update-grub}" >/dev/null 2>&1 || echo "limine-boot: update-grub failed while restoring GRUB's target" >&2
  fi
  if [[ -n ${limine_backup:-} ]]; then
    for index in "${!limine_managed[@]}"; do
      file=${limine_managed[index]}
      sudo rm -rf -- "$file"
      if sudo test -e "$limine_backup/$index" || sudo test -L "$limine_backup/$index"; then
        sudo mkdir -p "$(dirname "$file")"
        sudo cp -a -- "$limine_backup/$index" "$file" || return 1
      fi
    done
    sudo rm -rf "$limine_backup"
    limine_backup=""
  fi
  update_grub_default_changed=0
  limine_default_created=0
  return 0
}
limine_default_created=0
update_grub_default_changed=0
update_grub_default_before=""
# Any unexpected error rolls back too: under `bash -eE` the leaf stops where
# it is, and a Mac left with Omarchy's Limine defaults while GRUB still owns
# the U-Boot slot would regenerate only the unused recovery image from then on.
limine_boot_trap() {
  local status=$?
  trap - ERR
  limine_boot_fail "a step failed with status $status"
}
trap limine_boot_trap ERR

# 1. The Asahi update-grub keeps running on kernel updates; its EFI image
# goes to a file under /boot instead of the U-Boot slot.
sudo mkdir -p "$esp/EFI/BOOT"
# An image that never shipped GRUB has nothing to retarget. update-grub comes
# from asahi-scripts, which stays for update-m1n1, so GRUB's own tools are
# what says whether it is there.
if grub_installed; then
  if ! grep -Fxq "TARGET=\"$grub_target\"" "$update_grub_default" 2>/dev/null; then
    [[ ! -f $update_grub_default ]] || update_grub_default_before=$(<"$update_grub_default")
    update_grub_default_changed=1
    printf '# Written by Omarchy: Limine owns BOOTAA64.EFI; update-grub writes its image here, unused.\nTARGET="%s"\n' "$grub_target" |
      sudo tee "$update_grub_default" >/dev/null
  fi
  sudo "${OMARCHY_UPDATE_GRUB:-update-grub}" >/dev/null || { limine_boot_fail "update-grub failed with its new target"; return 0; }
fi
sudo rm -f "$esp/EFI/BOOT/grub-aa64.efi"

# 2. Limine's configuration: the static keys here, the kernel command line
# from GRUB's defaults, re-derived before every UKI rebuild.
[[ -f $limine_default ]] || limine_default_created=1
# The ESP override is used by isolated tests; the installed default is /boot/efi.
# Reject shell syntax before writing a configuration sourced by root.
[[ $esp =~ ^/[a-zA-Z0-9_./-]+$ ]] || { limine_boot_fail "invalid ESP path"; return 1; }
sudo tee "$limine_default" >/dev/null <<'CONF'
# Written by Omarchy (install/hardware/apple/limine-boot.sh). KERNEL_CMDLINE
# is derived from /etc/default/grub by omarchy-mac-limine-cmdline; edit GRUB's
# defaults, not this line.
TARGET_OS_NAME="Omarchy"
ENABLE_UKI=yes
CUSTOM_UKI_NAME="omarchy"
FIND_BOOTLOADERS=no
KERNEL_CMDLINE[default]=""
CONF
printf 'ESP_PATH="%s"\nBOOT_ORDER="%s, *, *fallback, Snapshots"\n' "$esp" "$kernel" |
  sudo tee -a "$limine_default" >/dev/null
sudo install -d "$boot_hooks_dir"
sudo ln -sfn "$(command -v omarchy-mac-limine-cmdline)" "$boot_hooks_dir/20-omarchy-mac-cmdline"
sudo omarchy-mac-limine-cmdline || { limine_boot_fail "could not derive the kernel command line"; return 0; }
sudo grep -q '^KERNEL_CMDLINE\[default\]="root=UUID=' "$limine_default" || { limine_boot_fail "no root= in the derived command line"; return 0; }

# 3. Omarchy's Limine menu: the template once, then 3 s like x86.
# limine-entry-tool keys its OS block by machine-id, so a menu written under
# another identity (the image's, or the one before a factory reset) would
# keep an entry pointing at a UKI this machine no longer has. That menu
# starts over from the template, and the stale identity's history goes.
machine_id=$(cat "${OMARCHY_MACHINE_ID:-/etc/machine-id}" 2>/dev/null || true)
stale_ids=$(sudo grep -o 'machine-id=[0-9a-f]\{32\}' "$esp/limine.conf" 2>/dev/null | cut -d= -f2 | sort -u || true)
menu_is_ours=0
if sudo grep -Fq 'interface_branding: Omarchy Bootloader' "$esp/limine.conf" 2>/dev/null; then
  menu_is_ours=1
  for stale_id in $stale_ids; do
    [[ $stale_id == "$machine_id" ]] && continue
    menu_is_ours=0
    # Remove history only after the replacement menu/UKI is committed.
  done
fi
if (( ! menu_is_ours )); then
  sudo install -m600 "$limine_conf_source" "$esp/limine.conf"
fi
sudo sed -i -E 's/^#?[[:space:]]*timeout:.*/timeout: 3/' "$esp/limine.conf"
sudo grep -Eq '^timeout: ' "$esp/limine.conf" || printf 'timeout: 3\n' | sudo tee -a "$esp/limine.conf" >/dev/null

# 4. UKI and entries, before anything replaces GRUB: only a menu that boots
# the kernel unattended earns the U-Boot slot.
echo "Building the Omarchy UKI and Limine entries"
sudo limine-update || { limine_boot_fail "limine-update failed"; return 0; }
sudo test -f "$esp/EFI/Linux/omarchy_$kernel.efi" || { limine_boot_fail "limine-update built no $esp/EFI/Linux/omarchy_$kernel.efi"; return 0; }
sudo grep -Fq "//$kernel" "$esp/limine.conf" || { limine_boot_fail "limine.conf has no $kernel entry"; return 0; }

# 5. The menu is Omarchy's and its snapshots, nothing else: the GRUB recovery
# entry of the experiment is dropped.
if sudo grep -Fq '/GRUB (recovery)' "$esp/limine.conf"; then
  limine_menu=$(mktemp)
  sudo awk '
    /^\/GRUB \(recovery\)$/ { skip = 1; next }
    skip && /^[[:space:]]/ { next }
    skip && /^[[:space:]]*$/ { next }
    { skip = 0; print }
  ' "$esp/limine.conf" >"$limine_menu"
  sudo install -m600 "$limine_menu" "$esp/limine.conf"
  rm -f "$limine_menu"
fi

# 6. Limine as the default EFI application, kept current by a pacman hook.
# From here on the Mac boots Limine: no rollback past this point.
sudo omarchy-mac-limine-deploy || { limine_boot_fail "could not put Limine on the ESP"; return 0; }
update_grub_default_changed=0
limine_default_created=0
trap - ERR
sudo rm -rf "$limine_backup"
limine_backup=""
for stale_id in $stale_ids; do
  [[ $stale_id == "$machine_id" ]] || sudo rm -rf "${esp:?}/$stale_id"
done
sudo install -d "$pacman_hooks_dir"
sudo tee "$pacman_hooks_dir/81-omarchy-mac-limine-deploy.hook" >/dev/null <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/share/limine/BOOTAA64.EFI

[Action]
Description = Deploying Limine to the ESP (Apple Silicon)
When = PostTransaction
Exec = /usr/bin/omarchy-mac-limine-deploy
HOOK

# 7. Snapshot entries as on x86: the watcher writes them.
sudo limine-snapper-sync || echo "limine-snapper-sync did not finish; snapshot entries come with the next snapshot" >&2
sudo systemctl enable --now limine-snapper-sync.service >/dev/null 2>&1 || true

# Leftovers of the experiment: the hand-placed menu, the /boot resync unit.
# /boot/efi/omarchy is the installer's staging directory and stays.
sudo rm -rf "$esp/limine"
if [[ -f $systemd_dir/omarchy-mac-boot-sync.service ]]; then
  sudo systemctl disable omarchy-mac-boot-sync.service >/dev/null 2>&1 || true
  sudo rm -f "$systemd_dir/omarchy-mac-boot-sync.service"
fi
