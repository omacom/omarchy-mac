# Sourced by the shared Omarchy lifecycle; do not run independently.

grub_add_rd_luks_key() {
  local file=$1 uuid=$2
  local token="rd.luks.key=${uuid}=/omarchy/luks-key:UUID=$BOOT_FS_UUID"
  [[ -f $file ]] || return 1
  if grep -q 'rd.luks.key=' "$file"; then
    local tmp
    tmp=$(mktemp)
    sed -E "s|[[:space:]]*rd\\.luks\\.key=[^[:space:]\"]+| ${token}|g" "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
    return 0
  fi
  if grep -q '^GRUB_CMDLINE_LINUX=' "$file"; then
    sed -i -E "s|^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"|\\1 ${token}\"|" "$file"
  else
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "$token" >>"$file"
  fi
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
  grub_add_rd_luks_key "$grub_dst" "$uuid"
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

  for dir in boot run dev sys proc; do
    umount -R "$next/$dir" 2>/dev/null || true
  done
}
