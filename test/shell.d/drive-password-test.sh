#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-drive-password against fake drives. blkid, findmnt and lsblk describe
# a system drive under / and a data drive; cryptsetup is either a slot-table fake
# or the real binary on file-backed volumes; chpasswd records the accounts. Each
# cryptsetup and chpasswd call is a crash point, so a run can be killed after
# every step and rerun, like a power loss.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

old_password=old-password
new_password='new pass:word'
recovery_key=recovery-passphrase
data_password=data-password
journal=$tmp/state/omarchy/drive-password.state

mkdir -p "$tmp/bin" "$tmp/real" "$tmp/dev"

cat >"$tmp/crash.sh" <<'SH'
crash_point() {
  local count
  count=$(( $(cat "$TEST_TMP/steps") + 1 ))
  echo "$count" >"$TEST_TMP/steps"
  printf '%s %s\n' "$count" "$1" >>"$TEST_TMP/trace"
  if (( count == ${CRASH_AT:-0} )); then
    kill -9 "$TEST_PID"
    kill -9 $$
  fi
}
SH

cat >"$tmp/bin/blkid" <<'SH'
#!/bin/bash
[[ $* == "-t TYPE=crypto_LUKS -o device" ]] || exit 99
cat "$TEST_TMP/drives"
SH

cat >"$tmp/bin/findmnt" <<'SH'
#!/bin/bash
[[ $* == "-no SOURCE /" ]] || exit 99
echo '/dev/mapper/root[/@]'
SH

cat >"$tmp/bin/lsblk" <<'SH'
#!/bin/bash
[[ $* == "-nsrpo NAME,FSTYPE /dev/mapper/root" ]] || exit 98
cat "$TEST_TMP/root-ancestry"
SH

cat >"$tmp/bin/omarchy-drive-select" <<'SH'
#!/bin/bash
cat "$TEST_TMP/select"
SH

cat >"$tmp/bin/gum" <<'SH'
#!/bin/bash
[[ $1 == "input" ]] || exit 97
printf '%s\n' "$*" >>"$TEST_TMP/prompts"
[[ -s $TEST_TMP/inputs ]] || exit 130
head -n 1 "$TEST_TMP/inputs"
sed -i '1d' "$TEST_TMP/inputs"
SH

# Runs as the caller. The passphrase cryptsetup reads from the terminal comes
# from $TEST_TMP/tty.
cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_TMP/sudo-calls"
args=()
for arg in "$@"; do
  args+=("${arg//\/dev\/tty/$TEST_TMP/tty}")
done
exec "${args[@]}"
SH

cat >"$tmp/bin/chpasswd" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"
IFS= read -r line
name=${line%%:*}
crash_point "chpasswd $name"
[[ $name != "${TEST_CHPASSWD_FAIL:-}" ]] || exit 1
{
  grep -v "^$name	" "$TEST_TMP/accounts" || true
  printf '%s\t%s\n' "$name" "${line#*:}"
} >"$TEST_TMP/accounts.next"
mv -f "$TEST_TMP/accounts.next" "$TEST_TMP/accounts"
crash_point "$name password set"
SH

# A LUKS volume as a table of "slot<TAB>passphrase" lines next to the device.
# luksChangeKey adds the new key to a free slot before removing the old one,
# as cryptsetup does.
cat >"$tmp/bin/cryptsetup" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"

slot_of() {
  local slot key
  while IFS=$'\t' read -r slot key; do
    [[ $key == "$1" ]] && { echo "$slot"; return; }
  done <"$slots"
}

op=$1
shift
key_file="" positional=()
while (( $# )); do
  case $1 in
    --key-file | --pbkdf | --iter-time) [[ $1 == "--key-file" ]] && key_file=$2; shift 2 ;;
    -*) shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
slots=${positional[0]}.slots
[[ -f $slots ]] || { echo "Device ${positional[0]} does not exist or access denied."; exit 4; }

case $op in
  open)
    crash_point "cryptsetup open"
    [[ -z ${TEST_OPEN_FAIL:-} ]] || exit 1
    if [[ $key_file == "-" ]]; then key=$(cat); else key=$(cat "$key_file"); fi
    slot=$(slot_of "$key")
    [[ -n $slot ]] || { echo "No key available with this passphrase."; exit 2; }
    echo "Key slot $slot unlocked."
    ;;
  luksChangeKey)
    crash_point "cryptsetup luksChangeKey"
    IFS= read -r current || true
    new=$(cat "${positional[1]}")
    old_slot=$(slot_of "$current")
    [[ -n $old_slot ]] || { echo "No key available with this passphrase."; exit 2; }
    for (( next = 0; next < 32; next++ )); do
      cut -f1 "$slots" | grep -qx "$next" || break
    done
    printf '%s\t%s\n' "$next" "$new" >>"$slots"
    crash_point "new key added"
    awk -F'\t' -v s="$old_slot" '$1 != s' "$slots" >"$slots.next"
    mv -f "$slots.next" "$slots"
    crash_point "old key removed"
    ;;
  *) exit 1 ;;
esac
SH

# The real cryptsetup with a fast KDF, counting the same crash points.
cat >"$tmp/real/cryptsetup" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"
args=()
while (( $# )); do
  case $1 in
    --pbkdf | --iter-time) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${args[0]} == "luksChangeKey" ]] && args+=(--pbkdf pbkdf2 --pbkdf-force-iterations 1000)
crash_point "cryptsetup ${args[0]}"
[[ ${args[0]} != "open" || -z ${TEST_OPEN_FAIL:-} ]] || exit 1
status=0
"$REAL_CRYPTSETUP" "${args[@]}" || status=$?
[[ ${args[0]} == "luksChangeKey" ]] && (( status == 0 )) && crash_point "key changed"
exit "$status"
SH

chmod +x "$tmp"/bin/* "$tmp/real/cryptsetup"

export TEST_TMP=$tmp OMARCHY_PATH=$ROOT XDG_STATE_HOME=$tmp/state SUDO_USER=owner
base_path=$PATH
system=$tmp/dev/system
data=$tmp/dev/data

# The slot the key opens, or nothing.
opens() {
  local device=$1 key=$2 slot k
  if [[ $backend == "fake" ]]; then
    while IFS=$'\t' read -r slot k; do
      [[ $k == "$key" ]] && { echo "$slot"; return; }
    done <"$device.slots"
  else
    LC_ALL=C "$REAL_CRYPTSETUP" open --test-passphrase --verbose --key-file <(printf '%s' "$key") "$device" 2>&1 |
      grep -o 'Key slot [0-9]* unlocked' | grep -o '[0-9]*' || true
  fi
}

account() {
  awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$tmp/accounts"
}

volume() {
  local device=$1 key=$2 extra=${3:-}
  if [[ $backend == "fake" ]]; then
    : >"$device"
    printf '0\t%s\n' "$key" >"$device.slots"
    [[ -z $extra ]] || printf '1\t%s\n' "$extra" >>"$device.slots"
  else
    rm -f "$device"
    truncate -s 32M "$device"
    "$REAL_CRYPTSETUP" luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$device" <(printf '%s' "$key")
    if [[ -n $extra ]]; then
      "$REAL_CRYPTSETUP" luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file <(printf '%s' "$key") "$device" <(printf '%s' "$extra")
    fi
  fi
}

# / on the system drive, which also holds a recovery key; a data drive beside it.
fixture() {
  rm -rf "$tmp/state" "$tmp/output" "$tmp/prompts" "$tmp/sudo-calls" "$tmp/trace"
  unset TEST_OPEN_FAIL TEST_CHPASSWD_FAIL
  volume "$system" "$old_password" "$recovery_key"
  volume "$data" "$data_password"
  printf 'owner\t%s\nroot\t%s\n' "$old_password" "$old_password" >"$tmp/accounts"
  printf '%s\n%s\n' "$system" "$data" >"$tmp/drives"
  printf '/dev/mapper/root btrfs\n%s crypto_LUKS\n/dev/fake-disk \n' "$system" >"$tmp/root-ancestry"
  echo "$system" >"$tmp/select"
  printf '%s\n' "$old_password" >"$tmp/tty"
  : >"$tmp/prompts"
  : >"$tmp/sudo-calls"
}

# One run of the command: answers for its prompts, then an optional crash step.
attempt() {
  local crash_at=$1
  shift
  if (( $# )); then printf '%s\n' "$@" >"$tmp/inputs"; else : >"$tmp/inputs"; fi
  echo 0 >"$tmp/steps"
  : >"$tmp/trace"
  {
    CRASH_AT=$crash_at bash -c 'TEST_PID=$$ exec bash "$0"' "$ROOT/bin/omarchy-drive-password"
  } >>"$tmp/output" 2>&1
}

consistent() {
  local context=$1 password=$2
  [[ $(account owner) == "$password" && $(account root) == "$password" ]] ||
    fail "$backend: $context: the login and root passwords are the disk password" "$(cat "$tmp/accounts" "$tmp/output")"
  [[ -n $(opens "$system" "$password") ]] || fail "$backend: $context: the disk opens with that password" "$(cat "$tmp/output")"
  [[ -n $(opens "$system" "$recovery_key") ]] || fail "$backend: $context: the recovery key still opens the disk"
  [[ ! -e $journal ]] || fail "$backend: $context: the journal is gone" "$(cat "$journal")"
}

no_secrets() {
  local file
  for file in "$journal" "$tmp/sudo-calls" "$tmp/prompts"; do
    [[ -e $file ]] || continue
    ! grep -Fq -e "$old_password" -e "$new_password" -e "$recovery_key" -e "$data_password" "$file" ||
      fail "$backend: $1: $(basename "$file") holds no password" "$(cat "$file")"
  done
}

# Between runs the disk and the accounts may disagree only while the journal
# says so, and the accounts never take a password the disk does not.
recoverable() {
  local context=$1 login
  login=$(account owner)
  [[ -n $(opens "$system" "$login") || -e $journal ]] ||
    fail "$backend: $context: a disk that no longer opens with the login password is journaled" "$(cat "$tmp/trace")"
  [[ $login == "$old_password" || -n $(opens "$system" "$login") ]] ||
    fail "$backend: $context: the login password changes only after the disk takes it" "$(cat "$tmp/trace")"
  [[ ! -e $journal || $(stat -c %a "$journal") == "600" ]] || fail "$backend: $context: the journal is private"
  no_secrets "$context"
}

# The password an interrupted run is finished with: the one that opens the disk.
current_disk_password() {
  if [[ -n $(opens "$system" "$new_password") ]]; then echo "$new_password"; else echo "$old_password"; fi
}

backends=(fake)
if REAL_CRYPTSETUP=$(command -v cryptsetup); then
  export REAL_CRYPTSETUP
  backends+=(luks2)
else
  pass "cryptsetup is not installed; skipping the file-backed volume runs"
fi

for backend in "${backends[@]}"; do
  if [[ $backend == "fake" ]]; then
    export PATH="$tmp/bin:$ROOT/bin:$base_path"
  else
    export PATH="$tmp/real:$tmp/bin:$ROOT/bin:$base_path"
  fi

  fixture
  attempt 0 "$new_password" "$new_password" || fail "$backend: changing the system disk password succeeds" "$(cat "$tmp/output")"
  consistent "uninterrupted" "$new_password"
  [[ -z $(opens "$system" "$old_password") ]] || fail "$backend: the old disk password no longer opens the disk"
  [[ $(opens "$data" "$data_password") == "0" ]] || fail "$backend: the data drive is untouched"
  first_account=$(grep -n 'chpasswd' "$tmp/trace" | head -1 | cut -d: -f1)
  last_luks=$(grep -n 'cryptsetup' "$tmp/trace" | tail -1 | cut -d: -f1)
  (( last_luks < first_account )) || fail "$backend: the disk key changes and is verified before any account" "$(cat "$tmp/trace")"
  grep -Fq 'login password for owner and root' "$tmp/output" || fail "$backend: the command says the login password follows the system disk"
  no_secrets "uninterrupted"
  total_steps=$(cat "$tmp/steps")
  (( total_steps >= 6 )) || fail "$backend: every change is a crash point" "$(cat "$tmp/trace")"
  pass "$backend: the system disk key changes and verifies first, then the login and root passwords follow"

  fixture
  printf 'not-the-password\n' >"$tmp/tty"
  if attempt 0 "$new_password" "$new_password"; then fail "$backend: a failed disk key change fails the command"; fi
  [[ $(account owner) == "$old_password" && $(account root) == "$old_password" ]] || fail "$backend: a failed disk key change leaves both accounts alone"
  ! grep -q '^chpasswd' "$tmp/sudo-calls" || fail "$backend: a failed disk key change runs no chpasswd"
  [[ -n $(opens "$system" "$old_password") && ! -e $journal ]] || fail "$backend: a failed disk key change leaves the disk and no journal"
  pass "$backend: a failed LUKS change leaves the login and root passwords unchanged"

  fixture
  echo "$data" >"$tmp/select"
  printf '%s\n' "$data_password" >"$tmp/tty"
  attempt 0 "$new_password" "$new_password" || fail "$backend: changing a data drive password succeeds" "$(cat "$tmp/output")"
  [[ -n $(opens "$data" "$new_password") && -z $(opens "$data" "$data_password") ]] || fail "$backend: the data drive takes the new password"
  [[ $(account owner) == "$old_password" && $(account root) == "$old_password" ]] || fail "$backend: a data drive leaves the login and root passwords alone"
  [[ -n $(opens "$system" "$old_password") ]] || fail "$backend: a data drive change leaves the system disk alone"
  ! grep -q '^chpasswd' "$tmp/sudo-calls" && [[ ! -e $journal ]] || fail "$backend: a data drive change runs no chpasswd and keeps no journal"
  ! grep -Fq 'login password' "$tmp/output" || fail "$backend: a data drive change does not mention the login password"
  pass "$backend: changing a non-root encrypted drive's password leaves the login unchanged"

  # Killed after each step, the owner runs the command again and answers with
  # the password that opens the disk now.
  for (( step = 1; step <= total_steps; step++ )); do
    fixture
    if attempt "$step" "$new_password" "$new_password"; then fail "$backend: the run is killed at step $step"; fi
    point=$(sed -n "${step}p" "$tmp/trace")
    recoverable "killed after '$point'"
    if [[ -e $journal ]]; then
      # The rerun is itself killed after each of its steps until one finishes.
      for (( again = 1; ; again++ )); do
        answer=$(current_disk_password)
        status=0
        attempt "$again" "$answer" || status=$?
        (( status == 0 )) && break
        (( status == 137 )) || fail "$backend: the rerun after '$point' finishes" "$(cat "$tmp/output")"
        recoverable "rerun after '$point' killed at step $again"
      done
      consistent "rerun after '$point'" "$answer"
    else
      if [[ $(account owner) == "$new_password" ]]; then
        consistent "killed after '$point'" "$new_password"
      else
        consistent "killed after '$point'" "$old_password"
      fi
    fi
    no_secrets "rerun after '$point'"
  done
  pass "$backend: killed after each of $total_steps steps, and each rerun killed after each of its own, a rerun ends with the disk, login and root on one password"
done

backend=fake
export PATH="$tmp/bin:$ROOT/bin:$base_path"

fixture
if attempt 3 "$new_password" "$new_password"; then fail "the run is killed after the disk key changes"; fi
point=$(sed -n 3p "$tmp/trace")
if attempt 0 "not-the-password"; then fail "a rerun refuses a password that opens nothing"; fi
[[ -e $journal && $(account owner) == "$old_password" ]] || fail "a refused rerun keeps the journal and the accounts"
attempt 0 "$new_password" || fail "the rerun with the new password finishes" "$(cat "$tmp/output")"
consistent "rerun after '$point'" "$new_password"
pass "a rerun refuses a password that does not open the disk and keeps the journal"

fixture
attempt 5 "$new_password" "$new_password" || true
grep -qx 'phase=accounts' "$journal" || fail "a crash before the accounts leaves the confirmed phase" "$(cat "$journal" "$tmp/trace")"
if attempt 0 "$recovery_key"; then fail "a confirmed change refuses the recovery key"; fi
[[ -e $journal && $(account owner) == "$old_password" ]] || fail "refusing the recovery key changes no account"
attempt 0 "$new_password" || fail "the confirmed change finishes with the new password" "$(cat "$tmp/output")"
consistent "rerun after a confirmed change" "$new_password"
pass "once the new key is confirmed, only its slot can finish the accounts"

fixture
export TEST_OPEN_FAIL=1
if attempt 0 "$new_password" "$new_password"; then fail "an unconfirmed new key fails the command"; fi
[[ $(account owner) == "$old_password" && -e $journal ]] || fail "an unconfirmed new key changes no account and keeps the journal"
unset TEST_OPEN_FAIL
attempt 0 "$new_password" || fail "the rerun confirms the key and finishes" "$(cat "$tmp/output")"
consistent "rerun after an unconfirmed key" "$new_password"
pass "the accounts change only after the new key is confirmed to open the disk"

fixture
export TEST_CHPASSWD_FAIL=root
if attempt 0 "$new_password" "$new_password"; then fail "a failed root password change fails the command"; fi
[[ $(account owner) == "$new_password" && $(account root) == "$old_password" && -e $journal ]] ||
  fail "a failed root password change keeps the journal"
unset TEST_CHPASSWD_FAIL
attempt 0 "$new_password" || fail "the rerun sets the root password" "$(cat "$tmp/output")"
consistent "rerun after a failed root password change" "$new_password"
pass "a failed account change is finished by the next run"

fixture
SUDO_USER=root
if attempt 0 "$new_password" "$new_password"; then fail "the system disk needs a login user"; fi
[[ ! -s $tmp/sudo-calls && ! -e $journal && -n $(opens "$system" "$old_password") ]] || fail "without a login user nothing changes"
echo "$data" >"$tmp/select"
printf '%s\n' "$data_password" >"$tmp/tty"
attempt 0 "$new_password" "$new_password" || fail "a data drive changes without a login user" "$(cat "$tmp/output")"
SUDO_USER=owner
pass "the system disk password changes only for a known login user"

fixture
printf '/dev/mapper/root btrfs\n/dev/mapper/cryptlvm LVM2_member\n%s crypto_LUKS\n/dev/fake-disk \n' "$system" >"$tmp/root-ancestry"
attempt 0 "$new_password" "$new_password" || fail "an LVM-on-LUKS system disk changes" "$(cat "$tmp/output")"
consistent "LVM on LUKS" "$new_password"
pass "the system disk is found beneath an LVM volume group"

fixture
printf '/dev/mapper/root ext4\n/dev/fake-disk \n' >"$tmp/root-ancestry"
echo "$data" >"$tmp/drives"
printf '%s\n' "$data_password" >"$tmp/tty"
attempt 0 "$new_password" "$new_password" || fail "an unencrypted root still changes a data drive" "$(cat "$tmp/output")"
[[ $(account owner) == "$old_password" && -n $(opens "$data" "$new_password") ]] || fail "an unencrypted root keeps the login password"
pass "with / unencrypted, every encrypted drive changes alone"

fixture
mkdir -p "${journal%/*}"
printf 'device=/dev/elsewhere\nphase=accounts\nslot=0\n' >"$journal"
attempt 0 "$new_password" "$new_password" || fail "a journal for another disk does not block a change" "$(cat "$tmp/output")"
consistent "stale journal" "$new_password"
pass "a journal for a disk that is not / is dropped"

fixture
if attempt 0 ""; then fail "an empty password is refused"; fi
if attempt 0 "secret123" "*"; then fail "a mismatched confirmation is refused"; fi
[[ ! -s $tmp/sudo-calls && ! -e $journal && $(account owner) == "$old_password" ]] || fail "refused passwords change nothing"
pass "drive password rejects empty and mismatched passphrases before changing anything"
