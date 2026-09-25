#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Owner provisioning's LUKS re-key, killed after every durable step and rerun.
# Each attempt is its own process, like a reboot: the shared re-key, the Limine
# unlock callbacks lifted from omarchy-provision-owner, and a cryptsetup that
# is either a slot-table fake or the real binary on a file-backed volume.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

staged_key=staged-install-key
seller_key=previous-owner-key
owner_password=owner-password

sed -n '/^PROVISIONING_UNLOCK_FILES=(/,/^)/p; /^luks_auto_unlock_present() {/,/^}/p; /^luks_auto_unlock_drop() {/,/^}/p' \
  "$ROOT/bin/omarchy-provision-owner" | sed "s|/etc/|$tmp/etc/|g" >"$tmp/unlock.sh"
grep -q '^luks_auto_unlock_drop() {' "$tmp/unlock.sh" || fail "omarchy-provision-owner defines the Limine auto-unlock callbacks"
sed -n '/^rekey_luks() {/,/^}/p; /^run_provisioning() {/,/^}/p; /^cleanup_oem_state() {/,/^}/p' \
  "$ROOT/bin/omarchy-provision-owner" | sed "s|/etc/|$tmp/etc/|g" >"$tmp/provision.sh"
grep -q '^run_provisioning() {' "$tmp/provision.sh" || fail "omarchy-provision-owner defines its provisioning worker"

cat >"$tmp/attempt.sh" <<'SH'
set -euo pipefail

source "$ROOT/install/provisioning/luks-rekey.sh"
source "$TMP/unlock.sh"

PROVISIONING_DIR=$TMP/provisioning
REKEY_STATE=$PROVISIONING_DIR/luks-rekey.state
LOG_FILE=$TMP/log
password=$PASSWORD

log_step() { printf '%s\n' "$*" >>"$LOG_FILE"; }
say() { :; }

crash_point() {
  local count
  count=$(( $(cat "$TMP/steps") + 1 ))
  echo "$count" >"$TMP/steps"
  printf '%s %s\n' "$count" "$1" >>"$TMP/trace"
  if (( count == ${CRASH_AT:-0} )); then
    kill -9 $$
    kill -9 "$BASHPID"
  fi
}

eval "$(declare -f rekey_state_put | sed '1s/^rekey_state_put /journal_write /')"
rekey_state_put() {
  journal_write "$@" || return 1
  crash_point "journal $*"
}

reset_limine_config() { crash_point "auto-unlock files removed"; }

limine-update() {
  echo rebuild >>"$TMP/rebuilds"
  [[ ! -e $TMP/rebuild-fail ]] || return 1
  crash_point "boot rebuilt"
}

shred() {
  command rm -f -- "${@: -1}"
  crash_point "staged key destroyed"
}

fake_cryptsetup() {
  local op=$1 key_file="" token_type="" target="" extra="" material slot next
  shift
  while (( $# )); do
    case $1 in
      --key-file) key_file=$2; shift 2 ;;
      --token-type) token_type=$2; shift 2 ;;
      -*) shift ;;
      *)
        if [[ -z $target ]]; then target=$1; else extra=$1; fi
        shift
        ;;
    esac
  done
  [[ $target == "$DEVICE" ]] || return 4

  if [[ $op == "luksDump" ]]; then
    echo "Keyslots:"
    awk '{ printf "  %s: luks2\n", $1 }' "$TMP/slots"
    if [[ -s $TMP/token-slot ]]; then
      printf 'Tokens:\n  0: luks2-keyring\n\tKeyslot:    %s\n' "$(cat "$TMP/token-slot")"
    fi
    printf 'Segments:\n  0: crypt\n'
    return 0
  fi
  if [[ $op == "luksKillSlot" ]]; then
    [[ ! -e $TMP/kill-noop ]] || return 0
    awk -v s="$extra" '$1 != s' "$TMP/slots" >"$TMP/slots.next"
    command mv -f "$TMP/slots.next" "$TMP/slots"
    return 0
  fi

  # An enrolled token unlocks its slot whatever key is given, unless the
  # allowed token types exclude it, as with cryptsetup.
  if [[ $op == "open" && -z $token_type && -s $TMP/token-slot ]]; then
    echo "Key slot $(cat "$TMP/token-slot") unlocked."
    return 0
  fi

  material=$(cat "$key_file")
  slot=$(awk -v m="$material" '$2 == m { print $1; exit }' "$TMP/slots")
  if [[ -z $slot ]]; then
    echo "No key available with this passphrase."
    return 2
  fi
  case $op in
    open) echo "Key slot $slot unlocked." ;;
    luksAddKey)
      for (( next = 0; next < 32; next++ )); do
        awk '{ print $1 }' "$TMP/slots" | grep -qx "$next" || break
      done
      printf '%s %s\n' "$next" "$(cat "$extra")" >>"$TMP/slots"
      ;;
    *) return 1 ;;
  esac
}

cryptsetup() {
  local status=0
  if [[ $BACKEND == "fake" ]]; then
    fake_cryptsetup "$@" || status=$?
  elif [[ $1 == "luksAddKey" ]]; then
    command cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "${@:2}" || status=$?
  else
    command cryptsetup "$@" || status=$?
  fi
  (( status == 0 )) || return "$status"
  case $1 in
    luksAddKey) echo add >>"$TMP/adds"; crash_point "owner key added" ;;
    luksKillSlot) crash_point "slot ${*: -1} killed" ;;
  esac
}

# The first-boot worker around the re-key, with account and boot setup stubbed.
provision() {
  source "$TMP/provision.sh"
  STATE_FILE=$TMP/state
  FINALIZE_WARNING_FLAG=$TMP/finalize-warning
  username=owner hostname="" timezone=""
  create_user() { :; }
  install_authorized_keys() { :; }
  configure_login() { :; }
  configure_hostname() { :; }
  configure_timezone() { :; }
  finalize_user() { :; }
  limine_entries_stale() {
    crash_point "re-key returned"
    return 1
  }
  luks_device() { echo "$DEVICE"; }
  systemctl() { :; }
  run_provisioning
}

case $MODE in
  provision) provision ;;
  rekey) luks_rekey "$DEVICE" ;;
  accepts) luks_rekey_accepts_password "$DEVICE" ;;
  remains) luks_staged_unlock_remains ;;
esac
SH

run() {
  local mode=$1 password=$2 crash_at=${3:-0}
  {
    ROOT=$ROOT TMP=$tmp BACKEND=$backend DEVICE=$device MODE=$mode PASSWORD=$password CRASH_AT=$crash_at \
      bash "$tmp/attempt.sh"
  } >>"$tmp/output" 2>&1
}

# The slot the key opens on the volume, or nothing.
opens() {
  if [[ $backend == "fake" ]]; then
    awk -v m="$1" '$2 == m { print $1; exit }' "$tmp/slots"
  else
    LC_ALL=C cryptsetup open --test-passphrase --verbose --key-file <(printf '%s' "$1") "$device" 2>&1 |
      grep -o 'Key slot [0-9]* unlocked' | grep -o '[0-9]*' || true
  fi
}

slot_count() {
  if [[ $backend == "fake" ]]; then
    wc -l <"$tmp/slots"
  else
    cryptsetup luksDump "$device" | grep -cE '^ +[0-9]+: luks2|^Key Slot [0-9]+: ENABLED'
  fi
}

fixture() {
  local format=${1:-luks2}
  rm -rf "$tmp/provisioning" "$tmp/etc" "$tmp/log" "$tmp/output" "$tmp/trace" "$tmp/rebuilds" "$tmp/adds" "$tmp/rebuild-fail" "$tmp/kill-noop" "$tmp/token-slot"
  mkdir -p "$tmp/provisioning" "$tmp/etc/omarchy" "$tmp/etc/limine-entry-tool.d" "$tmp/etc/mkinitcpio.conf.d"
  chmod 755 "$tmp/provisioning"
  touch "$tmp/provisioning/pending"
  printf '%s' "$staged_key" >"$tmp/provisioning/luks-key"
  printf '%s' "$staged_key" >"$tmp/etc/omarchy/provisioning.key"
  echo 'KERNEL_CMDLINE[default]+=" cryptkey=rootfs:/etc/omarchy/provisioning.key"' \
    >"$tmp/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf"
  echo 'FILES+=(/etc/omarchy/provisioning.key)' >"$tmp/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
  echo 0 >"$tmp/steps"
  : >"$tmp/log"

  # A reset leaves the previous owner's slot next to the staged key.
  if [[ $backend == "fake" ]]; then
    device=$tmp/volume
    : >"$device"
    printf '0 %s\n1 %s\n' "$staged_key" "$seller_key" >"$tmp/slots"
  else
    device=$tmp/volume.img
    rm -f "$device"
    truncate -s 32M "$device"
    local pbkdf=(--pbkdf pbkdf2 --pbkdf-force-iterations 1000)
    [[ $format == "luks1" ]] && pbkdf=(--pbkdf-force-iterations 1000)
    cryptsetup luksFormat -q --type "$format" "${pbkdf[@]}" "$device" <(printf '%s' "$staged_key")
    cryptsetup luksAddKey "${pbkdf[@]}" --key-file <(printf '%s' "$staged_key") "$device" <(printf '%s' "$seller_key")
  fi
}

unlock_files_present() {
  [[ -e $tmp/etc/omarchy/provisioning.key || -e $tmp/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf ||
    -e $tmp/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf ]]
}

no_secrets_in() {
  local file
  for file in "$@"; do
    [[ -e $file ]] || continue
    ! grep -Fq -e "$staged_key" -e "$seller_key" -e "$owner_password" -e "other-password" "$file" ||
      fail "$backend: $(basename "$file") holds no key material" "$(cat "$file")"
  done
}

# Between attempts the disk must still open at the next boot: unattended while
# the auto-unlock remains, otherwise with a password the owner typed.
assert_recoverable() {
  local context=$1 password=$2
  if unlock_files_present; then
    [[ -n $(opens "$staged_key") ]] || fail "$backend: $context: the auto-unlock key still opens the disk"
  else
    [[ -n $(opens "$password") ]] || fail "$backend: $context: the owner's password opens the disk once auto-unlock is gone"
  fi
  if [[ -n $(opens "$staged_key") && ! -f $tmp/provisioning/luks-key ]]; then
    fail "$backend: $context: the staged key file is kept while it still unlocks the volume"
  fi
  if [[ -f $tmp/provisioning/luks-rekey.state ]]; then
    [[ $(stat -c %a "$tmp/provisioning/luks-rekey.state") == "600" ]] || fail "$backend: $context: the journal is private"
  fi
  [[ $(stat -c %a "$tmp/provisioning") == "755" ]] || fail "$backend: $context: the provisioning directory stays readable for the new user"
  no_secrets_in "$tmp/provisioning/luks-rekey.state" "$tmp/log"
}

assert_finished() {
  local context=$1 password=$2 max_adds=${3:-1} adds=0
  [[ $(slot_count) == "1" && -n $(opens "$password") ]] || fail "$backend: $context: only the owner's slot remains" "$(cat "$tmp/log")"
  [[ -z $(opens "$staged_key") ]] || fail "$backend: $context: the staged install key no longer unlocks the volume"
  [[ -z $(opens "$seller_key") ]] || fail "$backend: $context: the previous owner's key no longer unlocks the volume"
  [[ ! -e $tmp/provisioning/luks-key ]] || fail "$backend: $context: the staged key file is destroyed"
  ! unlock_files_present || fail "$backend: $context: no boot-time auto-unlock remains"
  [[ -f $tmp/adds ]] && adds=$(wc -l <"$tmp/adds")
  (( adds <= max_adds )) || fail "$backend: $context: the owner's key is added at most $max_adds time(s)"
  ! run remains "$password" || fail "$backend: $context: nothing of the staged unlock remains"
  no_secrets_in "$tmp/provisioning/luks-rekey.state" "$tmp/log" "$tmp/output"
}

# Setup completed: the disk opens with the password the account got, and the
# provisioning state is gone.
assert_provisioned() {
  assert_finished "$@"
  [[ ! -e $tmp/provisioning/pending && ! -e $tmp/provisioning/luks-rekey.state ]] ||
    fail "$backend: $1: setup drops pending and the journal together"
}

backends=(fake)
if command -v cryptsetup >/dev/null; then
  backends+=(luks2 luks1)
else
  skip "cryptsetup is not installed; skipping the file-backed volume runs"
fi

for backend in "${backends[@]}"; do
  format=$backend
  [[ $backend == "fake" ]] && format=luks2

  fixture "$format"
  run provision "$owner_password" || fail "$backend: uninterrupted setup completes" "$(cat "$tmp/log" "$tmp/output")"
  assert_provisioned "uninterrupted" "$owner_password"
  total_steps=$(cat "$tmp/steps")
  (( total_steps >= 11 )) || fail "$backend: every durable step is a crash point" "$(cat "$tmp/trace")"
  pass "$backend: uninterrupted setup leaves only the owner's slot and destroys the staged key"

  # After each kill the owner reboots and answers the form again, with the same
  # password or a new one. The account takes whatever the form accepts, so the
  # disk must open with that password when setup finishes.
  for (( step = 1; step <= total_steps; step++ )); do
    for retry_password in "$owner_password" other-password; do
      fixture "$format"
      if run provision "$owner_password" "$step"; then
        fail "$backend: setup is killed at step $step"
      fi
      point=$(sed -n "${step}p" "$tmp/trace")
      assert_recoverable "killed after '$point'" "$owner_password"
      [[ -e $tmp/provisioning/pending ]] || fail "$backend: killed after '$point', setup runs again"
      staged_alive=$([[ -n $(opens "$staged_key") ]] && echo 1 || echo 0)

      if run accepts "$retry_password"; then
        [[ $retry_password == "$owner_password" ]] || (( staged_alive )) ||
          fail "$backend: after '$point' a new password is refused once the staged key is retired"
        run provision "$retry_password" || fail "$backend: after '$point' setup completes" "$(cat "$tmp/log")"
        if [[ $retry_password == "$owner_password" ]]; then
          assert_provisioned "rerun after '$point'" "$retry_password"
          if head -n "$step" "$tmp/trace" | grep -q 'journal phase boot'; then
            [[ $(wc -l <"$tmp/rebuilds") == "1" ]] || fail "$backend: rerun after '$point' does not rebuild boot again"
          fi
        else
          assert_provisioned "new password after '$point'" "$retry_password" 2
          [[ -z $(opens "$owner_password") ]] || fail "$backend: after '$point' the abandoned password is retired"
        fi
      else
        [[ $retry_password != "$owner_password" ]] || fail "$backend: after '$point' the original password is always accepted"
        (( ! staged_alive )) || fail "$backend: after '$point' a new password is accepted while the staged key works"
        if run provision "$retry_password"; then fail "$backend: after '$point' setup refuses a new password"; fi
        assert_recoverable "refused new password after '$point'" "$owner_password"
        [[ -e $tmp/provisioning/pending ]] || fail "$backend: after '$point' a refused password keeps setup pending"
        run provision "$owner_password" || fail "$backend: after '$point' the original password completes" "$(cat "$tmp/log")"
        assert_provisioned "original password after '$point'" "$owner_password"
      fi
    done
  done
  pass "$backend: killed after each of $total_steps steps, setup resumes to a disk that opens with the account's password"
done

backend=fake

fixture
touch "$tmp/rebuild-fail"
if run rekey "$owner_password"; then fail "a failed boot rebuild fails the attempt"; fi
unlock_files_present || fail "a failed boot rebuild restores the auto-unlock"
[[ $(cat "$tmp/etc/omarchy/provisioning.key") == "$staged_key" ]] || fail "the restored keyfile is the staged key"
[[ -n $(opens "$staged_key") && -n $(opens "$seller_key") ]] || fail "a failed boot rebuild retires no slot"
rm "$tmp/rebuild-fail"
run rekey "$owner_password" || fail "the retry after a failed rebuild completes" "$(cat "$tmp/log")"
assert_finished "retry after a failed rebuild" "$owner_password"
pass "a failed boot rebuild keeps the unattended unlock and every slot for the retry"

fixture
printf '2 %s\n' tpm-sealed-key >>"$tmp/slots"
echo 2 >"$tmp/token-slot"
run provision "$owner_password" || fail "setup completes beside an enrolled token" "$(cat "$tmp/log")"
assert_provisioned "beside the previous owner's token" "$owner_password"
pass "a token the previous owner enrolled never answers for a key and is retired with its slot"

fixture
touch "$tmp/kill-noop"
if run rekey "$owner_password"; then fail "a slot kill that changes nothing fails the re-key"; fi
[[ -f $tmp/provisioning/luks-key && -f $tmp/provisioning/luks-rekey.state ]] || fail "an unverified retirement keeps the staged key and journal"
rm "$tmp/kill-noop"
run rekey "$owner_password" || fail "the retry after an ineffective slot kill completes" "$(cat "$tmp/log")"
assert_finished "retry after an ineffective slot kill" "$owner_password"
pass "the staged key is destroyed only after the volume proves it no longer opens"

fixture
printf '0 %s\n1 %s\n2 %s\n' "$staged_key" "$seller_key" "$owner_password" >"$tmp/slots"
printf 'staged_slot=0\nowner_slot=2\nphase=boot\n' >"$tmp/provisioning/luks-rekey.state"
run rekey "$owner_password" || fail "a leftover auto-unlock after the boot step is removed" "$(cat "$tmp/log")"
assert_finished "leftover auto-unlock after the boot step" "$owner_password"
[[ $(wc -l <"$tmp/rebuilds") == "1" ]] || fail "the leftover auto-unlock triggers a boot rebuild"
pass "an auto-unlock that outlives the boot step is rebuilt away rather than blocking forever"

fixture
printf 'wrong-key' >"$tmp/provisioning/luks-key"
if run rekey "$owner_password"; then fail "a staged key that opens nothing fails the re-key"; fi
[[ ! -e $tmp/provisioning/luks-rekey.state && $(slot_count) == "2" ]] || fail "a dead staged key changes nothing"
pass "a fresh re-key refuses a staged key that no longer unlocks the volume"

fixture
rm "$tmp/provisioning/luks-key"
run remains "$owner_password" || fail "a leftover auto-unlock counts as the staged unlock remaining"
if run rekey "$owner_password"; then fail "a leftover auto-unlock without its staged key fails closed"; fi
unlock_files_present || fail "the leftover auto-unlock is not silently accepted"
pass "a boot-time auto-unlock without its staged key keeps provisioning from finishing"

fixture
if run rekey "$staged_key"; then fail "the staged key is refused as the owner's password"; fi
[[ $(slot_count) == "2" ]] && unlock_files_present || fail "refusing the staged key as a password changes nothing"
run rekey "$owner_password" || fail "a retry with a real password completes" "$(cat "$tmp/log")"
assert_finished "retry after refusing the staged key" "$owner_password"
pass "the owner's password must differ from the staged install key"

fixture
printf 'phase=owner\nstaged_slot=0\nowner_slot=2\nrecovery_slot=5\n' >"$tmp/provisioning/luks-rekey.state"
chmod 600 "$tmp/provisioning/luks-rekey.state"
(
  source "$ROOT/install/provisioning/luks-rekey.sh"
  REKEY_STATE=$tmp/provisioning/luks-rekey.state
  rekey_state_put phase boot
)
[[ $(grep -c . "$tmp/provisioning/luks-rekey.state") == "4" ]] && grep -qx 'phase=boot' "$tmp/provisioning/luks-rekey.state" &&
  grep -qx 'recovery_slot=5' "$tmp/provisioning/luks-rekey.state" || fail "a journal write keeps every other recorded key" "$(cat "$tmp/provisioning/luks-rekey.state")"
pass "journal writes replace only their own keys"

fixture
rm "$tmp/provisioning/luks-key"
if run provision "$owner_password"; then fail "provisioning with a leftover auto-unlock and no staged key fails"; fi
[[ -e $tmp/provisioning/pending ]] && unlock_files_present || fail "provisioning keeps its state while the auto-unlock remains"
pass "first-boot provisioning never finishes with the boot-time auto-unlock still configured"

fixture
rm -rf "$tmp/provisioning/luks-key" "$tmp/etc"
run provision "$owner_password" || fail "unencrypted provisioning finishes" "$(cat "$tmp/log" "$tmp/output")"
[[ ! -e $tmp/provisioning/pending && ! -e $tmp/provisioning/luks-rekey.state && $(slot_count) == "2" ]] ||
  fail "unencrypted provisioning skips the re-key"
pass "provisioning without a staged key or auto-unlock skips the re-key"
