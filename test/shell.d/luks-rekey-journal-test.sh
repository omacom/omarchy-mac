#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Owner provisioning's LUKS re-key, killed after every durable step and rerun.
# Each attempt is its own process, like a reboot: the shared re-key, the unlock
# callbacks lifted from omarchy-provision-owner, and a cryptsetup that is either
# a slot-table fake or the real binary on a file-backed volume. The callbacks
# reach the platform through the real omarchy-lifecycle-dispatch: on an x86
# fixture it is a no-op and the Limine UKI path runs; on an Apple fixture a fake
# omarchy-mac-boot owns the unlock on the boot partition and GRUB command line.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_platform "$tmp/x86" generic
fake_platform "$tmp/apple" apple-silicon
platform=x86

# Root's dispatcher ignores the fixtures and sees this machine, which stands in
# for x86 only where no boot package is registered.
platforms=(x86 apple)
if (( EUID == 0 )); then
  if [[ $("$ROOT/bin/omarchy-hw-platform") == "apple-silicon" ]]; then
    pass "running as root on Apple Silicon, where dispatch ignores fixtures; skipping"
    exit 0
  fi
  platforms=(x86)
  pass "running as root, where dispatch ignores fixtures; skipping the Apple runs"
fi
runtime=$ROOT

mac_boot=$tmp/lifecycle/usr/lib/omarchy/mac-boot
mkdir -p "$mac_boot"
cat >"$tmp/mac-boot-lib.sh" <<'SH'
ran() { echo "$1" >>"$TMP/mac-boot-ran"; }
crash() {
  local count
  count=$(( $(cat "$TMP/steps") + 1 ))
  echo "$count" >"$TMP/steps"
  printf '%s %s\n' "$count" "$1" >>"$TMP/trace"
  if (( count == $(cat "$TMP/crash-at") )); then
    kill -9 "$PPID"
    kill -9 $$
  fi
}
SH
mac_boot_entrypoint() {
  { printf '#!/bin/bash\nset -euo pipefail\nTMP=%q\nsource "$TMP/mac-boot-lib.sh"\nran %s\n' "$tmp" "$1"; cat; } >"$mac_boot/$1"
}
mac_boot_entrypoint provision-prepare <<'SH'
if [[ -e $TMP/prepare-fail ]]; then
  echo "The boot partition is not mounted." >&2
  exit 1
fi
SH
mac_boot_entrypoint provision-commit <<'SH'
[[ ! -e $TMP/rebuild-fail ]] || exit 1
rm -f "$TMP/boot/omarchy/luks-key"
crash "boot-partition key removed"
sed -i 's/ rd\.luks\.key=[^" ]*//' "$TMP/etc/default/grub"
echo rebuild >>"$TMP/rebuilds"
crash "boot rebuilt"
SH
mac_boot_entrypoint provision-verify <<'SH'
[[ ! -e $TMP/boot/omarchy/luks-key ]] && ! grep -q 'rd\.luks\.key=' "$TMP/etc/default/grub"
SH
mac_boot_entrypoint boot-rebuild <<'SH'
echo rebuild >>"$TMP/rebuilds"
SH
chmod 755 "$mac_boot"/*
chmod -R go-w "$tmp/lifecycle"

staged_key=staged-install-key
seller_key=previous-owner-key
owner_password=owner-password

sed -n '/^PROVISIONING_UNLOCK_FILES=(/,/^)/p; /^UNLOCK_OWNER=/p; /^limine_auto_unlock_present() {/,/^}/p; /^limine_auto_unlock_drop() {/,/^}/p
  /^unlock_owner() {/,/^}/p; /^luks_auto_unlock_present() {/,/^}/p; /^luks_auto_unlock_drop() {/,/^}/p' \
  "$ROOT/bin/omarchy-provision-owner" | sed "s|/etc/|$tmp/etc/|g" >"$tmp/unlock.sh"
grep -q '^luks_auto_unlock_drop() {' "$tmp/unlock.sh" && grep -q '^limine_auto_unlock_drop() {' "$tmp/unlock.sh" ||
  fail "omarchy-provision-owner defines the dispatched and Limine auto-unlock callbacks"
sed -n '/^encrypt_state_get() {/,/^}/p; /^rekey_luks() {/,/^}/p; /^run_provisioning() {/,/^}/p; /^cleanup_oem_state() {/,/^}/p; /^platform_ready() {/,/^}/p; /^run_setup() {/,/^}/p
  /^refresh_boot_entries() {/,/^}/p' \
  "$ROOT/bin/omarchy-provision-owner" | sed "s|/etc/|$tmp/etc/|g" >"$tmp/provision.sh"
grep -q '^run_provisioning() {' "$tmp/provision.sh" && grep -q '^run_setup() {' "$tmp/provision.sh" ||
  fail "omarchy-provision-owner defines its setup and provisioning worker"

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

reset_limine_config() {
  echo reset >>"$TMP/limine-ran"
  crash_point "auto-unlock files removed"
}

limine-update() {
  echo update >>"$TMP/limine-ran"
  echo rebuild >>"$TMP/rebuilds"
  [[ ! -e $TMP/rebuild-fail ]] || return 1
  crash_point "boot rebuilt"
}

shred() {
  command rm -f -- "${@: -1}"
  crash_point "staged key destroyed"
}

fake_cryptsetup() {
  local op=$1 key_file="" target="" extra="" material slot next
  shift
  while (( $# )); do
    case $1 in
      --key-file) key_file=$2; shift 2 ;;
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
    printf 'Segments:\n  0: crypt\n'
    return 0
  fi
  if [[ $op == "luksKillSlot" ]]; then
    [[ ! -e $TMP/kill-noop ]] || return 0
    awk -v s="$extra" '$1 != s' "$TMP/slots" >"$TMP/slots.next"
    command mv -f "$TMP/slots.next" "$TMP/slots"
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
    [[ -e $TMP/stale ]]
  }
  luks_device() { echo "$DEVICE"; }
  systemctl() { :; }
  # The generic path: no Apple encrypt.state or Boot-partition key.
  apple_silicon() { return 1; }
  ENCRYPT_STATE=$TMP/boot/encrypt.state
  BOOT_LUKS_KEY=$TMP/boot/luks-key
  run_provisioning
}

# First-boot setup up to the owner form, with the screen captured.
setup() {
  source "$TMP/provision.sh"
  clear_logo() { :; }
  sleep() { :; }
  say() { printf '%s\n' "$*" >>"$TMP/screen"; }
  keyboard_form() {
    echo "owner form" >>"$TMP/screen"
    exit 0
  }
  run_setup
}

case $MODE in
  provision) provision ;;
  setup) setup ;;
  rekey) luks_rekey "$DEVICE" ;;
  accepts) luks_rekey_accepts_password "$DEVICE" ;;
  remains) luks_staged_unlock_remains ;;
esac
SH

run() {
  local mode=$1 password=$2 crash_at=${3:-0}
  echo "$crash_at" >"$tmp/crash-at"
  {
    ROOT=$ROOT TMP=$tmp BACKEND=$backend DEVICE=$device MODE=$mode PASSWORD=$password CRASH_AT=$crash_at \
      OMARCHY_PATH=$runtime OMARCHY_PROC_ROOT=$tmp/$platform/proc OMARCHY_LIFECYCLE_ROOT=$tmp/lifecycle \
      PATH="$tmp/$platform/bin:$PATH" bash "$tmp/attempt.sh"
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
  rm -rf "$tmp/provisioning" "$tmp/etc" "$tmp/boot" "$tmp/log" "$tmp/output" "$tmp/trace" "$tmp/rebuilds" "$tmp/adds" "$tmp/rebuild-fail" "$tmp/kill-noop" \
    "$tmp/prepare-fail" "$tmp/screen" "$tmp/stale"
  mkdir -p "$tmp/provisioning"
  chmod 755 "$tmp/provisioning"
  touch "$tmp/provisioning/pending"
  printf '%s' "$staged_key" >"$tmp/provisioning/luks-key"
  if [[ $platform == "apple" ]]; then
    mkdir -p "$tmp/boot/omarchy" "$tmp/etc/default"
    printf '%s' "$staged_key" >"$tmp/boot/omarchy/luks-key"
    echo 'GRUB_CMDLINE_LINUX="rd.luks.name=root-uuid=root rd.luks.key=root-uuid=/omarchy/luks-key:UUID=boot-uuid"' >"$tmp/etc/default/grub"
  else
    mkdir -p "$tmp/etc/omarchy" "$tmp/etc/limine-entry-tool.d" "$tmp/etc/mkinitcpio.conf.d"
    printf '%s' "$staged_key" >"$tmp/etc/omarchy/provisioning.key"
    echo 'KERNEL_CMDLINE[default]+=" cryptkey=rootfs:/etc/omarchy/provisioning.key"' \
      >"$tmp/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf"
    echo 'FILES+=(/etc/omarchy/provisioning.key)' >"$tmp/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
  fi
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
    -e $tmp/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf || -e $tmp/boot/omarchy/luks-key ]] ||
    grep -qs 'rd\.luks\.key=' "$tmp/etc/default/grub"
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
  pass "cryptsetup is not installed; skipping the file-backed volume runs"
fi

# The crash matrix runs on every backend for x86 and on the fake for Apple.
matrix=()
for backend in "${backends[@]}"; do
  matrix+=("x86 $backend")
done
[[ " ${platforms[*]} " != *" apple "* ]] || matrix+=("apple fake")

for run_spec in "${matrix[@]}"; do
  read -r platform backend <<<"$run_spec"
  rm -f "$tmp/mac-boot-ran" "$tmp/limine-ran"
  format=$backend
  [[ $backend == "fake" ]] && format=luks2

  fixture "$format"
  run provision "$owner_password" || fail "$backend: uninterrupted setup completes" "$(cat "$tmp/log" "$tmp/output")"
  assert_provisioned "uninterrupted" "$owner_password"
  total_steps=$(cat "$tmp/steps")
  (( total_steps >= 11 )) || fail "$backend: every durable step is a crash point" "$(cat "$tmp/trace")"
  pass "$platform $backend: uninterrupted setup leaves only the owner's slot and destroys the staged key"

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
  pass "$platform $backend: killed after each of $total_steps steps, setup resumes to a disk that opens with the account's password"

  if [[ $platform == "x86" ]]; then
    [[ ! -e $tmp/mac-boot-ran ]] || fail "x86 $backend: no Mac boot entrypoint runs" "$(cat "$tmp/mac-boot-ran")"
    pass "x86 $backend: dispatch is a no-op and the Limine UKI path runs unchanged"
  else
    [[ ! -e $tmp/limine-ran ]] || fail "apple $backend: the Limine UKI path never runs on Apple"
    grep -qx provision-commit "$tmp/mac-boot-ran" && grep -qx provision-verify "$tmp/mac-boot-ran" ||
      fail "apple $backend: the boot package commits and verifies the unlock"
    pass "apple $backend: the boot package owns the boot-time unlock through dispatch"
  fi
done

platform=x86
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

if [[ " ${platforms[*]} " == *" apple "* ]]; then
  # Apple: a failed boot-package commit keeps the unattended unlock and every slot.
  platform=apple
  fixture
  touch "$tmp/rebuild-fail"
  if run rekey "$owner_password"; then fail "apple: a failed boot-package commit fails the attempt"; fi
  unlock_files_present || fail "apple: a failed commit keeps the boot-time unlock"
  [[ -n $(opens "$staged_key") && -n $(opens "$seller_key") ]] || fail "apple: a failed commit retires no slot"
  rm "$tmp/rebuild-fail"
  run rekey "$owner_password" || fail "apple: the retry after a failed commit completes" "$(cat "$tmp/log")"
  assert_finished "apple: retry after a failed commit" "$owner_password"
  pass "apple: a failed boot-package commit keeps the unattended unlock and every slot for the retry"

  # Apple: an inherited decision never replaces resolving who owns the unlock.
  fixture
  rm -f "$tmp/limine-ran"
  export UNLOCK_OWNER=limine
  run provision "$owner_password" || fail "apple: setup completes with UNLOCK_OWNER in its environment" "$(cat "$tmp/log")"
  unset UNLOCK_OWNER
  assert_provisioned "apple: UNLOCK_OWNER inherited" "$owner_password"
  [[ ! -e $tmp/limine-ran ]] || fail "apple: an inherited UNLOCK_OWNER does not select the Limine path"
  pass "apple: an inherited UNLOCK_OWNER is ignored"
fi

# After a factory reset left entries for another machine identity, the menu
# starts over on both; the boot package rebuilds on Apple, limine-update on x86.
for platform in "${platforms[@]}"; do
  fixture
  rm -rf "$tmp/provisioning/luks-key" "$tmp/etc" "$tmp/boot" "$tmp/limine-ran" "$tmp/mac-boot-ran"
  touch "$tmp/stale"
  run provision "$owner_password" || fail "$platform: stale boot entries are refreshed" "$(cat "$tmp/log" "$tmp/output")"
  [[ ! -e $tmp/provisioning/pending && $(wc -l <"$tmp/rebuilds") == "1" ]] || fail "$platform: setup finishes after one boot rebuild"
  if [[ $platform == "x86" ]]; then
    [[ $(cat "$tmp/limine-ran") == $'reset\nupdate' && ! -e $tmp/mac-boot-ran ]] ||
      fail "x86: the Limine menu is reset and limine-update rebuilds" "$(cat "$tmp/limine-ran")"
  else
    [[ $(cat "$tmp/limine-ran") == "reset" ]] && grep -qx boot-rebuild "$tmp/mac-boot-ran" ||
      fail "apple: the Limine menu is reset and the boot package rebuilds" "$(cat "$tmp/limine-ran")"
  fi
done
pass "stale boot entries are rebuilt by limine-update on x86 and by the boot package on Apple"

# Before the owner form: a no-op on x86 even with Mac entrypoints on disk, the
# boot package's own answer on Apple.
platform=x86
fixture
rm -f "$tmp/mac-boot-ran"
touch "$tmp/prepare-fail"
run setup "$owner_password" || fail "x86: setup reaches the owner form without a boot package" "$(cat "$tmp/output")"
[[ $(cat "$tmp/screen") == "owner form" && ! -e $tmp/mac-boot-ran ]] ||
  fail "x86: no Mac boot entrypoint runs before the owner form" "$(cat "$tmp/screen")"
pass "x86: the platform check before the owner form is a no-op"

if [[ " ${platforms[*]} " == *" apple "* ]]; then
  platform=apple
  fixture
  run setup "$owner_password" && grep -qx 'owner form' "$tmp/screen" ||
    fail "apple: setup reaches the owner form with the boot package ready" "$(cat "$tmp/output")"
  fixture
  touch "$tmp/prepare-fail"
  if run setup "$owner_password"; then fail "apple: setup stops when the boot package is not ready"; fi
  ! grep -qx 'owner form' "$tmp/screen" || fail "apple: the owner is asked nothing when the boot package is not ready"
  grep -q 'The boot partition is not mounted.' "$tmp/screen" && grep -q 'The boot partition is not mounted.' "$tmp/log" ||
    fail "apple: the boot package's reason reaches the screen and the log" "$(cat "$tmp/screen" "$tmp/log" 2>/dev/null)"
  pass "apple: setup stops before the owner form when the boot package is not ready"

  # Apple without omarchy-mac-boot: setup stops before the owner form naming the
  # package, and a worker that got past it anyway never finishes while any part
  # of the staged unlock remains.
  mv "$mac_boot" "$tmp/mac-boot.off"
  fixture
  rm -f "$tmp/limine-ran"
  if run setup "$owner_password"; then fail "apple: setup refuses without the boot package"; fi
  ! grep -qx 'owner form' "$tmp/screen" || fail "apple: the owner is asked nothing without the boot package"
  grep -q 'provision-prepare on apple-silicon needs omarchy-mac-boot' "$tmp/screen" ||
    fail "apple: the missing boot package is named on the screen" "$(cat "$tmp/screen" 2>/dev/null)"
  grep -q '/usr/lib/omarchy/mac-boot/provision-prepare' "$tmp/log" || fail "apple: the log names the missing entrypoint" "$(cat "$tmp/log")"
  if run provision "$owner_password"; then fail "apple: provisioning without the boot package fails"; fi
  [[ -e $tmp/provisioning/pending && -f $tmp/provisioning/luks-key ]] && unlock_files_present ||
    fail "apple: provisioning without the boot package keeps its state and the staged unlock"
  [[ -n $(opens "$staged_key") && -n $(opens "$seller_key") ]] || fail "apple: provisioning without the boot package retires no slot"
  fixture
  rm "$tmp/provisioning/luks-key"
  if run provision "$owner_password"; then fail "apple: a leftover boot-partition unlock without the boot package fails provisioning"; fi
  [[ -e $tmp/provisioning/pending ]] && unlock_files_present || fail "apple: a leftover boot-partition unlock keeps provisioning pending"
  [[ ! -e $tmp/limine-ran ]] || fail "apple: the Limine UKI path is no fallback for a missing boot package"
  mv "$tmp/mac-boot.off" "$mac_boot"
  pass "apple: without omarchy-mac-boot setup stops naming it, and the worker fails closed"
fi

# A boot package that implements only one of the commit/verify pair owns
# nothing: provisioning fails closed rather than mixing it with the Limine path.
mkdir -p "$tmp/half/bin"
cat >"$tmp/half/bin/omarchy-lifecycle-dispatch" <<SH
#!/bin/bash
echo "\$*" >>"$tmp/half-ran"
[[ \$* != "--resolve provision-commit" ]] || echo /usr/lib/omarchy/mac-boot/provision-commit
SH
chmod +x "$tmp/half/bin/omarchy-lifecycle-dispatch"
runtime=$tmp/half
fixture
rm -f "$tmp/limine-ran" "$tmp/half-ran"
if run provision "$owner_password"; then fail "a half-implemented unlock fails provisioning"; fi
[[ -e $tmp/provisioning/pending ]] && unlock_files_present || fail "a half-implemented unlock keeps provisioning pending"
[[ -s $tmp/half-ran && ! -e $tmp/limine-ran ]] && ! grep -qv -- '--resolve' "$tmp/half-ran" ||
  fail "a half-implemented unlock runs neither the platform nor the Limine path" "$(cat "$tmp/half-ran")"
runtime=$ROOT
pass "a boot package implementing only half of the unlock pair fails closed"

# A recovery slot the owner acknowledged (luks-recovery.sh) survives the
# retirement; one whose key was never acknowledged is retired with the rest.
platform=x86
backend=fake
for acknowledged in 1 0; do
  fixture
  printf '2 recovery-key\n' >>"$tmp/slots"
  printf 'recovery_slot=2\n' >"$tmp/provisioning/luks-rekey.state"
  (( acknowledged )) && echo 'recovery_shown=1' >>"$tmp/provisioning/luks-rekey.state"
  chmod 600 "$tmp/provisioning/luks-rekey.state"
  run rekey "$owner_password" || fail "the re-key with a recorded recovery slot completes" "$(cat "$tmp/log")"
  [[ -z $(opens "$staged_key") && -z $(opens "$seller_key") && -n $(opens "$owner_password") ]] ||
    fail "the staged and previous owner's keys are retired beside a recovery slot"
  if (( acknowledged )); then
    [[ $(opens recovery-key) == 2 && $(slot_count) == 2 ]] || fail "an acknowledged recovery slot is kept" "$(cat "$tmp/slots")"
  else
    [[ -z $(opens recovery-key) && $(slot_count) == 1 ]] || fail "an unacknowledged recovery slot is retired" "$(cat "$tmp/slots")"
  fi
done
pass "the re-key keeps an acknowledged recovery slot and retires an unacknowledged one"
