#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The owner provisioning entrypoints omarchy-lifecycle-dispatch runs, staged by
# install into a fixture root and run as the files they are. Boot tools are
# stubs: mkinitcpio writes the initramfs listing lsinitcpio reads back, and
# omarchy-mac-boot-update regenerates the loader's command line from GRUB's
# defaults.
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
root=$test_tmp/root
stub_bin=$test_tmp/bin
calls=$test_tmp/calls
mkdir -p "$stub_bin"
bash "$ROOT/install" "$root"
entry=$root/usr/lib/omarchy/mac-boot

firmware_listing='./usr/lib/systemd/system-generators/systemd-cryptsetup-generator
./usr/lib/systemd/system/omarchy-vendorfw-initrd.service
./usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf'
cat >"$stub_bin/omarchy-hw-platform" <<'SH'
#!/bin/bash
echo "${TEST_PLATFORM:-apple-silicon}"
SH
cat >"$stub_bin/omarchy-mac-kernel" <<'SH'
#!/bin/bash
echo linux-aurora
SH
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
[[ $1 == -l && -f $2 ]] && cat "$2"
SH
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
echo "mkinitcpio \$*" >>"$calls"
[[ ! -e $test_tmp/fail-mkinitcpio ]] || exit 1
if [[ -e $test_tmp/build-without-firmware ]]; then
  echo ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator >"$root/boot/initramfs-linux-aurora.img"
else
  printf '%s\n' "$firmware_listing" >"$root/boot/initramfs-linux-aurora.img"
fi
SH
cat >"$stub_bin/omarchy-mac-boot-update" <<SH
#!/bin/bash
cmdline=\$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"/\1/p' "$root/etc/default/grub")
echo "omarchy-mac-boot-update \$cmdline" >>"$calls"
[[ ! -e $test_tmp/fail-boot-update ]] || exit 1
if [[ -e $root/var/lib/omarchy/limine.enabled ]]; then
  printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="%s"\n' "\$cmdline" >"$root/etc/default/limine"
else
  printf 'linux /vmlinuz-linux-aurora %s\n' "\$cmdline" >"$root/boot/grub/grub.cfg"
fi
SH
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
# The Boot partition at /boot, as an image mounts it.
if [[ " $* " == *" --mountpoint "* && " $* " == *" UUID "* && ${*: -1} == */boot ]]; then
  echo "${TEST_BOOT_UUID-4f4d5801-424f-4f54-8000-000000000001}"
  exit 0
fi
exec /usr/bin/findmnt "$@"
SH
cat >"$stub_bin/omarchy-mac-esp" <<'SH'
#!/bin/bash
[[ -n ${TEST_ESP-/boot/efi} ]] || exit 1
echo "${TEST_ESP-/boot/efi}"
SH
# The root's LUKS header: keyslots, then tokens, which luksDump lists alike.
cat >"$stub_bin/cryptsetup" <<'SH'
#!/bin/bash
[[ $1 == luksDump && -e $2 ]] || exit 1
[[ -z ${TEST_DUMP_FAIL:-} ]] || exit 1
printf 'LUKS header information\nVersion:       \t2\n\nKeyslots:\n'
for slot in ${TEST_KEYSLOTS-2 3}; do printf '  %s: luks2\n\tKey:        512 bits\n' "$slot"; done
printf 'Tokens:\n'
for token in ${TEST_TOKENS-}; do printf '  %s: luks2-keyring\n\tKeyslot:    3\n' "$token"; done
printf 'Digests:\n  0: pbkdf2\n'
SH
chmod +x "$stub_bin"/*

luks_uuid=1b2c3d4e-0000-4000-8000-000000000001
key_line="rd.luks.key=$luks_uuid=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001"
grub_line="GRUB_CMDLINE_LINUX=\"quiet rd.luks.name=$luks_uuid=root $key_line\""

# An image's first boot after the initramfs encrypted the root: phase
# configured, the staged key on the boot partition and named on the command
# line, and a re-key journal whose owner acknowledged a recovery key.
fixture() {
  rm -rf "$root/boot" "$root/etc" "$root/var" "$root/dev"
  mkdir -p "$root/boot/omarchy" "$root/boot/grub" "$root/etc/default" "$root/dev/disk/by-uuid" \
    "$root/var/lib/omarchy/provisioning" "$root/var/lib/omarchy/mac-first-boot"
  head -c 64 /dev/urandom >"$root/boot/omarchy/luks-key"
  chmod 600 "$root/boot/omarchy/luks-key"
  printf 'format=1\nphase=configured\npartition=5f2b0c3e-0003\nluks_uuid=%s\n' "$luks_uuid" >"$root/boot/omarchy/encrypt.state"
  printf '%s\nGRUB_CMDLINE_LINUX_DEFAULT="splash"\n' "$grub_line" >"$root/etc/default/grub"
  printf 'linux /vmlinuz-linux-aurora quiet rd.luks.name=%s=root %s\n' "$luks_uuid" "$key_line" >"$root/boot/grub/grub.cfg"
  printf 'root UUID=%s none luks\n' "$luks_uuid" >"$root/etc/crypttab"
  : >"$root/dev/disk/by-uuid/$luks_uuid"
  printf 'format=1\nencrypt=1\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
  printf 'staged_slot=0\nowner_slot=2\nrecovery_slot=3\nrecovery_shown=1\nphase=owner\n' >"$root/var/lib/omarchy/provisioning/luks-rekey.state"
  printf '%s\n' "$firmware_listing" >"$root/boot/initramfs-linux-aurora.img"
  rm -f "$test_tmp"/fail-* "$test_tmp/build-without-firmware"
  : >"$calls"
}

limine_fixture() {
  fixture
  : >"$root/var/lib/omarchy/limine.enabled"
  printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID=x rw quiet rd.luks.name=%s=root %s"\n' "$luks_uuid" "$key_line" \
    >"$root/etc/default/limine"
}

run() {
  OMARCHY_MAC_BOOT_ROOT=$root PATH="$stub_bin:$PATH" "$entry/$1" "${@:2}" 2>"$test_tmp/err"
}

snapshot() {
  (cd "$root" && find boot etc var dev -type f -exec sha256sum {} + | sort)
}

error_says() {
  grep -Fq "$1" "$test_tmp/err" || fail "the error says: $1" "$(cat "$test_tmp/err")"
}

for name in provision-prepare provision-commit provision-verify luks-slots; do
  [[ -x $entry/$name && $(head -n 1 "$entry/$name") == "#!/bin/bash -p" ]] ||
    fail "$name is an executable entrypoint that ignores BASH_ENV"
done

# ── provision-prepare ──────────────────────────────────────────────────────
fixture
before=$(snapshot)
run provision-prepare || fail "an encrypted image root is ready for owner setup" "$(cat "$test_tmp/err")"
[[ $(snapshot) == "$before" && ! -s $calls ]] || fail "provision-prepare changes nothing"
pass "provision-prepare accepts an encrypted image root and changes nothing"

for platform in generic-aarch64 qualcomm generic; do
  fixture
  before=$(snapshot)
  for name in provision-prepare provision-commit provision-verify luks-slots; do
    if TEST_PLATFORM=$platform run "$name" owner=2; then fail "$name refuses to run on $platform"; fi
    error_says "runs only on Apple Silicon"
  done
  [[ $(snapshot) == "$before" && ! -s $calls ]] || fail "nothing changes on $platform"
done
pass "every entrypoint re-checks the platform and refuses off Apple Silicon"

# install.conf handoff: what the first boot recorded decides whether a plain
# root may be set up. It records encrypt=1 when the installer left no
# install.conf, so an absent one means the disk must be encrypted.
fixture
rm "$root/boot/omarchy/encrypt.state"
if run provision-prepare; then fail "a plain root is refused when install.conf asked for encryption"; fi
error_says "set up to encrypt its disk, but the disk was not encrypted"
[[ $(wc -l <"$test_tmp/err") == 1 ]] || fail "the owner sees one line" "$(cat "$test_tmp/err")"
printf 'format=1\nencrypt=1\nlane=stable\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
if run provision-prepare; then fail "encrypt=1 with a lane is still encryption"; fi
printf 'format=1\nencrypt=0\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
run provision-prepare || fail "encrypt=0 lets a plain root be set up" "$(cat "$test_tmp/err")"
rm "$root/var/lib/omarchy/mac-first-boot/install.conf"
run provision-prepare || fail "a Mac that did not start from an image has nothing to hand off" "$(cat "$test_tmp/err")"
printf 'format=1\nphase=declined\npartition=unknown\nluks_uuid=\n' >"$root/boot/omarchy/encrypt.state"
printf 'format=1\nencrypt=1\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
run provision-prepare || fail "an initramfs that recorded the decline wins" "$(cat "$test_tmp/err")"
pass "provision-prepare holds the install.conf handoff: absent means encrypt, encrypt=0 allows a plain root"

# The first boot records an absent install.conf as encrypt=1: the whole chain.
fixture
rm "$root/var/lib/omarchy/mac-first-boot/install.conf"
mkdir -p "$root/boot/efi/omarchy"
: >"$root/var/lib/omarchy/mac-first-boot/pending"
printf 'install/hardware/apple/limine-boot.sh\n' >"$root/var/lib/omarchy/mac-first-boot/deferred-steps"
(
  OMARCHY_MAC_FIRST_BOOT_ROOT=$root
  source "$root/usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot"
  consume_install_conf
) || fail "first boot consumes a missing install.conf"
[[ $(<"$root/var/lib/omarchy/mac-first-boot/install.conf") == $'format=1\nencrypt=1' ]] ||
  fail "first boot records a missing install.conf as encrypt=1"
rm -f "$root/var/lib/omarchy/mac-first-boot/pending" "$root/var/lib/omarchy/mac-first-boot/deferred-steps"
run provision-prepare || fail "the encrypted root an absent install.conf asked for is ready" "$(cat "$test_tmp/err")"
rm "$root/boot/omarchy/encrypt.state"
if run provision-prepare; then fail "a plain root is refused after an absent install.conf"; fi
pass "an absent install.conf is recorded as encrypt=1 and holds owner setup to an encrypted root"

for phase in plaintext shrunk reencrypting encrypted; do
  fixture
  sed -i "s/^phase=.*/phase=$phase/" "$root/boot/omarchy/encrypt.state"
  if run provision-prepare; then fail "phase=$phase is not ready for owner setup"; fi
  error_says "did not finish (encrypt.state phase=$phase)"
done
pass "provision-prepare refuses a conversion the initramfs has not finished"

fixture
rm "$root/dev/disk/by-uuid/$luks_uuid"
if run provision-prepare; then fail "a missing LUKS device is refused"; fi
error_says "Could not find the encrypted disk"
fixture
sed -i "s/^luks_uuid=.*/luks_uuid=someone-else/" "$root/boot/omarchy/encrypt.state"
if run provision-prepare; then fail "crypttab naming another LUKS volume than encrypt.state is refused"; fi
pass "provision-prepare finds the LUKS device crypttab names"

# Firmware ordering: the next boot asks for the password, so the initramfs
# must load the vendor firmware (the M2 keyboard) before the prompt.
fixture
echo ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator >"$root/boot/initramfs-linux-aurora.img"
if run provision-prepare; then fail "an initramfs without the vendor firmware ordering is refused"; fi
error_says "before the keyboard firmware loads"
fixture
rm "$root/boot/initramfs-linux-aurora.img"
if run provision-prepare; then fail "an unreadable initramfs is refused"; fi
pass "provision-prepare requires the vendor firmware before the disk password prompt"

# ESP selection: the device tree's ESP, and on a Limine Mac the one Limine writes to.
fixture
if TEST_ESP="" run provision-prepare; then fail "a Mac whose system ESP is not mounted is refused"; fi
error_says "EFI partition this Mac boots from"
limine_fixture
run provision-prepare || fail "a Limine Mac writing to the system ESP is ready" "$(cat "$test_tmp/err")"
if TEST_ESP=/boot run provision-prepare; then fail "Limine writing to another ESP than the device tree's is refused"; fi
pass "provision-prepare requires the boot files to go to the ESP the Mac boots from"

# Without the Boot partition /boot is a directory on the root: nothing there
# is the key, encrypt.state or the initramfs the Mac boots.
fixture
before=$(snapshot)
for name in provision-prepare provision-commit provision-verify luks-slots; do
  if TEST_BOOT_UUID="" run "$name" owner=2; then fail "$name refuses while the Boot partition is not mounted"; fi
  error_says "Boot partition is not mounted"
done
[[ $(snapshot) == "$before" && ! -s $calls ]] || fail "nothing changes without the Boot partition"
rm "$root/var/lib/omarchy/mac-first-boot/install.conf" "$root/boot/omarchy/encrypt.state"
TEST_BOOT_UUID="" run provision-prepare || fail "a Mac that did not start from an image has no Boot partition to require"
pass "an image's entrypoints refuse to work without its Boot partition at /boot"

# ── provision-commit and provision-verify ─────────────────────────────────
fixture
if run provision-verify; then fail "the staged unlock remains before commit"; fi
before=$(snapshot)
if run provision-verify; then fail "verify keeps failing"; fi
[[ $(snapshot) == "$before" && ! -s $calls ]] || fail "provision-verify changes nothing"
run provision-commit || fail "commit succeeds" "$(cat "$test_tmp/err")"
[[ ! -e $root/boot/omarchy/luks-key ]] || fail "the boot-partition key is removed"
grep -Fxq "GRUB_CMDLINE_LINUX=\"quiet rd.luks.name=$luks_uuid=root\"" "$root/etc/default/grub" ||
  fail "only rd.luks.key= leaves GRUB's defaults" "$(cat "$root/etc/default/grub")"
grep -Fxq 'GRUB_CMDLINE_LINUX_DEFAULT="splash"' "$root/etc/default/grub" || fail "the rest of GRUB's defaults stays"
[[ $(cat "$calls") == $'mkinitcpio -P\n'"omarchy-mac-boot-update quiet rd.luks.name=$luks_uuid=root" ]] ||
  fail "the initramfs, then the boot files are rebuilt from the new command line" "$(cat "$calls")"
[[ $(cat "$root/boot/omarchy/encrypt.state") == "format=1
phase=finished
partition=5f2b0c3e-0003
luks_uuid=$luks_uuid
owner_slot=2
recovery_slot=3" ]] || fail "encrypt.state is finished with the journal's slots" "$(cat "$root/boot/omarchy/encrypt.state")"
run provision-verify || fail "nothing of the staged unlock remains after commit" "$(cat "$test_tmp/err")"
pass "provision-commit takes the staged key out of a GRUB Mac's boot chain and records the slots"

before=$(snapshot)
: >"$calls"
run provision-commit || fail "a repeated commit succeeds" "$(cat "$test_tmp/err")"
[[ $(snapshot) == "$before" ]] || fail "a repeated commit changes nothing but the rebuild"
run provision-verify || fail "verify still passes after a repeated commit"
pass "provision-commit is idempotent"

limine_fixture
run provision-commit || fail "commit succeeds on a Limine Mac" "$(cat "$test_tmp/err")"
! grep -q 'rd.luks.key=' "$root/etc/default/limine" || fail "the Limine command line drops rd.luks.key="
run provision-verify || fail "a Limine Mac verifies after commit" "$(cat "$test_tmp/err")"
pass "provision-commit rebuilds a Limine Mac's command line without the staged key"

fixture
sed -i '/^recovery_shown=/d' "$root/var/lib/omarchy/provisioning/luks-rekey.state"
run provision-commit || fail "commit succeeds without an acknowledged recovery key"
! grep -q '^recovery_slot=' "$root/boot/omarchy/encrypt.state" || fail "an unacknowledged recovery slot is not recorded"
grep -Fxq 'owner_slot=2' "$root/boot/omarchy/encrypt.state" || fail "the owner slot is recorded"
printf 'recovery_slot=7\n' >>"$root/boot/omarchy/encrypt.state"
sed -i 's/^phase=.*/phase=configured/' "$root/boot/omarchy/encrypt.state"
run provision-commit || fail "commit succeeds over a stale recovery slot"
! grep -q '^recovery_slot=' "$root/boot/omarchy/encrypt.state" || fail "a stale recovery slot is not carried into finished"
pass "only a recovery slot the owner acknowledged is recorded"

# A failed rebuild keeps the unattended unlock for the retry: the key stays on
# the boot partition, rd.luks.key= comes back and the boot files are rebuilt with it.
for failure in fail-mkinitcpio fail-boot-update build-without-firmware; do
  fixture
  grub_before=$(cat "$root/etc/default/grub")
  key_before=$(sha256sum <"$root/boot/omarchy/luks-key")
  touch "$test_tmp/$failure"
  if run provision-commit; then fail "commit fails when $failure"; fi
  [[ $(sha256sum <"$root/boot/omarchy/luks-key") == "$key_before" ]] || fail "$failure: the boot-partition key stays"
  [[ $(cat "$root/etc/default/grub") == "$grub_before" ]] || fail "$failure: rd.luks.key= is restored" "$(cat "$root/etc/default/grub")"
  grep -Fxq 'phase=configured' "$root/boot/omarchy/encrypt.state" || fail "$failure: encrypt.state stays configured"
  [[ $(tail -n 1 "$calls") == "omarchy-mac-boot-update quiet rd.luks.name=$luks_uuid=root $key_line" ]] ||
    fail "$failure: the boot files are rebuilt with the restored command line" "$(cat "$calls")"
  if run provision-verify; then fail "$failure: the staged unlock remains"; fi
  rm -f "$test_tmp/$failure"
  run provision-commit || fail "$failure: the retry commits" "$(cat "$test_tmp/err")"
  run provision-verify || fail "$failure: the retry leaves nothing behind"
done
pass "a failed rebuild, or one without the firmware ordering, keeps the unattended unlock for the retry"

# An attempt killed after it rewrote GRUB's defaults, then a retry whose
# rebuild fails: the key is still on the boot partition, so the command line
# names it again.
fixture
sed -i "s| $key_line||" "$root/etc/default/grub"
touch "$test_tmp/fail-mkinitcpio"
if run provision-commit; then fail "the retry's failed rebuild fails commit"; fi
grep -Fxq "$grub_line" "$root/etc/default/grub" || fail "rd.luks.key= is put back for the key that remains" "$(cat "$root/etc/default/grub")"
[[ -f $root/boot/omarchy/luks-key ]] || fail "the key stays for the next boot"
pass "a failed retry names the remaining boot-partition key again, whichever attempt dropped it"

# Interrupted after the rebuild, before the key went: the rerun finishes.
fixture
sed -i "s| $key_line||" "$root/etc/default/grub"
run provision-commit || fail "commit finishes after an interruption past the rebuild" "$(cat "$test_tmp/err")"
[[ ! -e $root/boot/omarchy/luks-key ]] && grep -Fxq 'phase=finished' "$root/boot/omarchy/encrypt.state" ||
  fail "the rerun removes the key and finishes"
fixture
rm "$root/boot/omarchy/luks-key"
sed -i "s| $key_line||" "$root/etc/default/grub"
run provision-commit || fail "commit finishes after an interruption past the key removal"
grep -Fxq 'phase=finished' "$root/boot/omarchy/encrypt.state" || fail "the rerun records finished"
pass "provision-commit resumes wherever an interruption stopped it"

for phase in plaintext shrunk reencrypting encrypted unreadable; do
  fixture
  if [[ $phase == unreadable ]]; then
    sed -i '/^phase=/d' "$root/boot/omarchy/encrypt.state"
  else
    sed -i "s/^phase=.*/phase=$phase/" "$root/boot/omarchy/encrypt.state"
  fi
  before=$(snapshot)
  if run provision-commit; then fail "commit refuses phase=$phase"; fi
  [[ $(snapshot) == "$before" && ! -s $calls ]] || fail "phase=$phase: the key the conversion resumes with is untouched"
done
pass "provision-commit never touches the key an unfinished conversion needs"

# provision-verify: each leftover alone counts as the staged unlock.
verify_fixture() {
  fixture
  rm "$root/boot/omarchy/luks-key"
  sed -i "s| $key_line||" "$root/etc/default/grub" "$root/boot/grub/grub.cfg"
  sed -i 's/^phase=.*/phase=finished/' "$root/boot/omarchy/encrypt.state"
  run provision-verify || fail "the verify fixture is clean" "$(cat "$test_tmp/err")"
}
verify_fixture
: >"$root/boot/omarchy/luks-key"
if run provision-verify; then fail "a key on the boot partition remains"; fi
verify_fixture
printf 'GRUB_CMDLINE_LINUX="%s"\n' "$key_line" >"$root/etc/default/grub"
if run provision-verify; then fail "rd.luks.key= in GRUB's defaults remains"; fi
verify_fixture
printf 'linux /vmlinuz %s\n' "$key_line" >"$root/boot/grub/grub.cfg"
if run provision-verify; then fail "rd.luks.key= in a GRUB Mac's grub.cfg remains"; fi
: >"$root/var/lib/omarchy/limine.enabled"
printf 'ESP_PATH="/boot/efi"\nKERNEL_CMDLINE[default]="root=UUID=x rw"\n' >"$root/etc/default/limine"
run provision-verify || fail "a Limine Mac does not boot the GRUB image it keeps for rollback"
printf 'KERNEL_CMDLINE[default]="root=UUID=x %s"\n' "$key_line" >"$root/etc/default/limine"
if run provision-verify; then fail "rd.luks.key= in the Limine command line remains"; fi
for phase in configured rekeyed encrypted; do
  verify_fixture
  sed -i "s/^phase=.*/phase=$phase/" "$root/boot/omarchy/encrypt.state"
  if run provision-verify; then fail "encrypt.state phase=$phase is not finished"; fi
done
verify_fixture
sed -i 's/^phase=.*/phase=declined/' "$root/boot/omarchy/encrypt.state"
run provision-verify || fail "a declined Mac has no staged unlock"
rm "$root/boot/omarchy/encrypt.state"
run provision-verify || fail "a Mac without encrypt.state has no staged unlock"
pass "provision-verify finds every boot-time copy of the staged unlock"

# ── luks-slots ─────────────────────────────────────────────────────────────
# A finished Mac: provision-commit recorded owner 2 and recovery 3.
slots_fixture() {
  fixture
  run provision-commit || fail "the luks-slots fixture commits" "$(cat "$test_tmp/err")"
  : >"$calls"
  unset TEST_KEYSLOTS TEST_TOKENS TEST_DUMP_FAIL
}

state_is() {
  [[ $(cat "$root/boot/omarchy/encrypt.state") == "format=1
phase=finished
partition=5f2b0c3e-0003
luks_uuid=$luks_uuid
$1" ]] || fail "$2" "$(cat "$root/boot/omarchy/encrypt.state")"
}

# The password change moved the owner's key from slot 2 to slot 0.
slots_fixture
before=$( (cd "$root" && find boot etc var dev -type f ! -name encrypt.state -exec sha256sum {} + | sort) )
TEST_KEYSLOTS="0 3" run luks-slots owner=0 || fail "luks-slots records the owner's new slot" "$(cat "$test_tmp/err")"
state_is $'owner_slot=0\nrecovery_slot=3' "the owner's new slot is recorded beside the recovery slot"
[[ $( (cd "$root" && find boot etc var dev -type f ! -name encrypt.state -exec sha256sum {} + | sort) ) == "$before" && ! -s $calls ]] ||
  fail "luks-slots changes nothing but encrypt.state"
TEST_KEYSLOTS="0 3" run luks-slots owner=0 || fail "luks-slots is idempotent"
state_is $'owner_slot=0\nrecovery_slot=3' "a repeated record changes nothing"
TEST_KEYSLOTS="4 5" run luks-slots owner=4 recovery=5 || fail "luks-slots records both slots" "$(cat "$test_tmp/err")"
state_is $'owner_slot=4\nrecovery_slot=5' "both slots are recorded"
TEST_KEYSLOTS="4" run luks-slots owner=4 recovery= || fail "an empty recovery= records none" "$(cat "$test_tmp/err")"
state_is 'owner_slot=4' "an empty recovery= drops the recovery slot"
pass "luks-slots records the owner's and the recovery slot the header holds, keeping the rest of encrypt.state"

refused() {
  local context=$1 says=$2
  shift 2
  if run luks-slots "$@"; then fail "luks-slots refuses $context"; fi
  error_says "$says"
  state_is $'owner_slot=2\nrecovery_slot=3' "$context: encrypt.state is untouched"
}
slots_fixture
TEST_KEYSLOTS="0 2" refused "a recorded recovery slot the header lost" "has no key in slot 3" owner=0
TEST_KEYSLOTS="3" refused "an owner slot the header does not hold" "has no key in slot 0" owner=0
TEST_KEYSLOTS="3" TEST_TOKENS="0" refused "a keyring token numbered like the owner's slot" "has no key in slot 0" owner=0
refused "the same slot for both" "cannot share key slot 3" owner=3
refused "a missing owner" "needs owner=<slot>" recovery=3
refused "a slot past the header's 32" "needs owner=<slot>" owner=32
refused "an argument it does not know" "not: slot=2" owner=2 slot=2
refused "a malformed recovery slot" "needs recovery=<slot>" owner=2 recovery=x
TEST_DUMP_FAIL=1 refused "an unreadable header" "Could not read the key slots" owner=2
rm "$root/dev/disk/by-uuid/$luks_uuid"
refused "a LUKS device crypttab does not name" "Could not find the encrypted disk" owner=2
pass "luks-slots never records a slot the root's LUKS header does not hold"

for phase in plaintext shrunk reencrypting encrypted; do
  fixture
  sed -i "s/^phase=.*/phase=$phase/" "$root/boot/omarchy/encrypt.state"
  before=$(cat "$root/boot/omarchy/encrypt.state")
  if run luks-slots owner=2 recovery=3; then fail "luks-slots refuses phase=$phase"; fi
  [[ $(cat "$root/boot/omarchy/encrypt.state") == "$before" ]] || fail "phase=$phase: encrypt.state is untouched"
done
fixture
sed -i 's/^phase=.*/phase=declined/' "$root/boot/omarchy/encrypt.state"
before=$(cat "$root/boot/omarchy/encrypt.state")
run luks-slots owner=2 || fail "a declined Mac has nothing to record"
[[ $(cat "$root/boot/omarchy/encrypt.state") == "$before" ]] || fail "a declined Mac's encrypt.state is untouched"
rm "$root/boot/omarchy/encrypt.state"
run luks-slots owner=2 || fail "a Mac without encrypt.state has nothing to record"
[[ ! -e $root/boot/omarchy/encrypt.state ]] || fail "luks-slots creates no encrypt.state"
pass "luks-slots records nothing on a Mac the image did not encrypt, and waits for an unfinished conversion"
