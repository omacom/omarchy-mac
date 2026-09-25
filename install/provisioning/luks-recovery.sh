# A recovery passphrase beside the owner's LUKS password, added with the staged
# install key through the re-key journal; sourcing performs no setup.
# Caller contract:
# - Source luks-rekey.sh first and meet its contract: the journal, the slot
#   lookups and the staged key are its.
# - Provide a foreground-only show_recovery_key callback that succeeds only
#   after the owner acknowledges the key. prepare_luks_recovery sets
#   recovery_key and RECOVERY_REPLACED for it.
# - Call with tracing disabled while secrets are in scope. Cryptsetup receives
#   secret material through key files/process substitution, never argv values.
# The journal records the reserved slot (recovery_slot) and the owner's view of
# its key (recovery_shown: 0 once added, 1 once acknowledged), never keys. The
# re-key keeps an acknowledged recovery slot and retires any other. These
# functions do not choose a platform or change boot files: the caller decides
# whether recovery is part of setup.

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

# Whether $1 has the form generate_recovery_passphrase gives every recovery key.
luks_recovery_passphrase() {
  local -
  set +x
  [[ $1 =~ ^([A-Z2-7]{4}-){11}[A-Z2-7]{4}$ ]]
}

luks_slot_present() {
  local device=$1 slot=$2 found
  found=$(luks_dump_slots "$device" | awk -v s="$slot" '$1 == s { print; exit }')
  [[ -n $found ]]
}

# Foreground only, before the re-key's worker runs. Reserve a free slot in the
# journal, add a new key there with the staged install key, show it and record
# the owner's acknowledgement, each step journaled so a retry resumes: an
# acknowledged key is kept, and one added but never acknowledged is revoked and
# replaced, RECOVERY_REPLACED telling the owner when they may have seen it. The
# owner's own slot is the re-key's, so a retry may still choose a new password.
prepare_luks_recovery() {
  local -
  set +x
  [[ -z ${OMARCHY_PROVISION_WORKER:-} ]] || return 1
  local device=$1 slot shown staged occupied candidate
  RECOVERY_REPLACED=0
  slot=$(rekey_state_get recovery_slot || true)
  shown=$(rekey_state_get recovery_shown || true)

  if [[ $shown == "1" ]]; then
    luks_slot_present "$device" "$slot" && return 0
    log_step "the acknowledged recovery slot ${slot:-?} is missing from $device; replacing its key"
    RECOVERY_REPLACED=1
  elif [[ $shown == "0" ]]; then
    RECOVERY_REPLACED=1
  fi

  staged=$(staged_key_slot "$device")
  if [[ -z $staged ]]; then
    log_step "the staged LUKS key no longer unlocks $device; cannot add a recovery key"
    return 1
  fi

  if [[ $slot =~ ^([0-9]|[12][0-9]|3[01])$ && $slot != "$staged" && $slot != "$(rekey_state_get owner_slot || true)" ]]; then
    if luks_slot_present "$device" "$slot"; then
      cryptsetup luksKillSlot -q --key-file "$PROVISIONING_DIR/luks-key" "$device" "$slot" 2>>"$LOG_FILE" || return 1
    fi
  else
    occupied=$(luks_dump_slots "$device") || return 1
    slot=""
    for (( candidate = 0; candidate < 32; candidate++ )); do
      if ! grep -Fxq "$candidate" <<<"$occupied"; then
        slot=$candidate
        break
      fi
    done
    [[ -n $slot ]] || return 1
    rekey_state_put recovery_slot "$slot" || return 1
  fi

  recovery_key=$(generate_recovery_passphrase) || return 1
  cryptsetup luksAddKey --key-slot "$slot" --key-file "$PROVISIONING_DIR/luks-key" "$device" <(printf '%s' "$recovery_key") 2>>"$LOG_FILE" || return 1
  [[ $(luks_slot_for "$recovery_key" "$device") == "$slot" ]] || return 1
  rekey_state_put recovery_shown 0 || return 1
  show_recovery_key "$recovery_key" || return 1
  rekey_state_put recovery_shown 1
}
