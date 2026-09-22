#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
root="$tmp/root"
calls="$tmp/calls"
slots="$tmp/slots"
prov="$tmp/provisioning"
boot_key="$tmp/boot/omarchy/luks-key"
encrypt_state="$tmp/boot/omarchy/encrypt.state"
grub_default="$tmp/default/grub"
device="$tmp/luks-device"
mkdir -p "$stub_bin" "$prov" "$tmp/boot/omarchy" "$tmp/default" "$root"
: >"$calls"
: >"$device"

printf 'throwaway-install-key\n' >"$prov/luks-key"
chmod 600 "$prov/luks-key"
printf 'throwaway-install-key\n' >"$boot_key"
chmod 600 "$boot_key"
# The files are binary-safe passphrases without a newline in production; keep
# the same bytes the stub will compare against.
printf 'throwaway-install-key' >"$prov/luks-key"
printf 'throwaway-install-key' >"$boot_key"
cat >"$encrypt_state" <<'EOF'
format=1
phase=encrypted
partition=PART-UUID-1
luks_uuid=abcd-ef
EOF

cat >"$grub_default" <<'EOF'
GRUB_CMDLINE_LINUX="rd.luks.name=abcd-ef=root rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4F4D-5801 root=/dev/mapper/root"
EOF

printf '0 throwaway-install-key\n' >"$slots"

cat >"$stub_bin/omarchy-hw-apple-silicon" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/update-grub" <<SH
#!/bin/bash
printf 'update-grub %s\n' "\$*" >>"$calls"
if [[ -f "$tmp/grub-fail" ]]; then
  rm -f "$tmp/grub-fail"
  exit 1
fi
exit 0
SH

# The re-key regenerates boot files through omarchy-mac-boot-update, which on
# a GRUB Mac is update-grub.
ln -sf "$ROOT/bin/omarchy-mac-boot-update" "$stub_bin/omarchy-mac-boot-update"
cat >"$stub_bin/omarchy-mac-limine-active" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin/omarchy-mac-limine-active"

cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
printf 'mkinitcpio %s\n' "\$*" >>"$calls"
exit 0
SH

cat >"$stub_bin/stty" <<'SH'
#!/bin/bash
echo "24 80"
SH

: >"$tmp/gum-stdin"
cat >"$stub_bin/gum" <<SH
#!/bin/bash
printf 'gum %s\n' "\$*" >>"$calls"
cat >/dev/null
exit 0
SH

cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
printf 'cryptsetup %s\n' "\$*" >>"$calls"
slots_file="$slots"
read_key() {
  local path=\$1
  [[ -n "\$path" && -e "\$path" ]] || return 1
  cat "\$path"
}
slot_for() {
  local material=\$1 line slot rest
  while read -r slot rest; do
    [[ \$rest == "\$material" ]] && { printf '%s' "\$slot"; return 0; }
  done <"\$slots_file"
  return 1
}
add_slot() {
  local material=\$1 next
  next=\$(awk '{s=\$1} END {print s+1}' "\$slots_file")
  printf '%s %s\n' "\$next" "\$material" >>"\$slots_file"
}
case "\$1" in
  open)
    keyfile=""
    verbose=0
    while ((\$#)); do
      case "\$1" in
        --verbose) verbose=1 ;;
        --key-file) keyfile=\$2; shift ;;
      esac
      shift
    done
    material=\$(read_key "\$keyfile") || exit 1
    slot=\$(slot_for "\$material") || exit 1
    (( verbose )) && echo "Key slot \$slot unlocked" >&2
    exit 0
    ;;
  luksAddKey)
    keyfile=""
    device=""
    newfile=""
    shift
    while ((\$#)); do
      case "\$1" in
        --key-file) keyfile=\$2; shift 2 ;;
        --*) shift ;;
        *)
          if [[ -z \$device ]]; then
            device=\$1
          else
            newfile=\$1
          fi
          shift
          ;;
      esac
    done
    material=\$(read_key "\$keyfile") || exit 1
    slot_for "\$material" >/dev/null || exit 1
    new=\$(read_key "\$newfile") || exit 1
    add_slot "\$new"
    exit 0
    ;;
  luksDump)
    awk '{ printf "  %s: luks2\\n", \$1 }' "\$slots_file"
    exit 0
    ;;
  luksUUID)
    echo abcd-ef
    exit 0
    ;;
  luksKillSlot)
    kill_slot=""
    while ((\$#)); do
      [[ \$1 =~ ^[0-9]+$ ]] && kill_slot=\$1
      shift
    done
    [[ -n \$kill_slot ]] || exit 1
    awk -v s="\$kill_slot" '\$1 != s { print }' "\$slots_file" >"\$slots_file.new"
    mv "\$slots_file.new" "\$slots_file"
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$stub_bin"/*

omarchy="$tmp/omarchy"
mkdir -p "$omarchy/install/provisioning"
printf 'OMARCHY\n' >"$omarchy/logo.txt"
: >"$omarchy/install/provisioning/setup-form.sh"

export PATH="$stub_bin:$PATH"
export OMARCHY_PATH="$omarchy"
export OMARCHY_PROVISIONING_DIR="$prov"
export OMARCHY_PROVISION_OWNER_LOG="$tmp/provision.log"
export OMARCHY_BOOT_LUKS_KEY="$boot_key"
export OMARCHY_ENCRYPT_STATE="$encrypt_state"
export OMARCHY_GRUB_DEFAULT="$grub_default"
export OMARCHY_LUKS_DEVICE="$device"
export OMARCHY_PROVISION_OWNER_SOURCE=1
export COLUMNS=80
: >"$OMARCHY_PROVISION_OWNER_LOG"

# shellcheck disable=SC1091
source "$ROOT/bin/omarchy-provision-owner"
export PATH="$stub_bin:$PATH"

password="owner-secret"
recovery_key=$(generate_recovery_passphrase)
[[ $recovery_key =~ ^([A-Z2-7]{4}-){11}[A-Z2-7]{4}$ ]] ||
  fail "recovery key is 12 base32 groups of 4" "$recovery_key"

touch "$prov/pending"
: >"$calls"
: >"$tmp/gum-stdin"
printf 'nope\n%s\n' "$RECOVERY_ACK_PHRASE" >"$tmp/gum-input"
cat >"$stub_bin/gum" <<SH
#!/bin/bash
printf 'gum %s\n' "\$*" >>"$calls"
if [[ "\$1" == "style" ]]; then
  cat >>"$tmp/gum-stdin"
fi
if [[ "\$1" == "input" ]]; then
  cat >/dev/null
  IFS= read -r line <"$tmp/gum-input" || exit 1
  tail -n +2 "$tmp/gum-input" >"$tmp/gum-input.new"
  mv "$tmp/gum-input.new" "$tmp/gum-input"
  printf '%s\n' "\$line"
fi
exit 0
SH
chmod +x "$stub_bin/gum"

show_recovery_key "$recovery_key" >"$tmp/show.out"
grep -aqF $'\e[3J' "$tmp/show.out" || fail "recovery display clearing uses CSI 3J" "$(od -An -tx1 "$tmp/show.out" | head)"

[[ -f $prov/luks-key ]] || fail "acknowledgement leaves the provisioning luks-key in place"
[[ -f $boot_key ]] || fail "acknowledgement leaves the Boot-partition luks-key in place"
[[ -f $prov/pending ]] || fail "acknowledgement leaves provisioning/pending in place"
grep -Fxq 'phase=encrypted' "$encrypt_state" ||
  fail "acknowledgement does not finalise encrypt.state" "$(cat "$encrypt_state")"
! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "acknowledgement happens before any keyslot is added"
! grep -F "$recovery_key" "$calls" >/dev/null ||
  fail "the recovery key is not passed as a gum argument" "$(cat "$calls")"
[[ "$(<"$tmp/gum-stdin")" == "$recovery_key" ]] ||
  fail "the recovery key is fed to gum on stdin" "$(cat "$tmp/gum-stdin")"
grep -F "$RECOVERY_ACK_PHRASE" "$calls" >/dev/null ||
  fail "the owner types the acknowledgement phrase"
! grep -F 'Show it again' "$calls" >/dev/null || fail "there is no re-show path"
! grep -F 'gum confirm' "$calls" >/dev/null || fail "acknowledgement is typed, not a confirm"
(( $(grep -c '^gum input' "$calls") == 2 )) ||
  fail "a wrong phrase is rejected until the owner types the acknowledgement" "$(cat "$calls")"
! grep -Fq "$recovery_key" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "the recovery key is never written to the provision log after display"

: >"$calls"
touch "$tmp/grub-fail"
if rekey_luks; then
  fail "re-key fails closed when update-grub fails"
fi
[[ ! -e $prov/luks-key ]] || fail "a failed GRUB step after phase=rekeyed has already shredded the staged key"
[[ ! -e $boot_key ]] || fail "a failed GRUB step after phase=rekeyed has already shredded the Boot-partition key"
grep -Fxq 'phase=rekeyed' "$encrypt_state" ||
  fail "a failed GRUB step leaves encrypt.state phase=rekeyed" "$(cat "$encrypt_state")"
(( $(wc -l <"$slots") == 2 )) || fail "a failed GRUB step has already retired the throwaway slot" "$(cat "$slots")"
[[ -f $REKEY_STATE ]] || fail "slot numbers remain recorded for retry"
grep -q '^owner_slot=' "$REKEY_STATE" || fail "owner slot is recorded" "$(cat "$REKEY_STATE")"
grep -q '^recovery_slot=' "$REKEY_STATE" || fail "recovery slot is recorded" "$(cat "$REKEY_STATE")"
grep -Fxq 'recovery_shown=1' "$REKEY_STATE" || fail "recovery_shown=1 is recorded after acknowledgement" "$(cat "$REKEY_STATE")"
[[ -f $prov/pending ]] || fail "provisioning state is not removed before phase=finished"
(( $(grep -cF 'cryptsetup luksAddKey' "$calls") == 2 )) ||
  fail "first attempt adds the owner key and the recovery keyslot" "$(cat "$calls")"
grep -F 'cryptsetup luksKillSlot' "$calls" >/dev/null || fail "the staged-key slot is killed after slots are recorded"

recorded_owner=$(awk -F= '$1 == "owner_slot" { print $2 }' "$REKEY_STATE")
recorded_recovery=$(awk -F= '$1 == "recovery_slot" { print $2 }' "$REKEY_STATE")

# A new --attempt process only has a freshly generated recovery key in memory.
# The retry must reuse the recorded slot rather than adding another.
: >"$calls"
recovery_key=$(generate_recovery_passphrase)
RECOVERY_ACKED=0
rekey_luks

! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "retry reuses recorded owner and recovery slots without the original key" "$(cat "$calls")"
grep -Fx 'update-grub ' "$calls" >/dev/null || fail "retry regenerates grub.cfg with update-grub"
grep -F 'mkinitcpio -P' "$calls" >/dev/null || fail "retry rebuilds the initramfs" "$(cat "$calls")"
(( $(wc -l <"$slots") == 2 )) || fail "retry does not accumulate LUKS slots" "$(cat "$slots")"

[[ ! -e $prov/luks-key ]] || fail "provisioning luks-key is shredded"
[[ ! -e $boot_key ]] || fail "Boot-partition luks-key is shredded"
[[ ! -e $REKEY_STATE ]] || fail "re-key state is removed after success"
! grep -q 'rd.luks.key=' "$grub_default" ||
  fail "rd.luks.key= is dropped from GRUB_CMDLINE_LINUX" "$(cat "$grub_default")"
grep -q 'rd.luks.name=' "$grub_default" || fail "rd.luks.name= is kept"
grep -q 'root=/dev/mapper/root' "$grub_default" || fail "root=/dev/mapper/root is kept"

grep -Fxq 'format=1' "$encrypt_state" || fail "encrypt.state keeps format=1" "$(cat "$encrypt_state")"
grep -Fxq 'phase=finished' "$encrypt_state" || fail "encrypt.state is phase=finished" "$(cat "$encrypt_state")"
grep -Fxq 'partition=PART-UUID-1' "$encrypt_state" || fail "encrypt.state keeps partition=" "$(cat "$encrypt_state")"
grep -Fxq 'luks_uuid=abcd-ef' "$encrypt_state" || fail "encrypt.state keeps luks_uuid=" "$(cat "$encrypt_state")"
grep -Fxq "owner_slot=$recorded_owner" "$encrypt_state" ||
  fail "encrypt.state records the owner slot" "$(cat "$encrypt_state")"
grep -Fxq "recovery_slot=$recorded_recovery" "$encrypt_state" ||
  fail "encrypt.state records the recovery slot" "$(cat "$encrypt_state")"

! grep -Fq "$recovery_key" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "the recovery key is never written to the provision log"
! grep -Fq "$recovery_key" "$grub_default" || fail "the recovery key is not stored in GRUB config"
[[ ! -e $prov/recovery-key && ! -e $tmp/boot/omarchy/recovery-key ]] ||
  fail "the recovery key is never written to a keyfile"

! grep -Fq 'limine-update' "$calls" || fail "Apple re-key does not call limine-update"
pass "Apple LUKS re-key adds a recovery keyslot, shreds both keyfiles, and drops rd.luks.key="

# Recorded recovery slot missing: fail rather than add another.
printf 'format=1\nphase=encrypted\npartition=PART-UUID-1\nluks_uuid=abcd-ef\n' >"$encrypt_state"
printf '0 throwaway-install-key\n1 owner-secret\n' >"$slots"
printf 'throwaway-install-key' >"$prov/luks-key"
printf 'throwaway-install-key' >"$boot_key"
printf 'owner_slot=1\nrecovery_slot=9\nrecovery_shown=1\n' >"$REKEY_STATE"
touch "$prov/pending"
: >"$calls"
recovery_key="AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH-IIII-JJJJ-KKKK-LLLL"
RECOVERY_ACKED=0
if rekey_luks; then
  fail "a missing recorded recovery slot fails closed"
fi
! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "a missing recorded recovery slot does not add another" "$(cat "$calls")"
[[ -f $prov/pending ]] || fail "a missing recorded slot keeps provisioning state"
pass "a missing recorded recovery slot fails rather than adding another"

# Crash after shred, before phase=finished: resume without the throwaway keyfile.
printf 'format=1\nphase=rekeyed\npartition=PART-UUID-1\nluks_uuid=abcd-ef\nowner_slot=1\nrecovery_slot=2\n' >"$encrypt_state"
printf '1 owner-secret\n2 recovery-material\n' >"$slots"
printf 'owner_slot=1\nrecovery_slot=2\nrecovery_shown=1\n' >"$REKEY_STATE"
rm -f "$prov/luks-key" "$boot_key"
cat >"$grub_default" <<'EOF'
GRUB_CMDLINE_LINUX="rd.luks.name=abcd-ef=root rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4F4D-5801 root=/dev/mapper/root"
EOF
touch "$prov/pending"
: >"$calls"
recovery_key=""
RECOVERY_ACKED=0
password="owner-secret"
rekey_luks
! grep -F 'cryptsetup luksAddKey' "$calls" >/dev/null ||
  fail "resume from phase=rekeyed does not add slots" "$(cat "$calls")"
grep -Fxq 'phase=finished' "$encrypt_state" || fail "resume from phase=rekeyed reaches phase=finished"
[[ -f $prov/pending ]] || fail "resume does not drop provisioning state from rekey_luks"
! grep -q 'rd.luks.key=' "$grub_default" || fail "resume drops rd.luks.key="
pass "finalisation resumes from phase=rekeyed without the throwaway keyfile"

# xtrace must not persist the owner or recovery secret into the provision log.
printf 'format=1\nphase=encrypted\npartition=PART-UUID-1\nluks_uuid=abcd-ef\n' >"$encrypt_state"
printf '0 throwaway-install-key\n' >"$slots"
printf 'throwaway-install-key' >"$prov/luks-key"
printf 'throwaway-install-key' >"$boot_key"
rm -f "$REKEY_STATE"
cat >"$grub_default" <<'EOF'
GRUB_CMDLINE_LINUX="rd.luks.name=abcd-ef=root rd.luks.key=abcd-ef=/omarchy/luks-key:UUID=4F4D-5801 root=/dev/mapper/root"
EOF
recovery_key="ZZZZ-YYYY-XXXX-WWWW-VVVV-UUUU-TTTT-SSSS-RRRR-QQQQ-PPPP-OOOO"
password="owner-secret-xtrace"
printf '0 throwaway-install-key\n' >"$slots"
# The stub compares slot material exactly; owner-secret-xtrace is new.
: >"$OMARCHY_PROVISION_OWNER_LOG"
: >"$calls"
RECOVERY_ACKED=1
set -x
rekey_luks >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1
set +x
! grep -Fq "$recovery_key" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "xtrace does not persist the recovery key in the provision log" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
! grep -Fq "$password" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "xtrace does not persist the owner password in the provision log" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
pass "secret-bearing re-key commands are not captured under xtrace"

# Slot reuse must authenticate a retry's password before changing accounts.
printf '1 owner-pass\n2 recovery-pass\n' >"$slots"
printf 'owner_slot=1\nrecovery_slot=2\nrecovery_shown=1\n' >"$prov/luks-rekey.state"
if luks_ensure_slot different-password "$device" owner_slot; then
  fail "a retry cannot reuse an owner slot with a different password"
fi
pass "owner slot reuse authenticates the retry password"

# Losing the staged key and device during an incomplete transaction is not
# evidence that encryption was declined.
printf 'format=1\nphase=rekeyed\nowner_slot=1\nrecovery_slot=2\n' >"$encrypt_state"
rm -f "$prov/luks-key" "$device"
if rekey_luks; then fail "an incomplete re-key rejects an unavailable device"; fi
pass "an incomplete re-key cannot silently skip a missing device"
