# Sourced by the shared Omarchy lifecycle; do not run independently.

grub_add_rd_luks_key() {
  local file=$1 uuid=$2
  local token="rd.luks.key=${uuid}=/omarchy/luks-key:UUID=$BOOT_FS_UUID"
  local tmp status=0
  [[ -f $file ]] || return 1
  # Callers may run this where errexit is suppressed: check every step and
  # replace the defaults only with a complete, verified copy.
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if grep -q 'rd.luks.key=' "$file"; then
    sed -E "s|[[:space:]]*rd\\.luks\\.key=[^[:space:]\"]+| ${token}|g" "$file" >"$tmp" || status=1
  elif grep -q '^GRUB_CMDLINE_LINUX=' "$file"; then
    sed -E "s|^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"|\\1 ${token}\"|" "$file" >"$tmp" || status=1
  else
    { cat "$file" && printf 'GRUB_CMDLINE_LINUX="%s"\n' "$token"; } >"$tmp" || status=1
  fi
  if (( status == 0 )) && grep -Fq -- "$token" "$tmp" && chmod --reference="$file" "$tmp" && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

stage_luks_rekey_apple() {
  local next="$1" device="$2" uuid crypttab_src grub_src grub_dst

  uuid=$(cryptsetup luksUUID "$device") || fail "could not read the LUKS UUID of $device"

  crypttab_src=$CRYPTTAB
  [[ -f $crypttab_src ]] && install -Dm644 "$crypttab_src" "$next/etc/crypttab"

  grub_src=$GRUB_DEFAULT
  grub_dst="$next/etc/default/grub"
  if [[ -f $grub_src ]]; then
    install -Dm644 "$grub_src" "$grub_dst"
  elif [[ -f $grub_dst ]]; then
    :
  else
    fail "no /etc/default/grub to stage the LUKS cmdline"
  fi
  grub_add_rd_luks_key "$grub_dst" "$uuid" || fail "could not stage the LUKS unlock in $grub_dst"
}

rebuild_next_boot_apple() {
  local next="$1" dir kernel pkgbase
  local boot_dir=${OMARCHY_BOOT_DIR:-/boot}
  local -a kernel_images=()
  kernel=$(omarchy-mac-kernel) || fail "cannot identify the Apple kernel"
  for pkgbase in "$next"/usr/lib/modules/*/pkgbase; do
    [[ -f $pkgbase ]] || continue
    [[ $(<"$pkgbase") == "$kernel" ]] || continue
    kernel_images+=("${pkgbase%/pkgbase}/vmlinuz")
  done
  # Firmware on the ESP is outside this subvolume reset. Refuse a snapshot
  # from another kernel rather than boot it with unrelated stage-two DTBs.
  (( ${#kernel_images[@]} == 1 )) && cmp -s "${kernel_images[0]}" "$boot_dir/vmlinuz-$kernel" ||
    fail "the factory kernel differs from /boot; a coordinated boot-package restore is required"

  # The rebuild below writes the live Boot partition and ESP while the old
  # root still boots. Keep their prior state until the reset commits.
  backup_live_boot_files

  for dir in proc sys dev run boot; do
    mkdir -p "$next/$dir"
    if [[ -d /$dir ]]; then
      mount --rbind "/$dir" "$next/$dir"
      mount --make-rslave "$next/$dir"
    fi
  done

  # A Limine Mac: the ESP's menu starts over from the template, so the
  # previous identity's entries (stale UKI hashes) do not survive the reset.
  # A factory root that predates its own Limine activation (the image state)
  # regenerates GRUB into the U-Boot slot below and activates Limine again on
  # its first boot; one that carries the Limine defaults rebuilds the UKI and
  # entries here.
  if omarchy-mac-limine-active; then
    reset_limine_config "$next" /boot/efi
  fi

  log "Rebuilding initramfs and the boot loader from the factory system (this can take a minute)"
  if ! chroot "$next" mkinitcpio -P </dev/null >>"$LOG_FILE" 2>&1; then
    fail "mkinitcpio failed in the factory root (see $LOG_FILE)"
  fi
  # A factory root from before the Limine work has no omarchy-mac-boot-update.
  if [[ -x $next$OMARCHY_PATH/bin/omarchy-mac-boot-update || -x $next/usr/bin/omarchy-mac-boot-update ]]; then
    if ! chroot "$next" omarchy-mac-boot-update >>"$LOG_FILE" 2>&1; then
      fail "omarchy-mac-boot-update failed in the factory root (see $LOG_FILE)"
    fi
    if chroot "$next" omarchy-mac-limine-active >/dev/null 2>&1; then
      verify_limine_hashes "$next" /boot/efi
    fi
  elif ! chroot "$next" update-grub >>"$LOG_FILE" 2>&1; then
    fail "update-grub failed in the factory root (see $LOG_FILE)"
  fi
  # m1n1 and U-Boot are outside the snapshot. A factory reset must not
  # select stale DTBs from preserved module directories or replace firmware.

  # The vfat ESP keeps the rebuilt menu in the page cache: flush it before the
  # reset adds any credential, or a power loss leaves the template menu.
  sync || fail "could not flush the rebuilt boot files"

  for dir in boot run dev sys proc; do
    umount -R "$next/$dir" 2>/dev/null || true
  done
}

# Boot files the reset rebuild writes, relative to the live /boot: the
# initramfs images, GRUB's directory, and on the ESP the Limine menu, UKIs,
# loader slot and per-machine-id history.
reset_boot_file_owned() {
  local rel=$1
  case $rel in
    initramfs-*.img | grub | efi/limine.conf | efi/EFI/Linux | efi/EFI/BOOT/BOOTAA64.EFI) return 0 ;;
  esac
  [[ $rel =~ ^efi/[0-9a-f]{32}$ ]]
}

reset_boot_file_candidates() {
  local boot=$1 path
  for path in "$boot"/initramfs-*.img "$boot/grub" "$boot/efi/limine.conf" "$boot/efi/EFI/Linux" \
    "$boot/efi/EFI/BOOT/BOOTAA64.EFI" "$boot"/efi/*; do
    [[ -e $path || -L $path ]] || continue
    printf '%s\n' "${path#"$boot"/}"
  done | sort -u | while IFS= read -r rel; do
    if reset_boot_file_owned "$rel"; then printf '%s\n' "$rel"; fi
  done
}

# Rollback is armed (RESET_BOOT_BACKUP set) only once every copy is complete
# and synced; a failed backup leaves the live files untouched.
backup_live_boot_files() {
  local boot=${OMARCHY_BOOT_DIR:-/boot} backup rel
  backup=$(mktemp -d "${OMARCHY_RESET_BACKUP_PARENT:-/run}/omarchy-reset-boot.XXXXXX") ||
    fail "could not create a backup of the boot files"
  if ! reset_boot_file_candidates "$boot" >"$backup/manifest.partial" || ! mkdir -p "$backup/tree"; then
    rm -rf -- "$backup"
    fail "could not prepare a backup of the boot files"
  fi
  while IFS= read -r rel; do
    if ! (cd "$boot" && cp -a --parents -- "$rel" "$backup/tree/"); then
      rm -rf -- "$backup"
      fail "could not back up $boot/$rel; no boot file was changed"
    fi
  done <"$backup/manifest.partial"
  if ! sync -f "$backup/manifest.partial" || ! mv -- "$backup/manifest.partial" "$backup/manifest"; then
    rm -rf -- "$backup"
    fail "could not finish the backup of the boot files"
  fi
  RESET_BOOT_BACKUP=$backup
}

# Stage the saved copy beside the target before replacing it, so a failed copy
# never leaves the path missing. A full filesystem (the rebuild can fill the
# ESP) cannot stage: then the rebuilt copy makes room for the verified backup.
restore_one_boot_file() {
  local boot=$1 rel=$2 staged
  staged="$boot/$rel.omarchy-restore"
  rm -rf -- "$staged" || return 1
  mkdir -p -- "$(dirname -- "$boot/$rel")" || return 1
  if cp -a -- "$RESET_BOOT_BACKUP/tree/$rel" "$staged"; then
    rm -rf -- "${boot:?}/$rel" && mv -- "$staged" "$boot/$rel"
    return
  fi
  rm -rf -- "$staged" "${boot:?}/$rel" && cp -a -- "$RESET_BOOT_BACKUP/tree/$rel" "$boot/$rel"
}

# The saved menu may go back only when every UKI it names is on the ESP with
# the hash it records; otherwise Limine would refuse to boot it.
old_menu_matches_live_ukis() {
  local boot=$1 line path hash
  while IFS= read -r line; do
    path=${line#boot():}
    path=${path%%#*}
    hash=${line##*#}
    [[ -f $boot/efi$path && $(b2sum "$boot/efi$path" | cut -d' ' -f1) == "$hash" ]] || return 1
  done < <(grep -o 'boot():/EFI/Linux/[^#[:space:]]*#[0-9a-f]*' "$RESET_BOOT_BACKUP/tree/efi/limine.conf")
}

# Put the live boot files back exactly as they were before the rebuild. The
# old menu goes back last, and only if the UKIs it names are back too; a
# partial restore otherwise keeps the rebuilt menu.
restore_live_boot_files() {
  local boot=${OMARCHY_BOOT_DIR:-/boot} rel failed=0
  [[ -n ${RESET_BOOT_BACKUP:-} && -f $RESET_BOOT_BACKUP/manifest ]] || return 0
  while IFS= read -r rel; do
    [[ $rel == "efi/limine.conf" ]] && continue
    grep -Fxq -- "$rel" "$RESET_BOOT_BACKUP/manifest" || rm -rf -- "${boot:?}/$rel" || failed=1
  done < <(reset_boot_file_candidates "$boot")
  while IFS= read -r rel; do
    [[ $rel == "efi/limine.conf" ]] || restore_one_boot_file "$boot" "$rel" || failed=1
  done <"$RESET_BOOT_BACKUP/manifest"
  if ! grep -Fxq efi/limine.conf "$RESET_BOOT_BACKUP/manifest"; then
    (( failed )) || rm -f -- "$boot/efi/limine.conf" || failed=1
  elif old_menu_matches_live_ukis "$boot"; then
    restore_one_boot_file "$boot" efi/limine.conf || failed=1
  else
    failed=1
  fi
  sync
  if (( failed )); then
    echo "Could not fully restore the boot files; the previous copies are in $RESET_BOOT_BACKUP until reboot" >&2
    return 1
  fi
  echo "Restored the previous boot files" >&2
  discard_live_boot_backup
}

discard_live_boot_backup() {
  [[ -n ${RESET_BOOT_BACKUP:-} ]] || return 0
  rm -rf -- "$RESET_BOOT_BACKUP"
  RESET_BOOT_BACKUP=""
}
