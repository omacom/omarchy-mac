# Sourced, after provision.sh, by the factory reset entrypoints in
# /usr/lib/omarchy/mac-boot (reset-prepare, reset-verify, reset-commit and
# reset-rollback), which omarchy-lifecycle-dispatch runs; do not run
# independently. The runtime's docs/lifecycle-dispatch.md is their contract.
#
# One reset runs them within one boot: prepare and verify while the previous
# root still boots, then commit once the factory root is the active one, or
# rollback when anything failed before that. prepare keeps what the others
# need in RESET_DIR on /run (the previous boot files and encrypt.state, the ESP
# and the LUKS UUID of an encrypted root), so a reboot ends the reset.

RESET_DIR=$MAC_BOOT_ROOT/run/omarchy-mac-boot/reset
RESET_STATE=$RESET_DIR/state
LIVE_BOOT=$MAC_BOOT_ROOT/boot

reset_state_get() {
  state_get "$RESET_STATE" "$1" || true
}

reset_prepared() {
  [[ $(reset_state_get prepared) == 1 ]]
}

# The ESP as a path prefix below /boot: "efi/", or "" where the ESP is /boot.
esp_prefix() {
  printf '%s' "${1:+$1/}"
}

# The clone the reset activates, never the running root.
require_factory_root() {
  [[ ${1:-} == /* && -d $1/usr/lib/modules && ! $1 -ef / && ! $1 -ef "$MAC_BOOT_ROOT/" ]] ||
    refuse "Name the factory root the reset activates."
}

# The sealed @factory snapshot the reset cloned the factory root from, beside
# it at the top of the filesystem.
factory_baseline() {
  local baseline=${1%/*}/@factory
  [[ -d $baseline && ! -L $baseline && ! $baseline -ef $1 ]] || return 1
  printf '%s\n' "$baseline"
}

# A fresh image's first-boot state, relative to a root. A pending first boot
# with the conversion token (deferred-steps) is what the initramfs encrypts in
# place, and install.conf is the previous install's choice.
FIRST_BOOT_STATE=(
  var/lib/omarchy/mac-first-boot/pending
  var/lib/omarchy/mac-first-boot/deferred-steps
  var/lib/omarchy/mac-first-boot/install.conf
  boot/efi/omarchy/install.conf
)

# @factory keeps none of it, nor owner setup's markers, so neither a later
# reset nor a restore of @factory brings them back. It is unsealed only when
# there is something to remove, and always sealed again.
scrub_factory_baseline() {
  local baseline=$1 rel status=0
  local -a found=()
  for rel in "${FIRST_BOOT_STATE[@]}" var/lib/omarchy/provisioning/pending var/lib/omarchy/provisioning/wipe-pending; do
    [[ ! -e $baseline/$rel && ! -L $baseline/$rel ]] || found+=("$baseline/$rel")
  done
  (( ${#found[@]} )) || return 0
  btrfs property set -ts "$baseline" ro false || return 1
  rm -f -- "${found[@]}" || status=1
  btrfs property set -ts "$baseline" ro true || status=1
  return "$status"
}

# The factory root boots into this Mac's first boot again, without the
# conversion token or the previous install.conf. Owner setup's markers are the
# caller's.
arm_factory_first_boot() {
  local next=$1 rel dir=$1/var/lib/omarchy/mac-first-boot
  for rel in "${FIRST_BOOT_STATE[@]}"; do
    rm -f -- "${next:?}/$rel" || return 1
  done
  install -d -m 0755 "$dir" && install -m 0644 /dev/null "$dir/pending"
}

# Firmware, m1n1 and its device trees are on the ESP, outside the snapshot, and
# match the kernel in /boot. The factory root must carry that same kernel, or
# its boot files would pair it with another kernel's device trees.
factory_kernel_coherent() {
  local next=$1 kernel pkgbase
  local -a images=()
  kernel=$(omarchy-mac-kernel) || return 1
  for pkgbase in "$next"/usr/lib/modules/*/pkgbase; do
    [[ -f $pkgbase && $(<"$pkgbase") == "$kernel" ]] || continue
    images+=("${pkgbase%/pkgbase}/vmlinuz")
  done
  if (( ${#images[@]} == 1 )) && cmp -s "${images[0]}" "$LIVE_BOOT/vmlinuz-$kernel"; then
    return 0
  fi
  log_step "the factory kernel differs from /boot/vmlinuz-$kernel"
  return 1
}

# The ESP this Mac boots from, relative to /boot (efi, or empty for /boot).
# A Limine Mac must also be writing Limine there.
reset_esp() {
  local esp
  esp=$(omarchy-mac-esp) || return 1
  esp_selected || return 1
  esp=${esp#/boot}
  printf '%s\n' "${esp#/}"
}

grub_add_rd_luks_key() {
  local file=$1 uuid=$2
  local token="rd.luks.key=${uuid}=/omarchy/luks-key:UUID=$BOOT_UUID"
  local tmp status=0
  [[ -f $file ]] || return 1
  # Check every step and replace the defaults only with a complete, verified
  # copy.
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

# The factory root was snapshotted before the first boot encrypted the disk:
# it gets the live crypttab and GRUB defaults, with rd.luks.key= naming the
# Boot partition key reset-commit writes.
stage_reset_unlock() {
  local next=$1 uuid=$2 grub=$1/etc/default/grub
  if [[ -f $CRYPTTAB ]]; then
    install -Dm644 "$CRYPTTAB" "$next/etc/crypttab" || return 1
  fi
  if [[ -f $GRUB_DEFAULT ]]; then
    install -Dm644 "$GRUB_DEFAULT" "$grub" || return 1
  elif [[ ! -f $grub ]]; then
    log_step "no /etc/default/grub to stage the LUKS command line"
    return 1
  fi
  grub_add_rd_luks_key "$grub" "$uuid"
}

# The ESP's menu starts over from the factory root's template, so the previous
# identity's entries (stale UKI hashes) do not survive the reset. Only the
# history of machine-ids the old menu named goes: a shared ESP may hold other
# installations' directories.
reset_limine_menu() {
  local next=$1 esp=$2 conf template machine_id old_ids="" old_id
  conf=$LIVE_BOOT/${esp}limine.conf
  if [[ -f $conf ]]; then
    old_ids=$(grep -o 'machine-id=[0-9a-f]\{32\}' "$conf" | cut -d= -f2 | sort -u) || true
  fi
  for template in "$next/usr/share/omarchy/install/assets/limine/limine.conf" \
    "$next/usr/share/omarchy/default/limine/limine.conf"; do
    [[ -f $template ]] && break
    template=""
  done
  if [[ -z $template ]]; then
    log_step "the factory root has no limine.conf template"
    return 1
  fi
  cp -- "$template" "$conf" || return 1
  machine_id=$(cat "$next/etc/machine-id" 2>/dev/null) || true
  for old_id in $old_ids; do
    [[ $old_id == "$machine_id" ]] || rm -rf -- "${LIVE_BOOT:?}/${esp}$old_id" || return 1
  done
}

FACTORY_ROOT_BOUND=()

# The caller deletes the clone next: a bind that will not unmount is detached
# lazily rather than left inside it.
unbind_factory_root() {
  local dir
  for dir in "${FACTORY_ROOT_BOUND[@]}"; do
    umount -R "$dir" 2>/dev/null || umount -R -l "$dir" 2>/dev/null || true
  done
  FACTORY_ROOT_BOUND=()
}

# Rebuild the initramfs and the loader from inside the factory root, on the
# live Boot partition and ESP, so they match its modules and command line. m1n1
# and U-Boot stay: a reset replaces neither firmware nor device trees.
rebuild_factory_boot() {
  local next=$1 dir update=""
  trap unbind_factory_root EXIT
  for dir in proc sys dev run boot; do
    mkdir -p "$next/$dir" || return 1
    if [[ -d $MAC_BOOT_ROOT/$dir ]]; then
      mount --rbind "$MAC_BOOT_ROOT/$dir" "$next/$dir" || return 1
      FACTORY_ROOT_BOUND=("$next/$dir" "${FACTORY_ROOT_BOUND[@]}")
      mount --make-rslave "$next/$dir" || return 1
    fi
  done

  log_step "Rebuilding the initramfs and the boot loader from the factory system"
  if ! chroot "$next" mkinitcpio -P </dev/null >&2; then
    log_step "mkinitcpio failed in the factory root"
    return 1
  fi
  # A factory root from before the Limine work has no omarchy-mac-boot-update.
  for update in /usr/bin/omarchy-mac-boot-update /usr/share/omarchy/bin/omarchy-mac-boot-update; do
    [[ -x $next$update ]] && break
    update=""
  done
  if [[ -n $update ]]; then
    chroot "$next" "$update" </dev/null >&2 || {
      log_step "omarchy-mac-boot-update failed in the factory root"
      return 1
    }
  elif ! chroot "$next" update-grub </dev/null >&2; then
    log_step "update-grub failed in the factory root"
    return 1
  fi
  # The vfat ESP keeps the rebuilt menu in the page cache: flush it before the
  # reset adds any credential, or a power loss leaves the template menu.
  sync || {
    log_step "could not flush the rebuilt boot files"
    return 1
  }
  unbind_factory_root
}

# Boot files the rebuild writes, relative to /boot: the initramfs images,
# GRUB's directory, and on the ESP the Limine menu, UKIs, loader slot and
# per-machine-id history.
reset_boot_file_owned() {
  local rel=$1 esp=$2
  case $rel in
    initramfs-*.img | grub | "${esp}limine.conf" | "${esp}EFI/Linux" | "${esp}EFI/BOOT/BOOTAA64.EFI") return 0 ;;
  esac
  [[ $rel == "$esp"* && ${rel#"$esp"} =~ ^[0-9a-f]{32}$ ]]
}

reset_boot_file_candidates() {
  local boot=$1 esp=$2 path rel
  for path in "$boot"/initramfs-*.img "$boot/grub" "$boot/${esp}limine.conf" "$boot/${esp}EFI/Linux" \
    "$boot/${esp}EFI/BOOT/BOOTAA64.EFI" "$boot/$esp"*; do
    [[ -e $path || -L $path ]] || continue
    printf '%s\n' "${path#"$boot"/}"
  done | sort -u | while IFS= read -r rel; do
    if reset_boot_file_owned "$rel" "$esp"; then printf '%s\n' "$rel"; fi
  done
}

# Rollback is armed (the manifest exists) only once every copy is complete; a
# failed backup changes no live file.
backup_live_boot_files() {
  local esp=$1 backup=$RESET_DIR/boot rel
  rm -rf -- "$backup" && mkdir -p -- "$backup/tree" || return 1
  if ! reset_boot_file_candidates "$LIVE_BOOT" "$esp" >"$backup/manifest.partial"; then
    rm -rf -- "$backup"
    return 1
  fi
  while IFS= read -r rel; do
    if ! (cd "$LIVE_BOOT" && cp -a --parents -- "$rel" "$backup/tree/"); then
      log_step "could not back up /boot/$rel"
      rm -rf -- "$backup"
      return 1
    fi
  done <"$backup/manifest.partial"
  if ! sync -f "$backup/manifest.partial" || ! mv -- "$backup/manifest.partial" "$backup/manifest"; then
    rm -rf -- "$backup"
    return 1
  fi
}

# Stage the saved copy beside the target before replacing it, so a failed copy
# never leaves the path missing. A full filesystem (the rebuild can fill the
# ESP) cannot stage: then the rebuilt copy makes room for the verified backup.
restore_one_boot_file() {
  local rel=$1 saved=$RESET_DIR/boot/tree/$1 staged
  staged="$LIVE_BOOT/$rel.omarchy-restore"
  rm -rf -- "$staged" || return 1
  mkdir -p -- "$(dirname -- "$LIVE_BOOT/$rel")" || return 1
  if cp -a -- "$saved" "$staged"; then
    rm -rf -- "${LIVE_BOOT:?}/$rel" && mv -- "$staged" "$LIVE_BOOT/$rel"
    return
  fi
  rm -rf -- "$staged" "${LIVE_BOOT:?}/$rel" && cp -a -- "$saved" "$LIVE_BOOT/$rel"
}

# Active path directives (Limine keys are case-insensitive; image_path is an
# alias) that name a UKI on the ESP. Comment lines are skipped.
limine_menu_uki_paths() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/ || index(line, ":") == 0) next
      key = tolower(substr(line, 1, index(line, ":") - 1))
      if (key != "path" && key != "image_path") next
      value = substr(line, index(line, ":") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value ~ /^boot\(\):\/EFI\/Linux\//) print value
    }
  ' "$1"
}

# Every UKI the menu names is on the ESP with the hash it records; otherwise
# Limine refuses to boot it. $1 is the menu, $2 the ESP directory.
menu_matches_ukis() {
  local menu=$1 esp_dir=$2 value path hash
  while IFS= read -r value; do
    [[ $value == *"#"* ]] || return 1
    path=${value#boot():}
    path=${path%%#*}
    hash=${value##*#}
    [[ -f $esp_dir$path && $(b2sum "$esp_dir$path" | cut -d' ' -f1) == "$hash" ]] || return 1
  done < <(limine_menu_uki_paths "$menu")
}

# Put the live boot files back exactly as they were before the rebuild. The
# old menu goes back last, and only if the UKIs it names are back too; a
# partial restore otherwise keeps the rebuilt menu.
restore_live_boot_files() {
  local backup=$RESET_DIR/boot esp menu rel failed=0
  [[ -f $backup/manifest ]] || return 0
  esp=$(esp_prefix "$(reset_state_get esp)")
  menu=${esp}limine.conf
  while IFS= read -r rel; do
    [[ $rel == "$menu" ]] && continue
    grep -Fxq -- "$rel" "$backup/manifest" || rm -rf -- "${LIVE_BOOT:?}/$rel" || failed=1
  done < <(reset_boot_file_candidates "$LIVE_BOOT" "$esp")
  while IFS= read -r rel; do
    [[ $rel == "$menu" ]] || restore_one_boot_file "$rel" || failed=1
  done <"$backup/manifest"
  if ! grep -Fxq -- "$menu" "$backup/manifest"; then
    (( failed )) || rm -f -- "${LIVE_BOOT:?}/$menu" || failed=1
  elif menu_matches_ukis "$backup/tree/$menu" "$LIVE_BOOT/${esp%/}"; then
    restore_one_boot_file "$menu" || failed=1
  else
    failed=1
  fi
  sync
  (( failed == 0 )) || return 1
  log_step "Restored the previous boot files"
  rm -rf -- "$backup"
}

# The previous owner's finished re-key goes back to configured, without their
# slots, so the next owner's setup re-keys again. A declined encryption stays
# declined. The prior state is kept for rollback.
reopen_encrypt_state() {
  local tmp
  [[ -f $ENCRYPT_STATE ]] || return 0
  ! grep -Fxq 'phase=declined' "$ENCRYPT_STATE" || return 0
  cp -- "$ENCRYPT_STATE" "$RESET_DIR/encrypt.state" || return 1
  tmp=$(mktemp "$ENCRYPT_STATE.XXXXXX") || return 1
  if sed -e 's/^phase=.*/phase=configured/' -e '/^owner_slot=/d' -e '/^recovery_slot=/d' "$ENCRYPT_STATE" >"$tmp" &&
    chmod 0644 "$tmp" && sync "$tmp" && mv -f "$tmp" "$ENCRYPT_STATE"; then
    sync "$(dirname "$ENCRYPT_STATE")"
    return
  fi
  rm -f "$tmp"
  return 1
}

restore_encrypt_state() {
  local saved=$RESET_DIR/encrypt.state tmp
  [[ -f $saved ]] || return 0
  tmp=$(mktemp "$ENCRYPT_STATE.XXXXXX") || return 1
  if cp -- "$saved" "$tmp" && chmod 0644 "$tmp" && sync "$tmp" && mv -f "$tmp" "$ENCRYPT_STATE" &&
    sync "$(dirname "$ENCRYPT_STATE")"; then
    rm -f -- "$saved"
    return 0
  fi
  rm -f "$tmp"
  log_step "could not restore $ENCRYPT_STATE"
  return 1
}

# The factory root's first boot unlocks with this key until its owner's setup
# re-keys the disk. Written only once the factory root is the active root, so a
# power loss before that leaves the previous root asking for its password.
install_reset_boot_key() {
  local staged
  install -d -m 755 "$(dirname "$BOOT_LUKS_KEY")" || return 1
  staged=$(mktemp "$BOOT_LUKS_KEY.XXXXXX") || return 1
  if (umask 077 && cat >"$staged") && [[ -s $staged ]] && chmod 600 "$staged" && sync "$staged" &&
    mv -f "$staged" "$BOOT_LUKS_KEY" && sync "$(dirname "$BOOT_LUKS_KEY")"; then
    return 0
  fi
  rm -f "$staged"
  return 1
}

# The factory system boots on the menu the reset rebuilt: an entry for its
# machine-id, and every UKI the menu names on the ESP with its recorded hash.
limine_menu_boots() {
  local next=$1 esp=$2 menu machine_id
  menu=$LIVE_BOOT/${esp}limine.conf
  [[ -f $menu ]] || { log_step "there is no /boot/${esp}limine.conf"; return 1; }
  machine_id=$(cat "$next/etc/machine-id" 2>/dev/null) || true
  [[ -n $machine_id ]] && grep -Fq "machine-id=$machine_id" "$menu" ||
    { log_step "the Limine menu has no entry for the factory system"; return 1; }
  [[ -n $(limine_menu_uki_paths "$menu") ]] || { log_step "the Limine menu names no UKI"; return 1; }
  menu_matches_ukis "$menu" "$LIVE_BOOT/${esp%/}" ||
    { log_step "a UKI the Limine menu names is missing or does not match its hash"; return 1; }
}

# The factory root boots Limine once it carries Limine's gate and defaults;
# one from before its own Limine activation boots GRUB until its first boot.
factory_limine() {
  [[ -e $1/var/lib/omarchy/limine.enabled && -f $1/etc/default/limine ]]
}

reset_prepare() {
  local next=${1:-} device=${2:-} uuid="" esp baseline
  require_apple_silicon
  (( $# == 1 || $# == 2 )) || refuse "Usage: reset-prepare <factory-root> [<luks-device>]"
  require_factory_root "$next"
  baseline=$(factory_baseline "$next") || refuse "The factory root is not a clone beside the @factory snapshot."
  require_boot_partition
  [[ ! -e $RESET_DIR ]] ||
    refuse "A failed reset's boot files are still saved in /run/omarchy-mac-boot/reset. Restart before resetting again."
  if [[ -n $device ]]; then
    [[ -e $device ]] || refuse "The encrypted disk $device is missing."
    uuid=$(cryptsetup luksUUID "$device") && [[ $uuid =~ ^[0-9a-fA-F-]+$ ]] ||
      refuse "Could not read the LUKS UUID of $device."
  fi
  factory_kernel_coherent "$next" ||
    refuse "The factory system's kernel differs from the one this Mac boots. Resetting needs a coordinated boot-package restore."
  esp=$(reset_esp) ||
    refuse "The EFI partition this Mac boots from is not where its boot files are written."

  install -d -m 700 "$RESET_DIR" && printf 'esp=%s\nluks_uuid=%s\n' "$esp" "$uuid" >"$RESET_STATE" ||
    refuse "Could not record the reset in /run/omarchy-mac-boot/reset."
  backup_live_boot_files "$(esp_prefix "$esp")" ||
    refuse "Could not save the current boot files. Nothing was changed."
  scrub_factory_baseline "$baseline" || refuse "Could not remove the first-boot markers from the @factory snapshot."
  arm_factory_first_boot "$next" || refuse "Could not arm the factory system's first boot."
  if [[ -n $uuid ]]; then
    stage_reset_unlock "$next" "$uuid" || refuse "Could not stage the factory system's disk unlock."
  fi
  if limine_mac; then
    reset_limine_menu "$next" "$(esp_prefix "$esp")" || refuse "Could not start the Limine menu over."
  fi
  rebuild_factory_boot "$next" || refuse "Could not rebuild the boot files from the factory system."
  # Before the caller adds the temporary key: a power loss after activation
  # must never leave phase=finished behind.
  if [[ -n $uuid ]]; then
    reopen_encrypt_state || refuse "Could not reopen the disk encryption state for the next owner."
  fi
  printf 'prepared=1\n' >>"$RESET_STATE" || refuse "Could not record the reset in /run/omarchy-mac-boot/reset."
}

reset_verify() {
  local next=${1:-} esp uuid kernel token
  require_apple_silicon
  (( $# == 1 )) || refuse "Usage: reset-verify <factory-root>"
  require_factory_root "$next"
  require_boot_partition
  reset_prepared || refuse "No factory reset is prepared on this boot."
  esp=$(esp_prefix "$(reset_state_get esp)")
  uuid=$(reset_state_get luks_uuid)

  factory_kernel_coherent "$next" ||
    refuse "The factory system's kernel differs from the one this Mac boots."
  kernel=$(omarchy-mac-kernel) || refuse "Cannot tell which Apple kernel this Mac boots."
  [[ -s $LIVE_BOOT/initramfs-$kernel.img ]] || refuse "There is no rebuilt initramfs for $kernel."
  if [[ -n $uuid ]]; then
    initramfs_orders_firmware ||
      refuse "The factory system's boot image would ask for the disk password before the keyboard firmware loads."
    token="rd.luks.key=$uuid=/omarchy/luks-key:UUID=$BOOT_UUID"
    grep -Fq -- "$token" "$next/etc/default/grub" ||
      refuse "The factory system's GRUB defaults do not unlock its disk at the next boot."
  fi
  if factory_limine "$next"; then
    limine_menu_boots "$next" "$esp" || refuse "The Limine menu does not boot the factory system."
    [[ -z $uuid ]] || grep -Fq -- "$token" "$next/etc/default/limine" ||
      refuse "The factory system's Limine command line does not unlock its disk at the next boot."
  else
    [[ -f $GRUB_CFG ]] || refuse "There is no rebuilt /boot/grub/grub.cfg."
    [[ -z $uuid ]] || grep -Fq -- "$token" "$GRUB_CFG" ||
      refuse "The rebuilt grub.cfg does not unlock the disk at the next boot."
  fi
}

# The unlock key arrives on standard input, never in arguments.
reset_commit() {
  local uuid status=0
  require_apple_silicon
  (( $# == 0 )) || refuse "Usage: reset-commit < key"
  require_boot_partition
  reset_prepared || refuse "No factory reset is prepared on this boot."
  uuid=$(reset_state_get luks_uuid)
  if [[ -n $uuid ]]; then
    install_reset_boot_key || status=1
  fi
  # The factory root is active: nothing is left to roll back to.
  rm -rf -- "$RESET_DIR" 2>/dev/null || true
  (( status == 0 )) ||
    refuse "Could not write the temporary unlock key; the next boot asks for the current disk password once."
}

reset_rollback() {
  local failed=0
  require_apple_silicon
  (( $# == 0 )) || refuse "Usage: reset-rollback"
  [[ -d $RESET_DIR ]] || return 0
  restore_live_boot_files || failed=1
  restore_encrypt_state || failed=1
  (( failed == 0 )) ||
    refuse "Could not fully restore the previous boot files; their copies stay in /run/omarchy-mac-boot/reset until the next boot."
  rm -rf -- "$RESET_DIR"
}
