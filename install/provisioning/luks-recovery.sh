# Shared LUKS owner/recovery-slot operations; sourcing performs no setup.
# Caller contract:
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

# Identify the slot unlocked by $1 (passphrase) on $2 (device).
luks_slot_for() {
  local out xtrace_on=0
  [[ $- == *x* ]] && xtrace_on=1
  set +x
  if ! out=$(LC_ALL=C cryptsetup open --test-passphrase --verbose --key-file <(printf '%s' "$1") "$2" 2>&1); then
    printf '%s\n' "$out" >>"$LOG_FILE"
  fi
  if (( xtrace_on )); then set -x; fi
  grep -o 'Key slot [0-9]* unlocked' <<<"$out" | grep -o '[0-9]*' | head -1 || true
}

luks_dump_slots() {
  cryptsetup luksDump "$1" | awk '/^ +[0-9]+: luks2/ { sub(":", "", $1); print $1 }'
}

luks_slot_present() {
  local device=$1 slot=$2 found
  found=$(luks_dump_slots "$device" | awk -v s="$slot" '$1 == s { print; exit }')
  [[ -n $found ]]
}

rekey_state_get() {
  local key=$1
  [[ -f $REKEY_STATE ]] || return 1
  awk -F= -v k="$key" '$1 == k { print $2; exit }' "$REKEY_STATE"
}

rekey_state_put() {
  local key=$1 value=$2 tmp owner_slot recovery_slot recovery_shown
  owner_slot=$(rekey_state_get owner_slot || true)
  recovery_slot=$(rekey_state_get recovery_slot || true)
  recovery_shown=$(rekey_state_get recovery_shown || true)
  case $key in
    owner_slot) owner_slot=$value ;;
    recovery_slot) recovery_slot=$value ;;
    recovery_shown) recovery_shown=$value ;;
  esac
  install -d -m 700 "$(dirname "$REKEY_STATE")" || return 1
  tmp=$(mktemp "${REKEY_STATE}.XXXXXX") || return 1
  {
    [[ -z $owner_slot ]] || printf 'owner_slot=%s\n' "$owner_slot"
    [[ -z $recovery_slot ]] || printf 'recovery_slot=%s\n' "$recovery_slot"
    [[ -z $recovery_shown ]] || printf 'recovery_shown=%s\n' "$recovery_shown"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  sync "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$REKEY_STATE" || return 1
  sync "$(dirname "$REKEY_STATE")"
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
