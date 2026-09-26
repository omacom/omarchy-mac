#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-drive-recover against a fake system disk: the owner forgot the
# password and unlocked the disk at boot with the recovery key, which systemd
# left in root's keyring (a keyctl fake). findmnt and lsblk describe / on the
# disk; cryptsetup is either a slot-table fake or the real binary on file-backed
# volumes; chpasswd records the accounts. Each cryptsetup and chpasswd call is a
# crash point, so a run can be killed after every step and rerun after the next
# unlock, like a power loss. The runs repeat on an Apple fixture, where a fake
# omarchy-mac-boot records the kept slots through the real
# omarchy-lifecycle-dispatch; on the x86 fixture that is a no-op.

# Root's dispatcher ignores the fixtures and sees this machine.
if (( EUID == 0 )) && [[ $("$(dirname -- "${BASH_SOURCE[0]}")/../../bin/omarchy-hw-platform") == "apple-silicon" ]]; then
  echo "ok - running as root on Apple Silicon, where dispatch ignores fixtures; skipping"
  exit 0
fi

tmp=$(mktemp -d)
token_key=""
REAL_KEYCTL=$(command -v keyctl || true)
trap 'rm -rf "$tmp"; [[ -z $token_key ]] || "$REAL_KEYCTL" unlink "$token_key" @s >/dev/null 2>&1 || true' EXIT

old_password=forgotten-password
new_password='new pass:word'
other_password='another new one'
recovery_key=ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-ABCD-EFGH-IJKL-MNOP
wrong_recovery=ZZZZ-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-ABCD-EFGH-IJKL-MNOP
journal=$tmp/state/drive-recover.state

mkdir -p "$tmp/bin" "$tmp/real" "$tmp/dev" "$tmp/units"

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

cat >"$tmp/bin/findmnt" <<'SH'
#!/bin/bash
case $* in
  "-no SOURCE /") echo '/dev/mapper/root[/@]' ;;
  "-no FSTYPE /") echo "${TEST_ROOT_FSTYPE:-btrfs}" ;;
  "-no OPTIONS /") echo "${TEST_ROOT_OPTIONS:-rw,relatime,subvol=/@}" ;;
  *) exit 1 ;;
esac
SH

cat >"$tmp/bin/lsblk" <<'SH'
#!/bin/bash
if [[ $1 == "-dno" && $2 == "UUID" ]]; then
  cat "$3.uuid"
  exit
fi
[[ $* == "-nsrpo NAME,TYPE,FSTYPE /dev/mapper/root" ]] || exit 98
cat "$TEST_TMP/root-ancestry"
SH

# Root's user keyring: the passwords typed at the unlock prompt, NUL-separated.
cat >"$tmp/bin/keyctl" <<'SH'
#!/bin/bash
case $1 in
  search) [[ $* == "search @u user cryptsetup" && -f $TEST_TMP/cache ]] && echo 123456789 || exit 1 ;;
  pipe) [[ $2 == 123456789 ]] && cat "$TEST_TMP/cache" ;;
  *) exit 1 ;;
esac
SH

cat >"$tmp/bin/getent" <<'SH'
#!/bin/bash
[[ $1 == "passwd" ]] || exit 2
if [[ -n ${2:-} ]]; then
  grep "^$2:" "$TEST_TMP/passwd" || exit 2
else
  cat "$TEST_TMP/passwd"
fi
SH

# gum input answers from the inputs file, one line each; confirm answers
# TEST_CONFIRM. Headers are recorded, never answers.
cat >"$tmp/bin/gum" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_TMP/prompts"
case $1 in
  confirm) [[ ${TEST_CONFIRM:-yes} == "yes" ]] ;;
  input)
    [[ -s $TEST_TMP/inputs ]] || exit 130
    head -n 1 "$TEST_TMP/inputs"
    sed -i '1d' "$TEST_TMP/inputs"
    ;;
  *) exit 97 ;;
esac
SH

cat >"$tmp/bin/chpasswd" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"
printf 'chpasswd %s\n' "$*" >>"$TEST_TMP/calls"
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

# A volume as a table of "slot<TAB>passphrase" lines next to the device.
# luksAddKey takes a key that opens a slot and adds to the first free one;
# luksKillSlot needs a key that opens another slot, as cryptsetup does.
cat >"$tmp/bin/cryptsetup" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"
printf 'cryptsetup %s\n' "$*" >>"$TEST_TMP/calls"

slot_of() {
  local slot key
  while IFS=$'\t' read -r slot key; do
    [[ $key == "$1" && $slot != "${2:-}" ]] && { echo "$slot"; return; }
  done <"$slots"
}

op=$1
shift
key_file="" token_type="" positional=()
while (( $# )); do
  case $1 in
    --key-file) key_file=$2; shift 2 ;;
    --token-type) token_type=$2; shift 2 ;;
    --pbkdf | --iter-time | --type) shift 2 ;;
    -*) shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
slots=${positional[0]}.slots
[[ -f $slots ]] || { echo "Device ${positional[0]} does not exist or access denied."; exit 4; }
key=""
[[ -z $key_file ]] || key=$(cat "$key_file")

[[ $op != "isLuks" ]] || exit 1
if [[ $op == "luksDump" ]]; then
  echo "Keyslots:"
  cut -f1 "$slots" | sed 's/^/  /; s/$/: luks2/'
  [[ -z ${TEST_TOKEN_SLOT:-} ]] || printf 'Tokens:\n  0: luks2-keyring\n\tKeyslot:    %s\n' "$TEST_TOKEN_SLOT"
  printf 'Digests:\n  0: pbkdf2\n'
  exit 0
fi

crash_point "cryptsetup $op"
if [[ $op == "open" && -z $token_type && -n ${TEST_TOKEN_SLOT:-} ]]; then
  echo "Key slot $TEST_TOKEN_SLOT unlocked."
  exit 0
fi
target=""
[[ $op == "luksKillSlot" ]] && target=${positional[1]}
slot=$(slot_of "$key" "$target")
[[ -n $slot ]] || { echo "No key available with this passphrase."; exit 2; }

case $op in
  open) echo "Key slot $slot unlocked." ;;
  luksAddKey)
    [[ -z ${TEST_ADD_FAIL:-} ]] || exit 1
    for (( next = 0; next < 32; next++ )); do
      cut -f1 "$slots" | grep -qx "$next" || break
    done
    printf '%s\t%s\n' "$next" "$(cat "${positional[1]}")" >>"$slots"
    crash_point "new key added"
    ;;
  luksKillSlot)
    awk -F'\t' -v s="$target" '$1 != s' "$slots" >"$slots.next"
    mv -f "$slots.next" "$slots"
    crash_point "slot $target killed"
    ;;
  *) exit 1 ;;
esac
SH

# The real cryptsetup at a fast KDF cost, counting the same crash points.
cat >"$tmp/real/cryptsetup" <<'SH'
#!/bin/bash
source "$TEST_TMP/crash.sh"
printf 'cryptsetup %s\n' "$*" >>"$TEST_TMP/calls"
args=()
while (( $# )); do
  case $1 in
    --iter-time) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [[ ${args[0]} == "luksAddKey" ]]; then
  if [[ " ${args[*]} " == *" argon2id "* ]]; then
    args+=(--pbkdf-force-iterations 4 --pbkdf-memory 32768)
  else
    args+=(--pbkdf-force-iterations 1000)
  fi
fi
[[ ${args[0]} == "luksDump" || ${args[0]} == "isLuks" ]] || crash_point "cryptsetup ${args[0]}"
status=0
"$REAL_CRYPTSETUP" "${args[@]}" || status=$?
if (( status == 0 )) && [[ ${args[0]} == "luksAddKey" || ${args[0]} == "luksKillSlot" ]]; then
  crash_point "${args[0]} done"
fi
exit "$status"
SH

chmod +x "$tmp"/bin/* "$tmp/real/cryptsetup"

fake_platform "$tmp/x86" generic
fake_platform "$tmp/apple" apple-silicon
mkdir -p "$tmp/lifecycle/usr/lib/omarchy/mac-boot"
cat >"$tmp/lifecycle/usr/lib/omarchy/mac-boot/luks-slots" <<SH
#!/bin/bash
[[ ! -e $tmp/record-fail ]] || exit 1
printf '%s\n' "\$*" >>"$tmp/slot-record"
count=\$(( \$(cat "$tmp/steps") + 1 ))
echo "\$count" >"$tmp/steps"
printf '%s slots recorded\n' "\$count" >>"$tmp/trace"
if (( count == \$(cat "$tmp/crash-at") )); then
  kill -9 "\$PPID"
  kill -9 \$\$
fi
SH
chmod 755 "$tmp/lifecycle/usr/lib/omarchy/mac-boot/luks-slots"
chmod -R go-w "$tmp/lifecycle"

export TEST_TMP=$tmp OMARCHY_PATH=$ROOT OMARCHY_LIFECYCLE_ROOT=$tmp/lifecycle
export OMARCHY_DRIVE_RECOVER_STATE=$journal OMARCHY_DRIVE_RECOVER_RUN_DIR=$tmp/run
export OMARCHY_SYSTEMD_UNIT_DIR=$tmp/units OMARCHY_PROVISIONING_DIR=$tmp/provisioning
export OMARCHY_AUTOLOGIN_CONF=$tmp/autologin.conf OMARCHY_CMDLINE=$tmp/cmdline OMARCHY_DRIVE_RECOVER_PAUSE=0
unset SUDO_USER
base_path=$PATH
armed=$tmp/run/drive-recover

use() {
  backend=$1 platform=$2
  export OMARCHY_PROC_ROOT=$tmp/$platform/proc
  if [[ $backend == "fake" ]]; then
    export PATH="$tmp/$platform/bin:$tmp/bin:$ROOT/bin:$base_path"
  else
    export PATH="$tmp/$platform/bin:$tmp/real:$tmp/bin:$ROOT/bin:$base_path"
  fi
}

# The slot the key opens, or nothing. Tokens never answer.
opens() {
  local key=$1 slot k
  if [[ $backend == "fake" ]]; then
    while IFS=$'\t' read -r slot k; do
      [[ $k == "$key" ]] && { echo "$slot"; return; }
    done <"$system.slots"
  else
    LC_ALL=C "$REAL_CRYPTSETUP" open --test-passphrase --verbose --token-type passphrase-only --key-file <(printf '%s' "$key") "$system" 2>&1 |
      grep -o 'Key slot [0-9]* unlocked' | grep -o '[0-9]*' || true
  fi
}

slot_count() {
  if [[ $backend == "fake" ]]; then
    wc -l <"$system.slots"
  else
    "$REAL_CRYPTSETUP" luksDump "$system" | awk '/^[^ \t]/ { k = ($0 == "Keyslots:") } k && /^ +[0-9]+: luks2/ { n++ } /^Key Slot [0-9]+: ENABLED/ { n++ } END { print n + 0 }'
  fi
}

account() {
  awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$tmp/accounts"
}

# The system disk: the owner's forgotten password in slot 0 and the recovery
# key in slot 1, and optionally more keys after them.
fixture() {
  local extra
  rm -rf "$tmp/state" "$tmp/run" "$tmp/output" "$tmp/trace" "$tmp/cache" "$tmp/inputs" "$tmp/slot-record" "$tmp/record-fail" \
    "$tmp/provisioning" "$tmp"/dev/* "$tmp/units"
  unset TEST_CHPASSWD_FAIL TEST_ADD_FAIL TEST_TOKEN_SLOT TEST_ROOT_FSTYPE TEST_ROOT_OPTIONS TEST_CONFIRM
  mkdir -p "$tmp/run" "$tmp/units"
  system=$tmp/dev/system
  echo "uuid-system" >"$system.uuid"
  if [[ $backend == "fake" ]]; then
    : >"$system"
    printf '0\t%s\n1\t%s\n' "$old_password" "$recovery_key" >"$system.slots"
    for extra in "$@"; do
      printf '%s\t%s\n' "$(wc -l <"$system.slots")" "$extra" >>"$system.slots"
    done
  else
    rm -f "$system"
    truncate -s 32M "$system"
    "$REAL_CRYPTSETUP" luksFormat -q --type "$backend" --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$system" <(printf '%s' "$old_password")
    for extra in "$recovery_key" "$@"; do
      "$REAL_CRYPTSETUP" luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file <(printf '%s' "$old_password") "$system" <(printf '%s' "$extra")
    done
  fi
  printf 'owner\t%s\nroot\t%s\n' "$old_password" "$old_password" >"$tmp/accounts"
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nnobody:x:65534:65534::/:/usr/bin/nologin\n' >"$tmp/passwd"
  printf '[Autologin]\nUser=owner\nSession=omarchy.desktop\n' >"$tmp/autologin.conf"
  printf 'root=UUID=x rw rootflags=subvol=@ quiet\n' >"$tmp/cmdline"
  printf '/dev/mapper/root crypt btrfs\n%s part crypto_LUKS\n/dev/fake-disk disk \n' "$system" >"$tmp/root-ancestry"
  : >"$tmp/prompts"
  : >"$tmp/calls"
  recovery_slot=$(opens "$recovery_key")
}

# What the owner typed at the unlock prompt, in order.
typed_at_boot() {
  if (( $# )); then printf '%s\0' "$@" >"$tmp/cache"; else rm -f "$tmp/cache"; fi
}

# One boot's check and, when it arms the reset, the reset with an optional
# crash step, answering its password prompts in order.
attempt() {
  local crash_at=$1
  shift
  if (( $# )); then printf '%s\n' "$@" >"$tmp/inputs"; else : >"$tmp/inputs"; fi
  echo 0 >"$tmp/steps"
  echo "$crash_at" >"$tmp/crash-at"
  : >"$tmp/trace"
  bash "$ROOT/bin/omarchy-drive-recover" --check >>"$tmp/output" 2>&1 || return
  [[ -e $armed ]] || return 0
  {
    CRASH_AT=$crash_at bash -c 'TEST_PID=$$ exec bash ${TEST_TRACE:+-x} "$0"' "$ROOT/bin/omarchy-drive-recover"
  } >>"$tmp/output" 2>&1
}

said() {
  grep -Fq "$1" "$tmp/output" || fail "$backend $platform: the reset says: $1" "$(cat "$tmp/output")"
}

untouched() {
  local context=$1
  [[ $(opens "$old_password") == "0" && $(opens "$recovery_key") == "$recovery_slot" ]] ||
    fail "$backend $platform: $context: the disk keeps its keys" "$(cat "$tmp/trace" "$tmp/output")"
  [[ $(account owner) == "$old_password" && $(account root) == "$old_password" ]] ||
    fail "$backend $platform: $context: the accounts keep their password"
  [[ ! -e $journal && ! -e $tmp/slot-record ]] || fail "$backend $platform: $context: no journal and no record"
  ! grep -q '^chpasswd\|luksAddKey\|luksKillSlot' "$tmp/calls" || fail "$backend $platform: $context: nothing changes" "$(cat "$tmp/calls")"
}

# The disk ends with the new password and the recovery key alone, the accounts
# take the new password, and the platform records the two slots.
reset_to() {
  local context=$1 password=$2 slot
  slot=$(opens "$password")
  [[ -n $slot && $slot != "$recovery_slot" ]] || fail "$backend $platform: $context: the new password opens the disk" "$(cat "$tmp/trace" "$tmp/output")"
  [[ $(opens "$recovery_key") == "$recovery_slot" ]] || fail "$backend $platform: $context: the recovery key keeps its slot"
  [[ $(slot_count) == 2 ]] || fail "$backend $platform: $context: only the new password and the recovery key remain ($(slot_count) slots)" "$(cat "$tmp/trace")"
  [[ -z $(opens "$old_password") ]] || fail "$backend $platform: $context: the forgotten password no longer opens the disk"
  [[ $(account owner) == "$password" && $(account root) == "$password" ]] ||
    fail "$backend $platform: $context: owner and root take the new password" "$(cat "$tmp/accounts" "$tmp/output")"
  [[ ! -e $journal ]] || fail "$backend $platform: $context: the journal is gone" "$(cat "$journal")"
  if [[ $platform == "apple" ]]; then
    [[ $(tail -n 1 "$tmp/slot-record" 2>/dev/null) == "owner=$slot recovery=$recovery_slot" ]] ||
      fail "apple: $context: the boot package records the two slots" "$(cat "$tmp/slot-record" 2>/dev/null)"
  else
    [[ ! -e $tmp/slot-record ]] || fail "x86: $context: nothing records the slots"
  fi
  no_secrets "$context"
}

no_secrets() {
  local file
  for file in "$journal" "$tmp/calls" "$tmp/prompts" "$tmp/trace"; do
    [[ -e $file ]] || continue
    ! grep -Fq -e "$old_password" -e "$new_password" -e "$other_password" -e "$recovery_key" "$file" ||
      fail "$backend $platform: $1: $(basename "$file") holds no key" "$(cat "$file")"
  done
}

# Between boots: the recovery key always opens the disk in its slot, and a disk
# that no longer opens with the login password is journaled. (A resumed reset
# may choose another password, retiring the one the accounts took first.)
recoverable() {
  local context=$1 login
  login=$(account owner)
  [[ $(opens "$recovery_key") == "$recovery_slot" ]] || fail "$backend $platform: $context: the recovery key still opens the disk" "$(cat "$tmp/trace")"
  [[ $(account root) == "$login" || -e $journal ]] ||
    fail "$backend $platform: $context: owner and root disagree only while journaled" "$(cat "$tmp/accounts")"
  [[ -n $(opens "$login") || -e $journal ]] ||
    fail "$backend $platform: $context: a disk that no longer opens with the login password is journaled" "$(cat "$tmp/trace")"
  [[ ! -e $journal || $(stat -c %a "$journal") == "600" ]] || fail "$backend $platform: $context: the journal is private"
  no_secrets "$context"
}

backends=(fake)
if REAL_CRYPTSETUP=$(command -v cryptsetup); then
  export REAL_CRYPTSETUP
  backends+=(luks2 luks1)
else
  pass "cryptsetup is not installed; skipping the file-backed volume runs"
fi

# ── arming ───────────────────────────────────────────────────────────────────
use fake x86
fixture
bash "$ROOT/bin/omarchy-drive-recover" --arm || fail "--arm installs the units"
bash "$ROOT/bin/omarchy-drive-recover" --arm || fail "--arm runs again"
for unit in omarchy-drive-recover-check.service omarchy-drive-recover.service; do
  cmp -s "$ROOT/install/provisioning/$unit" "$tmp/units/$unit" || fail "--arm installs $unit"
  [[ $(stat -c %a "$tmp/units/$unit") == "644" ]] || fail "$unit is 644"
  [[ $(readlink "$tmp/units/multi-user.target.wants/$unit") == "$tmp/units/$unit" ]] || fail "--arm enables $unit"
done
grep -qx 'KeyringMode=shared' "$ROOT/install/provisioning/omarchy-drive-recover-check.service" &&
  grep -qx 'KeyringMode=shared' "$ROOT/install/provisioning/omarchy-drive-recover.service" ||
  fail "both units read root's user keyring"
grep -qx 'ConditionPathExists=/run/omarchy/drive-recover' "$ROOT/install/provisioning/omarchy-drive-recover.service" &&
  grep -q '^Before=.*display-manager.service' "$ROOT/install/provisioning/omarchy-drive-recover.service" ||
  fail "the reset runs only when armed, before the login screen"
pass "--arm installs and enables the check and the reset, which run before the login screen only when armed"

# ── what arms the reset ──────────────────────────────────────────────────────
fixture
typed_at_boot "$old_password"
attempt 0
[[ ! -e $armed ]] || fail "a boot unlocked with the password arms nothing"
typed_at_boot
attempt 0
[[ ! -e $armed ]] || fail "a boot unlocked without a typed key arms nothing"
typed_at_boot "not-it" "$recovery_key"
attempt 0 || true
[[ -e $armed ]] || fail "a boot unlocked with the recovery key, after a typo, arms the reset"
typed_at_boot "$recovery_key"
printf 'root=UUID=x rw rootflags=subvol=@/.snapshots/12/snapshot quiet\n' >"$tmp/cmdline"
attempt 0
[[ ! -e $armed ]] || fail "a snapshot boot arms nothing"
printf 'root=UUID=x rw rootflags=subvol=@ quiet\n' >"$tmp/cmdline"
TEST_ROOT_FSTYPE=overlay attempt 0
[[ ! -e $armed ]] || fail "an overlay root arms nothing"
TEST_ROOT_OPTIONS=ro,relatime attempt 0
[[ ! -e $armed ]] || fail "a read-only root arms nothing"
mkdir -p "$tmp/provisioning" && touch "$tmp/provisioning/pending"
attempt 0
[[ ! -e $armed ]] || fail "owner setup still pending arms nothing"
rm -r "$tmp/provisioning"
printf '/dev/mapper/root part btrfs\n/dev/fake-disk disk \n' >"$tmp/root-ancestry"
attempt 0
[[ ! -e $armed ]] || fail "an unencrypted root arms nothing"
untouched "no reset armed"
pass "only a boot unlocked with the recovery key arms the reset: not the password, a snapshot, a read-only root, pending setup or a plain root"

fixture
typed_at_boot "$wrong_recovery"
attempt 0 || fail "a recovery key that opens nothing exits cleanly" "$(cat "$tmp/output")"
[[ ! -s $tmp/prompts ]] || fail "a recovery key that opens nothing asks nothing" "$(cat "$tmp/prompts")"
untouched "a recovery key that opens nothing"
pass "a key in the recovery key's form that opens nothing changes nothing and asks nothing"

fixture
typed_at_boot "$recovery_key"
export TEST_CONFIRM=no
attempt 0 || fail "declining the reset exits cleanly" "$(cat "$tmp/output")"
unset TEST_CONFIRM
grep -q '^confirm' "$tmp/prompts" && ! grep -q '^input' "$tmp/prompts" || fail "declining asks no password" "$(cat "$tmp/prompts")"
untouched "declined"
pass "the owner can decline the reset, and nothing changes"

# ── the reset, uninterrupted and killed after every step ───────────────────
matrix=()
for backend in "${backends[@]}"; do
  matrix+=("$backend x86" "$backend apple")
done

for run_spec in "${matrix[@]}"; do
  use $run_spec

  fixture
  typed_at_boot "$recovery_key"
  attempt 0 "$new_password" "$new_password" || fail "$backend $platform: the reset succeeds" "$(cat "$tmp/output")"
  reset_to "uninterrupted" "$new_password"
  first_account=$(grep -n 'chpasswd' "$tmp/trace" | head -1 | cut -d: -f1)
  last_luks=$(grep -n 'cryptsetup\|luksAddKey\|luksKillSlot\|slot .* killed\|new key added' "$tmp/trace" | tail -1 | cut -d: -f1)
  (( last_luks < first_account )) || fail "$backend $platform: the disk changes and verifies before any account" "$(cat "$tmp/trace")"
  said "unlocked with its recovery key"
  said "use the new password; the recovery key still unlocks the disk"
  total_steps=$(cat "$tmp/steps")
  (( total_steps >= 8 )) || fail "$backend $platform: every change is a crash point" "$(cat "$tmp/trace")"

  typed_at_boot "$new_password"
  : >"$tmp/prompts"
  attempt 0
  [[ ! -e $armed && ! -s $tmp/prompts ]] || fail "$backend $platform: the next boot, unlocked with the new password, offers no reset"
  pass "$backend $platform: unlocked with the recovery key, the disk takes a new password, then owner and root follow it"

  # Killed after each step, the owner unlocks again with the recovery key and
  # chooses the same password or another; each of those runs is itself killed
  # after each of its steps until one finishes.
  for (( step = 1; step <= total_steps; step++ )); do
    for answer in "$new_password" "$other_password"; do
      fixture
      typed_at_boot "$recovery_key"
      if attempt "$step" "$new_password" "$new_password"; then fail "$backend $platform: the reset is killed at step $step"; fi
      point=$(sed -n "${step}p" "$tmp/trace")
      recoverable "killed after '$point'"
      if [[ ! -e $journal ]]; then
        if [[ $(account owner) == "$new_password" ]]; then
          reset_to "killed after '$point'" "$new_password"
          continue
        fi
        [[ -z $(opens "$new_password") || $(opens "$old_password") == "0" ]] ||
          fail "$backend $platform: killed after '$point' before the journal, the disk is unchanged"
      fi
      for (( again = 1; ; again++ )); do
        status=0
        typed_at_boot "$recovery_key"
        attempt "$again" "$answer" "$answer" || status=$?
        (( status == 0 )) && break
        (( status == 137 )) || fail "$backend $platform: the rerun after '$point' finishes" "$(cat "$tmp/output")"
        recoverable "rerun after '$point' killed at step $again"
      done
      reset_to "rerun with the recovery key after '$point'" "$answer"
    done
  done
  pass "$backend $platform: killed after each of $total_steps steps, and each rerun after each of its own, the disk ends with the recovery key and one new password that owner and root share"
done

use fake x86

# Once the disk holds the new password beside the recovery key, a boot
# unlocked with that password finishes the accounts without asking.
fixture
typed_at_boot "$recovery_key"
attempt 0 "$new_password" "$new_password"
chpasswd_step=$(grep -n 'chpasswd owner' "$tmp/trace" | head -1 | cut -d: -f1)
fixture
typed_at_boot "$recovery_key"
attempt "$chpasswd_step" "$new_password" "$new_password" || true
grep -qx 'phase=accounts' "$journal" || fail "a crash at the accounts leaves the accounts phase" "$(cat "$journal" "$tmp/trace")"
typed_at_boot "$new_password"
: >"$tmp/prompts"
attempt 0 || fail "a boot unlocked with the new password finishes the reset" "$(cat "$tmp/output")"
[[ ! -s $tmp/prompts ]] || fail "finishing the accounts asks nothing" "$(cat "$tmp/prompts")"
said "Finishing the password reset"
reset_to "finished from the new password" "$new_password"
pass "a boot unlocked with the new password finishes a reset stopped at the accounts, asking nothing"

# A reset stopped part way, then a boot unlocked with the forgotten password
# (or a key file): the reset asks for the recovery key, and can be skipped.
fixture
typed_at_boot "$recovery_key"
attempt 3 "$new_password" "$new_password" || true
[[ -e $journal ]] || fail "a reset killed early keeps its journal" "$(cat "$tmp/trace")"
typed_at_boot
attempt 0 ""
[[ -e $journal && $(account owner) == "$old_password" ]] || fail "skipping the pending reset keeps the journal and the accounts"
said "stopped part way"
attempt 0 "$wrong_recovery" "$old_password" "$new_password" || true
said "That does not finish the reset."
[[ -e $journal && $(account owner) == "$old_password" ]] || fail "keys that do not finish the reset change nothing"
attempt 0 "$recovery_key" "$new_password" "$new_password" || fail "the recovery key typed at the reset finishes it" "$(cat "$tmp/output")"
reset_to "recovery key typed at the reset" "$new_password"
pass "a pending reset asks for the recovery key on a boot unlocked otherwise, and refuses keys that do not finish it"

fixture
typed_at_boot "$recovery_key"
attempt 0 "" "" "$new_password" "other" "$recovery_key" "$recovery_key" "$new_password" "$new_password" ||
  fail "the reset asks again after refused passwords" "$(cat "$tmp/output")"
said "Password cannot be empty."
said "Passwords do not match."
said "That has the form of a recovery key."
reset_to "after refused passwords" "$new_password"
pass "the reset refuses an empty password, a mismatched confirmation and one in the recovery key's form"

# Every other key goes, and a token never answers for the recovery key.
fixture "second-password" "third-password"
export TEST_TOKEN_SLOT=3
typed_at_boot "$wrong_recovery"
attempt 0 "$new_password" "$new_password" || true
[[ ! -s $tmp/prompts && $(account owner) == "$old_password" && $(slot_count) == 4 ]] ||
  fail "an enrolled token does not stand in for the recovery key" "$(cat "$tmp/prompts")"
typed_at_boot "$recovery_key"
attempt 0 "$new_password" "$new_password" || fail "a disk with more keys and a token resets" "$(cat "$tmp/output")"
unset TEST_TOKEN_SLOT
reset_to "more keys and a token" "$new_password"
[[ -z $(opens second-password) && -z $(opens third-password) ]] || fail "every other key is removed"
pass "the reset removes every key but the recovery key and the new password, and a token never answers for the recovery key"

if [[ " ${backends[*]} " == *" luks2 "* ]]; then
  use luks2 x86
  fixture
  if [[ -n $REAL_KEYCTL ]] && token_key=$(printf '%s' "$old_password" | "$REAL_KEYCTL" padd user omarchy-recover-test-$$ @s 2>/dev/null); then
    "$REAL_CRYPTSETUP" token add --key-description omarchy-recover-test-$$ --key-slot 0 "$system" >/dev/null
    # The real keyring token answers a bare cryptsetup open with any key.
    LC_ALL=C "$REAL_CRYPTSETUP" open --test-passphrase --verbose --key-file <(printf '%s' "$wrong_recovery") "$system" 2>&1 | grep -qx 'Key slot 0 unlocked.' ||
      fail "luks2: the fixture's keyring token answers any key"
    typed_at_boot "$wrong_recovery"
    attempt 0 "$new_password" "$new_password" || true
    [[ ! -s $tmp/prompts && $(account owner) == "$old_password" ]] || fail "luks2: a live keyring token does not stand in for the recovery key"
    typed_at_boot "$recovery_key"
    attempt 0 "$new_password" "$new_password" || fail "luks2: a disk with a live token resets" "$(cat "$tmp/output")"
    reset_to "beside a live keyring token" "$new_password"
    pass "luks2: with a live keyring token enrolled, only the real recovery key opens the reset"
  else
    pass "the kernel keyring is out of reach; skipping the live token run"
  fi
  use fake x86
fi

fixture
typed_at_boot "$recovery_key"
export TEST_ADD_FAIL=1
attempt 0 "$new_password" "$new_password" || true
unset TEST_ADD_FAIL
said "The password reset stopped"
[[ -e $journal && $(account owner) == "$old_password" && $(opens "$old_password") == "0" ]] ||
  fail "a failed key add keeps the journal, the accounts and the old key"
attempt 0 "$new_password" "$new_password" || fail "the next boot finishes after a failed add" "$(cat "$tmp/output")"
reset_to "rerun after a failed add" "$new_password"
pass "a failed key add changes no account, and the next boot with the recovery key finishes"

fixture
typed_at_boot "$recovery_key"
export TEST_CHPASSWD_FAIL=root
attempt 0 "$new_password" "$new_password" || true
unset TEST_CHPASSWD_FAIL
[[ $(account owner) == "$new_password" && $(account root) == "$old_password" ]] && grep -qx 'phase=accounts' "$journal" ||
  fail "a failed root password change keeps the accounts phase"
typed_at_boot "$new_password"
attempt 0 || fail "the next boot sets the root password" "$(cat "$tmp/output")"
reset_to "rerun after a failed root password change" "$new_password"
pass "a failed account change is finished by the next boot"

# The login user: autologin's, else the only person's; otherwise nothing changes.
fixture
rm "$tmp/autologin.conf"
typed_at_boot "$recovery_key"
attempt 0 "$new_password" "$new_password" || fail "without autologin the only person's account follows" "$(cat "$tmp/output")"
reset_to "no autologin, one person" "$new_password"
fixture
rm "$tmp/autologin.conf"
echo 'guest:x:1001:1001::/home/guest:/bin/bash' >>"$tmp/passwd"
typed_at_boot "$recovery_key"
if attempt 0 "$new_password" "$new_password"; then fail "without autologin and with two people the reset stops"; fi
said "could not tell whose login password"
untouched "two people and no autologin"
pass "the autologin user's password follows the disk, else the only person's; with two people nothing changes"

use fake apple
fixture
typed_at_boot "$recovery_key"
touch "$tmp/record-fail"
if attempt 0 "$new_password" "$new_password"; then fail "apple: a failed record fails the reset"; fi
[[ -e $journal && $(account owner) == "$new_password" && ! -e $tmp/slot-record ]] || fail "apple: a failed record keeps the journal"
rm "$tmp/record-fail"
typed_at_boot "$new_password"
attempt 0 || fail "apple: the next boot records the slots" "$(cat "$tmp/output")"
reset_to "rerun after a failed record" "$new_password"
pass "apple: the reset finishes only once the boot package recorded the new slot and the recovery slot"
use fake x86

fixture
typed_at_boot "$recovery_key"
mkdir -p "${journal%/*}"
printf 'uuid=uuid-elsewhere\nphase=accounts\nslot=0\n' >"$journal"
attempt 0 "$new_password" "$new_password" || fail "a journal for another disk does not block the reset" "$(cat "$tmp/output")"
reset_to "stale journal" "$new_password"
pass "a journal for a disk that is not / is dropped"

fixture
typed_at_boot "$recovery_key"
bash "$ROOT/bin/omarchy-drive-recover" --check >/dev/null
exec {held}>"$tmp/run/drive-recover.lock"
flock -n "$held"
bash "$ROOT/bin/omarchy-drive-recover" </dev/null >"$tmp/output" 2>&1 || fail "a second reset exits while one runs"
exec {held}>&-
untouched "a reset already running"
pass "two resets never interleave"

fixture
typed_at_boot "$recovery_key"
export TEST_TRACE=1
attempt 0 "$new_password" "$new_password" || fail "a traced reset succeeds" "$(cat "$tmp/output")"
unset TEST_TRACE
! grep -Fq -e "$recovery_key" -e "$new_password" "$tmp/output" || fail "tracing never shows a key" "$(cat "$tmp/output")"
reset_to "traced" "$new_password"
pass "bash -x does not trace keys"
