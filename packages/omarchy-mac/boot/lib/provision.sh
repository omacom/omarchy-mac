# Sourced by the shared Omarchy lifecycle; do not run independently.

grub_drop_rd_luks_key() {
  local file=${1:-$GRUB_DEFAULT} tmp
  [[ -f $file ]] || return 1
  grep -q 'rd.luks.key=' "$file" || return 0
  # Runs under `||`, where errexit is off: check every step and replace the
  # defaults durably, never truncating them on a failed write.
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if sed -E 's/[[:space:]]*rd\.luks\.key=[^[:space:]"]+//g' "$file" >"$tmp" &&
    ! grep -q 'rd.luks.key=' "$tmp" && grep -q '^GRUB_CMDLINE_LINUX' "$tmp" &&
    chmod --reference="$file" "$tmp" && sync "$tmp" && mv -f "$tmp" "$file"; then
    sync "$(dirname "$file")"
    return
  fi
  rm -f "$tmp"
  return 1
}

apple_rekey_boot() {
  [[ -f $GRUB_DEFAULT ]] || {
    log_step "no $GRUB_DEFAULT to drop rd.luks.key="
    say --foreground 1 "Could not update GRUB to drop the auto-unlock key."
    return 1
  }
  if grep -q 'rd.luks.key=' "$GRUB_DEFAULT"; then
    grub_drop_rd_luks_key "$GRUB_DEFAULT" || return 1
  fi
  if ! mkinitcpio -P </dev/null >>"$LOG_FILE" 2>&1 ||
    ! omarchy-mac-boot-update >>"$LOG_FILE" 2>&1; then
    log_step "mkinitcpio or omarchy-mac-boot-update failed during re-key; will retry from phase=rekeyed"
    say --foreground 1 "Could not rebuild boot files after the LUKS re-key; will retry."
    return 1
  fi
}
