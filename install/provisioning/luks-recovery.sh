# Shared LUKS owner/recovery-slot operations; sourcing performs no setup.
# Caller contract:
# - Source luks-rekey.sh first: the slot lookups and the journal
#   (luks_slot_for, luks_dump_slots, rekey_state_get, rekey_state_put) are its.
# - Set PROVISIONING_DIR (contains luks-key), REKEY_STATE, LOG_FILE and password.
# - Provide log_step, say and foreground-only show_recovery_key callbacks.
# - Call with tracing disabled while secrets are in scope. Cryptsetup receives
#   secret material through key files/process substitution, never argv values.
# - prepare_luks_recovery writes recovery_key and RECOVERY_REPLACED for the UI;
#   the callback must succeed only after the owner acknowledges the key.
# - The journal contains slot numbers and acknowledgement state, never keys.
# These functions do not choose a platform, change boot files, or activate a
# provisioning policy. The caller decides whether recovery is part of setup.

# 48 base32 characters (A-Z2-7), shown as groups of 4. Never written to disk.
generate_recovery_passphrase() {
  local raw grouped="" i
  raw=$(head -c 4096 /dev/urandom | tr -dc 'A-Z2-7')
  raw=${raw:0:48}
  (( ${#raw} == 48 )) || return 1
  for ((i = 0; i < 48; i += 4)); do
    grouped+="${raw:i:4}"
    (( i + 4 < 48 )) && grouped+="-"
  done
  printf '%s' "$grouped"
}

luks_slot_present() {
  local device=$1 slot=$2 found
  found=$(luks_dump_slots "$device" | awk -v s="$slot" '$1 == s { print; exit }')
  [[ -n $found ]]
}

# Add $1 (passphrase) to $2 (device) once. If a slot number is already recorded,
# never add another: reuse it when it still exists, otherwise fail. The recovery
# passphrase stays in memory of this attempt only.
luks_ensure_slot() {
  local passphrase=$1 device=$2 name=$3 current recorded xtrace_on=0
  recorded=$(rekey_state_get "$name" || true)
  if [[ -n $recorded ]]; then
    if luks_slot_present "$device" "$recorded"; then
      # A retry may have collected a different login password. Refuse before
      # account creation rather than reusing a slot that password cannot open.
      if [[ $name == "owner_slot" ]]; then
        current=$(luks_slot_for "$passphrase" "$device")
        [[ $current == "$recorded" ]] || return 1
      fi
      printf '%s' "$recorded"
      return 0
    fi
    log_step "recorded $name $recorded is missing from $device; not adding another slot"
    say --foreground 1 "The recorded ${name/_/ } is missing; will not add another."
    return 1
  fi
  [[ -n $passphrase ]] || return 1
  [[ $- == *x* ]] && xtrace_on=1
  set +x
  [[ $name == "owner_slot" ]] || return 1
  # A crash after luksAddKey but before the journal write must not add a duplicate.
  current=$(luks_slot_for "$passphrase" "$device")
  if [[ -z $current ]]; then
    if ! { cryptsetup luksAddKey --key-file "$PROVISIONING_DIR/luks-key" "$device" <(printf '%s' "$passphrase") ; } 2>>"$LOG_FILE"; then
      if (( xtrace_on )); then set -x; fi
      return 1
    fi
  fi
  current=$(luks_slot_for "$passphrase" "$device")
  if (( xtrace_on )); then set -x; fi
  [[ -n $current ]] || return 1
  rekey_state_put "$name" "$current" || return 1
  printf '%s' "$current"
}

# Foreground only: persist the intended slot before adding its key, verify it,
# then display and durably acknowledge it. An interrupted, unacknowledged slot
# is revoked before replacement; an acknowledged slot is retained on retry.
prepare_luks_recovery() {
  set +x
  [[ -z ${OMARCHY_PROVISION_WORKER:-} ]] || return 1
  local device=$1 owner_slot recovery_slot occupied slot
  RECOVERY_REPLACED=0
  owner_slot=$(luks_ensure_slot "$password" "$device" owner_slot) || return 1
  recovery_slot=$(rekey_state_get recovery_slot || true)
  if [[ $(rekey_state_get recovery_shown || true) == "1" ]]; then
    [[ -n $recovery_slot ]] && luks_slot_present "$device" "$recovery_slot"
    return
  fi

  if [[ -n $recovery_slot ]]; then
    [[ $recovery_slot =~ ^([0-9]|[12][0-9]|3[01])$ && $recovery_slot != "$owner_slot" ]] || return 1
    if luks_slot_present "$device" "$recovery_slot"; then
      cryptsetup luksKillSlot -q --key-file <(printf '%s' "$password") "$device" "$recovery_slot" 2>>"$LOG_FILE" || return 1
    fi
    RECOVERY_REPLACED=1
  else
    occupied=$(luks_dump_slots "$device") || return 1
    for (( slot=0; slot<32; slot++ )); do
      if ! grep -Fxq "$slot" <<<"$occupied"; then
        recovery_slot=$slot
        break
      fi
    done
    [[ -n $recovery_slot ]] || return 1
    rekey_state_put recovery_slot "$recovery_slot" || return 1
  fi

  recovery_key=$(generate_recovery_passphrase) || return 1
  cryptsetup luksAddKey --key-slot "$recovery_slot" --key-file <(printf '%s' "$password") "$device" <(printf '%s' "$recovery_key") 2>>"$LOG_FILE" || return 1
  [[ $(luks_slot_for "$recovery_key" "$device") == "$recovery_slot" ]] || return 1
  show_recovery_key "$recovery_key" || return 1
  rekey_state_put recovery_shown 1 || return 1
}

# Kill every LUKS slot except the ones listed after the device. Uses the owner's
# password as the remaining authorized key.
luks_kill_other_slots() {
  local device="$1" password="$2" slot other_slots keep xtrace_on=0
  shift 2
  if ! other_slots=$(luks_dump_slots "$device"); then
    log_step "luksDump failed while retiring slots; will retry from the recorded phase"
    say --foreground 1 "Could not enumerate LUKS slots; will retry."
    return 1
  fi
  [[ $- == *x* ]] && xtrace_on=1
  set +x
  for slot in $other_slots; do
    keep=0
    for keep_slot in "$@"; do
      [[ $slot == "$keep_slot" ]] && keep=1 && break
    done
    (( keep )) && continue
    if ! { cryptsetup luksKillSlot -q --key-file <(printf '%s' "$password") "$device" "$slot" ; } 2>>"$LOG_FILE"; then
      if (( xtrace_on )); then set -x; fi
      log_step "failed to kill LUKS slot $slot; will retry from the recorded phase"
      say --foreground 1 "Could not remove a leftover LUKS key; will retry."
      return 1
    fi
  done
  if (( xtrace_on )); then set -x; fi
}
