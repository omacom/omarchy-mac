# LUKS slot retirement is separate from boot generation. Every retry proves
# the same device, owner credential/slot and published boot bytes again.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/reset-boot.sh"

owner_rekey_slots() {
  local metadata slots
  metadata=$(cryptsetup luksDump --dump-json-metadata "$1") || return $?
  slots=$(jq -er '.keyslots | keys[]' <<<"$metadata") || return $?
  [[ -n $slots ]] || return 1
  local slot
  while IFS= read -r slot; do [[ $slot =~ ^[0-9]+$ && $slot -le 31 ]] || return 1; done <<<"$slots"
  LC_ALL=C sort -n <<<"$slots"
}
owner_rekey_boot_check() {
  local state=$1 digest path extra count=0
  reset_private_file "$state/boot-manifest" || return 1
  local -A seen=()
  while read -r digest path extra; do
    [[ -z $extra && $digest =~ ^[a-f0-9]{64}$ && ($path == /boot/* || $path == /efi/*) && $path != *'/../'* && ! ${seen[$path]+yes} ]] || return 1
    [[ -f $path && ! -L $path && $(sha256sum "$path") == "$digest  "* ]] || return 1
    seen[$path]=1; count=$((count + 1))
  done <"$state/boot-manifest"
  (( count > 0 ))
}
owner_rekey_boot_prepare() {
  local state=$1 work digest relative extra
  reset_boot_probe / || return $?
  if [[ $RESET_BOOT_BACKEND == grub ]]; then
    work=$(mktemp -d "$state/grub.XXXXXXXX") || return $?
    rmdir "$work" || return $?
    reset_boot_prepare / "$work" owner || return $?
    reset_boot_backup "$work" owner || return $?
    if ! reset_boot_publish "$work" owner; then
      reset_boot_rollback "$work" owner || {
        reset_error "Owner boot rollback incomplete; preserve $work and do not reboot"; return 1;
      }
      return 1
    fi
    : >"$state/boot-manifest"
    while read -r digest relative extra; do printf '%s  /boot/%s\n' "$digest" "${relative#./}" >>"$state/boot-manifest" || return $?; done <"$work/manifest"
  else
    # Supplied by the existing Limine provisioning command; retains its
    # template rebuild, auto-unlock fallback and actual UKI hash collection.
    owner_rekey_limine_boot "$state" || return $?
  fi
  chmod 600 "$state/boot-manifest" || return $?
  owner_rekey_boot_check "$state" || return $?
  sync -f "$state/boot-manifest"
}
owner_rekey_remove_auto_unlock() {
  rm -f /etc/omarchy/provisioning.key \
    /etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf \
    /etc/default/grub.d/99-omarchy-provisioning-unlock.cfg \
    /etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf
}
owner_rekey_device_valid() { [[ -b $1 ]]; }
owner_rekey_run() {
  local device=$1 staged_key=$2 owner_key=$3 state=$4 uuid slots slot owner_slot="" phase=owner-added digest=- version receipt_uuid extra state_fd owner_password
  owner_rekey_device_valid "$device" || return 1
  owner_password=$(cat "$owner_key") || return $?
  [[ -n $owner_password ]] || return 1
  uuid=$(cryptsetup luksUUID "$device") || return $?
  [[ $uuid =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
  [[ ! -L $state && (! -e $state || -d $state) ]] || return 1
  if [[ ! -e $state ]]; then install -d -m 700 "$state" || return $?; fi
  [[ $(stat -c %u "$state") == 0 && $(stat -c %a "$state") == 700 ]] || return 1
  [[ ! -L $state/lock && (! -e $state/lock || -f $state/lock) ]] || return 1
  exec {state_fd}>"$state/lock" || return $?
  flock -n "$state_fd" || { exec {state_fd}>&-; return 1; }
  # Run the state machine in a subshell so its lock always closes on errors.
  (
    if [[ -e $state/receipt || -L $state/receipt ]]; then
      reset_private_file "$state/receipt" || return 1
      read -r version receipt_uuid owner_slot phase digest extra <"$state/receipt"
      [[ $version == 1 && $receipt_uuid == "$uuid" && $owner_slot =~ ^[0-9]+$ && $owner_slot -le 31 && -z $extra && ($phase == owner-added || $phase == boot-published || $phase == complete) ]] || return 1
      cryptsetup open --test-passphrase --key-slot "$owner_slot" --key-file <(printf '%s' "$owner_password") "$device" || {
        reset_error 'Retry needs the previously confirmed owner disk credential'; return 1;
      }
      if [[ $phase != owner-added ]]; then
        [[ $digest =~ ^[a-f0-9]{64}$ && $(sha256sum "$state/boot-manifest") == "$digest  "* ]] || return 1
        owner_rekey_boot_check "$state" || return $?
      else [[ $digest == - ]] || return 1; fi
    else
      reset_boot_probe / || return $?
      reset_private_file "$staged_key" || return 1
      cryptsetup open --test-passphrase --key-file "$staged_key" "$device" || return $?
      slots=$(owner_rekey_slots "$device") || return $?
      for slot in $slots; do
        if cryptsetup open --test-passphrase --key-slot "$slot" --key-file <(printf '%s' "$owner_password") "$device" 2>/dev/null; then owner_slot=$slot; break; fi
      done
      if [[ -z $owner_slot ]]; then
        cryptsetup luksAddKey --key-file "$staged_key" "$device" <(printf '%s' "$owner_password") || return $?
        slots=$(owner_rekey_slots "$device") || return $?
        for slot in $slots; do
          if cryptsetup open --test-passphrase --key-slot "$slot" --key-file <(printf '%s' "$owner_password") "$device" 2>/dev/null; then owner_slot=$slot; break; fi
        done
      fi
      [[ -n $owner_slot ]] || return 1
      reset_state_write "$state/receipt" "1 $uuid $owner_slot owner-added -" || return $?
    fi
    if [[ $phase == owner-added ]]; then
      reset_boot_probe / || return $?
      owner_rekey_remove_auto_unlock || return $?
      owner_rekey_boot_prepare "$state" || return $?
      digest=$(sha256sum "$state/boot-manifest") || return $?
      digest=${digest%% *}
      reset_state_write "$state/receipt" "1 $uuid $owner_slot boot-published $digest" || return $?
    fi
    # Cleanup is deliberately repeated for receipt retries. A stale or
    # reintroduced key/drop-in must never survive a successful completion.
    [[ $phase == owner-added ]] || owner_rekey_remove_auto_unlock || return $?
    owner_rekey_boot_check "$state" || return $?
    cryptsetup open --test-passphrase --key-slot "$owner_slot" --key-file <(printf '%s' "$owner_password") "$device" || return $?
    slots=$(owner_rekey_slots "$device") || return $?
    for slot in $slots; do
      [[ $slot == "$owner_slot" ]] && continue
      cryptsetup luksKillSlot -q --key-file <(printf '%s' "$owner_password") "$device" "$slot" || return $?
    done
    slots=$(owner_rekey_slots "$device") || return $?
    [[ $slots == "$owner_slot" ]] || return 1
    owner_rekey_boot_check "$state" || return $?
    reset_state_write "$state/receipt" "1 $uuid $owner_slot complete $digest" || return $?
    # Old boot backups contain the provisioning key too. Remove all own
    # generation directories after the owner-only header and boot readback.
    local work
    for work in "$state"/grub.*; do
      [[ -e $work || -L $work ]] || continue
      [[ -d $work && ! -L $work && $(stat -c %u "$work") == 0 ]] || return 1
      rm -rf -- "$work" || return $?
    done
    rm -f -- "$staged_key" || return $?
    sync -f "$state"
  )
  local status=$?
  exec {state_fd}>&-
  return "$status"
}
