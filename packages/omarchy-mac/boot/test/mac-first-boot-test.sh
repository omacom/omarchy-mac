#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$ROOT/files/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot
unit=$ROOT/files/usr/lib/systemd/system/omarchy-mac-first-boot.service
hardware_dropin=$ROOT/files/usr/lib/systemd/system/omarchy-provision-hardware.service.d/20-mac-first-boot.conf
arm_key_file=${script%/*}/omarchy-arm-repository.key
arm_repository_key=C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC
keyring_master_fpr=$(printf 'A%.0s' {1..40})
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stubs=$tmp/bin
mkdir -p "$stubs"

fail() {
  echo "not ok - $1" >&2
  [[ -z ${case_dir:-} || ! -f $case_dir/out ]] || cat "$case_dir/out" >&2
  exit 1
}

cat >"$stubs/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$CASE/systemctl.log"
if [[ $1 == daemon-reload && -e $CASE/daemon-reload-fails ]]; then
  exit 1
fi
if [[ $1 == start && -e $CASE/start-fails ]]; then
  wanted=$(<"$CASE/start-fails")
  [[ -n $wanted && $* != *"$wanted"* ]] || exit 1
fi
STUB

cat >"$stubs/gum" <<'STUB'
#!/bin/bash
echo "gum $*" >>"$CASE/gum.log"
[[ -s $CASE/gum ]] || exit 1
answer=$(head -n 1 "$CASE/gum")
sed -i 1d "$CASE/gum"
printf '%s\n' "$answer"
STUB

cat >"$stubs/sync" <<'STUB'
#!/bin/bash
root=$OMARCHY_MAC_FIRST_BOOT_ROOT
target=${1-}
pending=$([[ -e $root/var/lib/omarchy/mac-first-boot/pending ]] && echo yes || echo no)
esp=$([[ -e $root/boot/efi/omarchy/install.conf ]] && echo yes || echo no)
echo "sync ${target:-all}" >>"$CASE/sync.log"
echo "pending=$pending" >>"$CASE/sync.log"
echo "esp=$esp" >>"$CASE/sync.log"
if [[ -e $CASE/sync-fails ]]; then
  exit 1
fi
if [[ -e $CASE/sync-fail-dir && -n $target && -d $target ]]; then
  exit 1
fi
# The commit sync is the directory sync right after pending is cleared.
if [[ -e $CASE/sync-fail-commit && -n $target && -d $target && $pending == no ]]; then
  rm -f "$CASE/sync-fail-commit"
  exit 1
fi
STUB

cat >"$stubs/pacman-key" <<'STUB'
#!/bin/bash
echo "pacman-key $*" >>"$CASE/pacman-key.log"
dir=""
while (($#)); do
  case $1 in
    --gpgdir) dir=$2; shift 2 ;;
    --populate-from) shift 2 ;;
    *) break ;;
  esac
done
case $1 in
  --init)
    mkdir -p -m 0755 "$dir"
    printf '%s\n' "$KEYRING_MASTER" >"$dir/omarchy-master"
    ;;
  --populate)
    shift
    for keyring in "$@"; do
      [[ $keyring == omarchy ]] || continue
      : >"$dir/omarchy-populated"
    done
    exit 0
    ;;
  --add) ;;
  --lsign-key)
    printf '%s\n' "$2" >"$dir/omarchy-lsigned"
    ;;
  *) exit 2 ;;
esac
STUB

cat >"$stubs/gpg" <<'STUB'
#!/bin/bash
homedir="" mode="" args=()
while (($#)); do
  case $1 in
    --batch|--with-colons) shift ;;
    --homedir) homedir=$2; shift 2 ;;
    --list-secret-keys|--check-sigs|--show-keys) mode=$1; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
case $mode in
  --list-secret-keys)
    [[ -f $homedir/omarchy-master ]] || exit 0
    printf 'sec:u:255:22:0:0::::::\nfpr:::::::::%s:\n' "$(cat "$homedir/omarchy-master")"
    ;;
  --show-keys)
    [[ -f ${args[0]} ]] || exit 1
    printf 'pub:u:255:22:0:0::::::\nfpr:::::::::%s:\n' "$ARM_REPOSITORY_KEY"
    ;;
  --check-sigs)
    key=${args[0]}
    signer=$(cat "$homedir/omarchy-master" 2>/dev/null || true)
    if [[ $key == 40DFB630FF42BCFFB047046CF0134EE680CAC571 ]]; then
      # populate omarchy imports and locally signs the release key
      [[ -f $homedir/omarchy-populated ]] || exit 2
      printf 'pub:f:::::::::\nsig:!:::%s::::::l:\n' "${signer:24}"
      exit 0
    fi
    [[ -f $homedir/omarchy-master && -f $homedir/omarchy-lsigned ]] || exit 1
    [[ $(<"$homedir/omarchy-lsigned") == "$ARM_REPOSITORY_KEY" ]] || exit 1
    printf 'pub:f:::::::::\nsig:!:::%s::::::l:\n' "${signer:24}"
    ;;
  *) exit 2 ;;
esac
STUB

printf '#!/bin/bash\n' >"$stubs/sleep"
chmod +x "$stubs"/*

# omarchy-provision-hardware: runs the queue the image build deferred.
deferred_stub() {
  cat >"$1" <<'STUB'
#!/bin/bash
(( $# == 0 )) || {
  echo "omarchy-provision-hardware takes no arguments: $*" >&2
  exit 1
}
root=$OMARCHY_MAC_FIRST_BOOT_ROOT
echo "keyring=$([[ -f $root/var/lib/omarchy/mac-first-boot/keyring ]] && echo yes || echo no)" >>"$CASE/deferred.log"
echo deferred >>"$CASE/deferred.log"
if [[ -e $CASE/deferred-fails ]]; then
  rm -f "$CASE/deferred-fails"
  echo "deferred failed" >&2
  exit 1
fi
STUB
  chmod +x "$1"
}

case_dir="" root=""
new_case() {
  case_dir=$tmp/case-$1
  root=$case_dir/root
  mkdir -p "$root/boot/efi/omarchy" "$root/var/log" "$root/var/lib/omarchy/provisioning" \
    "$root/usr/share/omarchy/install/provisioning" "$root/usr/bin" "$root/etc/systemd/system" \
    "$root/usr/share/pacman/keyrings"
  printf '[Unit]\nDescription=Omarchy provisioning first-boot user setup\n' \
    >"$root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  printf '#!/bin/bash\n' >"$root/usr/bin/omarchy-provision-owner"
  chmod 755 "$root/usr/bin/omarchy-provision-owner"
  "$BASH" "$script" arm "$root"
  : >"$root/var/lib/omarchy/provisioning/pending"
  : >"$case_dir/systemctl.log"
  : >"$case_dir/sync.log"
  : >"$case_dir/deferred.log"
  : >"$case_dir/pacman-key.log"
  deferred_stub "$root/usr/bin/omarchy-provision-hardware"
}

run() {
  timeout --kill-after=5 30 env OMARCHY_PATH="$root/usr/share/omarchy" PATH="$stubs:$PATH" CASE="$case_dir" \
    OMARCHY_MAC_FIRST_BOOT_ROOT="$root" \
    KEYRING_MASTER="$keyring_master_fpr" \
    ARM_REPOSITORY_KEY="$arm_repository_key" \
    "$BASH" -c 'source "$1"; "$2"' _ "$script" "$1" \
    </dev/null >"$case_dir/out" 2>&1
}

expect_stop() {
  if run attempt; then fail "$1: the attempt succeeded"; fi
  grep -Fq -- "$2" "$root/var/lib/omarchy/mac-first-boot/last-error" || fail "$1: expected '$2'"
  [[ -f $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "$1: first boot stays pending"
  [[ -f $root/var/lib/omarchy/provisioning/pending ]] || fail "$1: T1's provisioning marker stays"
  # A rejected start may have cleared pending for the gated units; it must be re-armed and synced last.
  [[ $(grep -F 'pending=' "$case_dir/sync.log" 2>/dev/null | tail -1) != 'pending=no' ]] ||
    fail "$1: pending is not re-armed after the failure"
  [[ ! -e $root/var/lib/omarchy/mac-first-boot/encrypt-pending ]] || fail "$1: encrypt-pending was written"
}

expect_handoff() {
  run attempt || fail "$1: the attempt failed"
  [[ ! -e $root/boot/efi/omarchy/install.conf ]] || fail "$1: the ESP copy is still there"
  [[ ! -e $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "$1: pending remains"
  [[ ! -e $root/var/lib/omarchy/mac-first-boot/encrypt-pending ]] || fail "$1: encrypt-pending was written"
  [[ -f $root/var/lib/omarchy/provisioning/pending ]] || fail "$1: T1's provisioning marker was dropped"
  [[ ! -e $root/var/lib/omarchy/provisioning/luks-key ]] || fail "$1: first boot must not touch luks-key"
  ! grep -Fq reboot "$case_dir/systemctl.log" || fail "$1: rebooted"
  grep -Fxq 'systemctl enable speakersafetyd.service sddm.service' "$case_dir/systemctl.log" ||
    fail "$1: the display manager is not enabled"
  [[ $(grep -E 'daemon-reload|^systemctl start' "$case_dir/systemctl.log") == \
    $'systemctl daemon-reload\nsystemctl start --no-block omarchy-provision-owner.service\nsystemctl start --no-block display-manager.service' ]] ||
    fail "$1: reload then queued starts, then pending is cleared"
  grep -Fxq 'pending=no' "$case_dir/sync.log" || fail "$1: the commit syncs after removing pending"
}

write_esp() {
  printf '%s\n' "$@" >"$root/boot/efi/omarchy/install.conf"
}

# ── unit ───────────────────────────────────────────────────────────────────
[[ -x $script ]] || fail "the first-boot script is executable"
[[ ! -e $arm_key_file ]] || fail "the upstream ARM repository key must not be shipped"
for line in 'ConditionPathExists=/var/lib/omarchy/mac-first-boot/pending' \
  'Conflicts=getty@tty1.service' 'Before=getty@tty1.service' \
  'Conflicts=omarchy-first-boot.service' 'After=omarchy-first-boot.service' \
  'After=systemd-user-sessions.service omarchy-vendor-firmware.service' \
  'Restart=no' 'StandardInput=null' \
  'StandardOutput=journal' 'StandardError=journal' \
  'WantedBy=multi-user.target' \
  'ExecStart=/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot' \
  'Environment=OMARCHY_PATH=/usr/share/omarchy'; do
  grep -Fxq "$line" "$unit" || fail "the unit has $line"
done
grep -Eq '^Environment=PATH=.*(/usr/share/omarchy/bin)' "$unit" ||
  fail "the unit puts /usr/share/omarchy/bin on PATH"
! grep -Fq NetworkManager "$unit" || fail "the unit does not wait for the network"
! grep -Fq encrypt-pending "$script" || fail "the script has no encrypt-pending path"
! grep -Fq reboot "$script" || fail "the script never reboots"
! grep -Eq '^(TTYPath|TTYReset|TTYVHangup|TTYVTDisallocate|StandardOutput=tty|StandardError=tty)' "$unit" ||
  fail "the unit acquires no terminal: systemd's TTY reset would switch the VT to text and drop the splash"
grep -Fq 'plymouth quit' "$script" && grep -Fq 'take_console' "$script" && grep -Fq 'release_console' "$script" ||
  fail "the script takes tty1 only for its failure screen, after dismissing the splash, and gives it back for the retry"
grep -Fq 'omarchy-mac-encrypt.failed' "$script" && grep -Fq 'last-encrypt-failure' "$script" ||
  fail "the script reports an encryption failure the initrd recorded, once"
echo 'ok - the unit logs to the journal and holds no terminal; the script owns tty1 only for its failure screen'

# The generic deferred-hardware service runs after first boot, which drains the
# queue once the keyring exists.
[[ $(grep -v '^#' "$hardware_dropin") == $'[Unit]\nAfter=omarchy-mac-first-boot.service' ]] ||
  fail "omarchy-provision-hardware.service waits for first boot"
grep -Fq '"$root/usr/bin/omarchy-provision-hardware"' "$script" ||
  fail "first boot runs omarchy-provision-hardware"
! grep -Fq 'install/hardware/apple/limine-boot.sh"' "$script" ||
  fail "first boot no longer sources the Limine activation leaf itself"
echo 'ok - first boot hands deferred hardware setup to omarchy-provision-hardware, which waits for it'

new_case arm
pending_mode=$(stat -c %a "$root/var/lib/omarchy/mac-first-boot/pending" 2>/dev/null ||
  stat -f %OLp "$root/var/lib/omarchy/mac-first-boot/pending")
[[ -f $root/var/lib/omarchy/mac-first-boot/pending && $pending_mode == 644 ]] ||
  fail "arm leaves the pending marker a builder needs"
rm "$root/var/lib/omarchy/mac-first-boot/pending"
run main || fail "a root without first boot pending is left alone"
[[ ! -s $case_dir/systemctl.log && ! -s $case_dir/deferred.log ]] ||
  fail "nothing runs without first boot pending"
echo 'ok - arm marks an image root pending, and without the marker nothing runs'

# ── install.conf consumed and deleted ──────────────────────────────────────
new_case consume
write_esp 'format=1' 'encrypt=0' 'lane=rc'
expect_handoff "consuming install.conf"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=0\nlane=rc' ]] ||
  fail "the consumed file matches the ESP copy"
grep -Fxq deferred "$case_dir/deferred.log" || fail "deferred steps run after consume"
echo 'ok - install.conf is consumed onto the root and deleted from the ESP'

# ── format ≠ 1 stays pending ───────────────────────────────────────────────
new_case bad-format
write_esp 'format=2' 'encrypt=1'
expect_stop "format is not 1" "install.conf is not format=1"
[[ ! -e $root/boot/efi/omarchy/install.conf ]] || fail "a bad-format ESP copy is still consumed"
[[ -f $root/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "the consumed copy is kept for retry"
echo 'ok - format≠1 is rejected with a clear message and stays pending'

# ── absent conf ⇒ encrypt=1 recorded, then provision ───────────────────────
new_case absent
expect_handoff "absent install.conf"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=1' ]] ||
  fail "an absent conf is recorded as encrypt=1"
echo 'ok - an absent install.conf is recorded as encrypt=1 and hands off'

# ── LUKS root and plain root both go straight to provisioning ──────────────
new_case luks-root
write_esp 'format=1' 'encrypt=1' 'lane=stable'
expect_handoff "a LUKS root"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=1\nlane=stable' ]] ||
  fail "a LUKS root keeps encrypt=1 for later tooling"

new_case plain-root
write_esp 'format=1' 'encrypt=0' 'lane=rc'
expect_handoff "a plain root"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=0\nlane=rc' ]] ||
  fail "a plain root keeps encrypt=0 for later tooling"
echo 'ok - a LUKS root and a plain root both go straight to provisioning, keeping encrypt=0|1'

# ── rerun after a failure resumes ──────────────────────────────────────────
new_case resume
write_esp 'format=1' 'encrypt=0' 'lane=edge'
touch "$case_dir/deferred-fails"
expect_stop "a deferred-steps failure" "the deferred hardware steps failed"
[[ ! -e $root/boot/efi/omarchy/install.conf ]] || fail "consume survives the failed attempt"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=0\nlane=edge' ]] ||
  fail "the consumed conf is kept for the retry"
[[ -f $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "pending remains after a failure"
: >"$case_dir/systemctl.log"
expect_handoff "a retry after deferred-steps failure"
[[ $(grep -c '^deferred$' "$case_dir/deferred.log") == 2 ]] || fail "deferred steps run again on retry"
echo 'ok - a failed attempt keeps pending, and the retry resumes from the consumed conf'

# ── pending removed only on success ────────────────────────────────────────
new_case pending-stays
write_esp 'format=1' 'encrypt=0'
rm "$root/usr/bin/omarchy-provision-owner"
expect_stop "a missing provision-owner" "does not ship owner provisioning"
[[ -f $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "pending remains when hand-off fails"
grep -Fxq 'pending=yes' "$case_dir/sync.log" || fail "every sync during a failed attempt still sees pending"
! grep -q '^systemctl start' "$case_dir/systemctl.log" || fail "nothing is started when hand-off fails"

new_case pending-gone
write_esp 'format=1' 'encrypt=1'
expect_handoff "a successful hand-off"
echo 'ok - pending is removed only when first boot succeeds'

# ── deferred-steps runner required ─────────────────────────────────────────
new_case no-deferred
write_esp 'format=1' 'encrypt=0'
rm -f "$root/usr/bin/omarchy-provision-hardware"
run attempt && fail "first boot must not hand off when the deferred-steps runner is absent"
[[ -e $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "pending stays armed when the runner is absent"
grep -Fq 'the deferred hardware steps failed' "$root/var/lib/omarchy/mac-first-boot/last-error" 2>/dev/null ||
  grep -Fq 'the deferred hardware steps failed' "$case_dir"/*.log 2>/dev/null ||
  fail "the missing runner is named"
echo 'ok - a runtime without omarchy-provision-hardware keeps first boot pending'

# A fresh-image contract allows exactly the one fixed activation leaf. The
# existing no-marker cases exercise reset's normal first-boot path.
new_case supported-deferred-contract
write_esp 'format=1' 'encrypt=0'
printf '%s\n' 'install/hardware/apple/limine-boot.sh' >"$root/var/lib/omarchy/mac-first-boot/deferred-steps"
expect_handoff "a supported deferred-steps contract"
for kind in other extra missing-newline symlink dangling-symlink directory; do
  new_case "unsupported-deferred-$kind"
  write_esp 'format=1' 'encrypt=0'
  steps=$root/var/lib/omarchy/mac-first-boot/deferred-steps
  case $kind in
    other) printf '%s\n' 'install/hardware/apple.sh' >"$steps" ;;
    extra) printf '%s\n' 'install/hardware/apple/limine-boot.sh' 'touch /tmp/unsafe' >"$steps" ;;
    missing-newline) printf '%s' 'install/hardware/apple/limine-boot.sh' >"$steps" ;;
    symlink) printf '%s\n' 'install/hardware/apple/limine-boot.sh' >"$case_dir/steps"; ln -s "$case_dir/steps" "$steps" ;;
    dangling-symlink) ln -s "$case_dir/missing" "$steps" ;;
    directory) mkdir "$steps" ;;
  esac
  expect_stop "an unsupported deferred-steps contract ($kind)" 'deferred-steps'
  [[ ! -s $case_dir/deferred.log ]] || fail "invalid deferred-steps must not execute the activation leaf"
done
echo 'ok - first boot accepts only the fixed fresh-image contract and permits marker-free reset'

# ── durable persist before ESP deletion ────────────────────────────────────
new_case persist-sync-fails
write_esp 'format=1' 'encrypt=0' 'lane=rc'
touch "$case_dir/sync-fails"
expect_stop "a failed file fsync" "could not persist"
[[ -f $root/boot/efi/omarchy/install.conf ]] || fail "a failed fsync leaves the ESP copy"
[[ ! -e $root/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "a failed fsync does not publish install.conf"
! grep -q '^systemctl start' "$case_dir/systemctl.log" || fail "nothing is started after a failed fsync"

new_case persist-dir-sync-fails
write_esp 'format=1' 'encrypt=0' 'lane=rc'
touch "$case_dir/sync-fail-dir"
expect_stop "a failed directory fsync" "could not persist"
[[ -f $root/boot/efi/omarchy/install.conf ]] || fail "a failed directory fsync leaves the ESP copy"
[[ -f $root/var/lib/omarchy/mac-first-boot/install.conf ]] || fail "the renamed copy exists before directory fsync"
rm -f "$case_dir/sync-fail-dir"
: >"$case_dir/systemctl.log"
: >"$case_dir/sync.log"
expect_handoff "retry after a failed directory fsync"
awk '
  $0 ~ /^sync / && $2 ~ /\/install\.conf$/ { wait="file" }
  file && !dir && $0 ~ /^sync / && $2 ~ /\/mac-first-boot$/ { wait="dir" }
  $0 == "esp=yes" {
    if (wait=="file") file=1
    if (wait=="dir") dir=1
    wait=""
  }
  $0 == "esp=no" {
    if (wait=="file" || wait=="dir") exit 2
    if (file && dir) gone=1
    wait=""
  }
  END { if (!(file && dir && gone)) exit 1 }
' "$case_dir/sync.log" || fail "retry fsyncs the existing record while the ESP copy is still there"
echo 'ok - fsync of the file and of its directory must succeed before the ESP copy is deleted'

new_case persist-order
write_esp 'format=1' 'encrypt=0' 'lane=rc'
expect_handoff "durable persist"
awk '
  $0 ~ /^sync / && $2 ~ /install\.conf\./ { wait="file" }
  file && !dir && $0 ~ /^sync / && $2 ~ /\/mac-first-boot$/ { wait="dir" }
  $0 == "esp=yes" {
    if (wait=="file") file=1
    if (wait=="dir") dir=1
    wait=""
  }
  $0 == "esp=no" {
    if (wait=="file" || wait=="dir") exit 2
    if (file && dir) gone=1
    wait=""
  }
  END { if (!(file && dir && gone)) exit 1 }
' "$case_dir/sync.log" || fail "file fsync, rename, directory fsync, then ESP deletion"
echo 'ok - the ESP copy is deleted only after file fsync, rename and directory fsync'

# ── rejected start leaves pending ──────────────────────────────────────────
new_case daemon-reload-fails
write_esp 'format=1' 'encrypt=0'
touch "$case_dir/daemon-reload-fails"
expect_stop "a failed daemon-reload" "could not reload systemd"
! grep -q '^systemctl start' "$case_dir/systemctl.log" || fail "starts are not queued when reload fails"

new_case rejected-start
write_esp 'format=1' 'encrypt=0'
printf '%s\n' omarchy-provision-owner.service >"$case_dir/start-fails"
expect_stop "a rejected provisioning start" "could not queue owner provisioning"
grep -Fxq 'systemctl daemon-reload' "$case_dir/systemctl.log" || fail "reload ran before the rejected start"
grep -Fq 'systemctl start --no-block omarchy-provision-owner.service' "$case_dir/systemctl.log" ||
  fail "the rejected start was attempted"
! grep -Fq display-manager "$case_dir/systemctl.log" || fail "the display manager is not queued after a rejected start"

new_case commit-sync-fails
write_esp 'format=1' 'encrypt=0'
touch "$case_dir/sync-fail-commit"
expect_stop "a failed commit sync" "could not persist the first-boot commit"
! grep -Fq 'systemctl start' "$case_dir/systemctl.log" ||
  fail "no unit is started when the commit sync fails"
: >"$case_dir/systemctl.log"
expect_handoff "retry after a failed commit sync"
echo 'ok - a failed commit sync re-arms pending and starts nothing; the retry hands off'

# ── retries prefer the persisted copy ──────────────────────────────────────
new_case prefer-persisted
printf '%s\n' 'format=1' 'encrypt=0' 'lane=edge' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
write_esp 'format=1' 'encrypt=1' 'lane=stable'
expect_handoff "ESP present with a persisted copy"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=0\nlane=edge' ]] ||
  fail "a remaining ESP copy must not replace the persisted install.conf"
echo 'ok - a retry keeps the persisted install.conf and still deletes the ESP copy'

# ── package keyring before deferred steps ──────────────────────────────────
new_case keyring
write_esp 'format=1' 'encrypt=0'
: >"$root/usr/share/pacman/keyrings/omarchy.gpg"
expect_handoff "keyring init"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/keyring") == "master=$keyring_master_fpr" ]] ||
  fail "the keyring record names this Mac's master key"
[[ $(head -n 1 "$case_dir/deferred.log") == keyring=yes ]] || fail "deferred steps run after the keyring exists"
[[ $(awk '/--init/{print "init"} /--populate /{print "populate"} /--add/{print "add"} /--lsign-key/{print "lsign"}' \
  "$case_dir/pacman-key.log") == $'init\npopulate' ]] ||
  fail "pacman-key initializes and populates the existing platform policy in order"
! grep -Eq -- '--(add|lsign-key)' "$case_dir/pacman-key.log" || fail "first boot imports no additional repository key"
grep -Eq -- '--populate archlinuxarm asahi-alarm omarchy$' "$case_dir/pacman-key.log" ||
  fail "the Omarchy release keyring is populated when omarchy-keyring ships it (omarchy-update-keyring requires it)"

new_case keyring-retry
write_esp 'format=1' 'encrypt=0' 'lane=edge'
touch "$case_dir/deferred-fails"
expect_stop "keyring before a deferred failure" "the deferred hardware steps failed"
: >"$case_dir/systemctl.log"
expect_handoff "retry after keyring init"
[[ $(grep -c -- '--init' "$case_dir/pacman-key.log") == 1 ]] || fail "a retry does not initialise the keyring again"
grep -Eq -- '--populate archlinuxarm asahi-alarm$' "$case_dir/pacman-key.log" ||
  fail "without omarchy.gpg the populate list stays archlinuxarm asahi-alarm"

new_case no-rearm-provisioning
write_esp 'format=1' 'encrypt=0'
rm -f "$root/var/lib/omarchy/provisioning/pending"
run attempt || fail "first boot still hands off when T1's provisioning marker is missing"
[[ ! -e $root/var/lib/omarchy/provisioning/pending ]] || fail "first boot does not re-arm provisioning/pending"
[[ ! -e $root/var/lib/omarchy/mac-first-boot/pending ]] || fail "pending is still cleared"
echo 'ok - provisioning/pending is left to T1'

# The installed unit supplies the runtime path before a user session exists.
[[ $(grep -c '^Environment=OMARCHY_PATH=/usr/share/omarchy$' "$unit") == 1 ]] || fail "the unit supplies one runtime path"
echo 'ok - the unit supplies the runtime environment without a login session'
