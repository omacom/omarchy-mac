#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Factory reset from omarchy-system-factory-reset's own functions, through the
# real omarchy-lifecycle-dispatch: on x86 the generic Limine UKI path, with Mac
# entrypoints on disk that must not run, and on Apple Silicon into
# omarchy-mac-boot's reset entrypoints, staged by its install script into a
# fixture of the live Mac. Subvolumes are directories: btrfs, mount and chroot
# are stubs, and cryptsetup is a slot-table fake.
require_platform_fixtures "factory reset through lifecycle dispatch"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_platform "$tmp/apple" apple-silicon
fake_platform "$tmp/x86" generic
real_cryptsetup=$(command -v cryptsetup || true)
stub_bin=$tmp/bin
calls=$tmp/calls
slots=$tmp/slots
screen=$tmp/screen
device=$tmp/luks-device
live=$tmp/live
top=$tmp/top
mkdir -p "$stub_bin"
: >"$device"
bash "$ROOT/packages/omarchy-mac/boot/install" "$live"

luks_uuid=1b2c3d4e-0000-4000-8000-000000000001
token="rd.luks.key=$luks_uuid=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001"
new_id=fedcba9876543210fedcba9876543210
firmware_listing='./usr/lib/systemd/system-generators/systemd-cryptsetup-generator
./usr/lib/systemd/system/omarchy-vendorfw-initrd.service
./usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf'

# Dispatch runs an entrypoint with an empty environment; each fixture
# entrypoint hands the staged one the live Mac's root, stubs and platform.
lifecycle=$tmp/lifecycle
mkdir -p "$lifecycle/usr/lib/omarchy/mac-boot" "$tmp/no-package"
for operation in reset-prepare reset-verify reset-commit reset-rollback; do
  cat >"$lifecycle/usr/lib/omarchy/mac-boot/$operation" <<SH
#!/bin/bash
echo "$operation \$*" >>"$calls"
exec /usr/bin/env OMARCHY_MAC_BOOT_ROOT="$live" OMARCHY_PROC_ROOT="$tmp/apple/proc" \\
  PATH="$stub_bin:$tmp/apple/bin:$ROOT/bin:/usr/bin:/bin" "$live/usr/lib/omarchy/mac-boot/$operation" "\$@"
SH
done
chmod 755 "$lifecycle/usr/lib/omarchy/mac-boot"/*
chmod -R go-w "$lifecycle"

cat >"$stub_bin/gum" <<SH
#!/bin/bash
if [[ \$1 == input ]]; then
  head -n 1 "$tmp/gum-inputs"
  sed -i '1d' "$tmp/gum-inputs"
  exit 0
fi
[[ \$1 == style ]] && printf '%s\n' "\${!#}" >>"$screen"
[[ -z \${TEST_FAIL_AT:-} || \${!#} != *"\$TEST_FAIL_AT"* ]]
SH

# A slot table: "<slot> <key>" per line. An enrolled token unlocks its slot
# whatever key is given, unless the allowed token types exclude it.
cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
printf 'cryptsetup %s\n' "\$*" >>"$calls"
case "\$1" in
  open)
    key_file="" token_type=""
    while ((\$#)); do
      case "\$1" in
        --key-file) key_file=\$2; shift ;;
        --token-type) token_type=\$2; shift ;;
      esac
      shift
    done
    [[ -n \$token_type || ! -s "$tmp/token-slot" ]] || exit 0
    material=\$(cat "\$key_file") || exit 1
    awk -v m="\$material" '\$2 == m { found = 1 } END { exit !found }' "$slots" || exit 2
    ;;
  luksAddKey)
    shift
    args=()
    while ((\$#)); do
      case "\$1" in
        --key-file) auth=\$(cat "\$2"); shift 2 ;;
        -*) shift ;;
        *) args+=("\$1"); shift ;;
      esac
    done
    awk -v m="\$auth" '\$2 == m { found = 1 } END { exit !found }' "$slots" || exit 2
    new=\$(cat "\${args[1]}")
    for (( next = 0; next < 32; next++ )); do
      awk '{ print \$1 }' "$slots" | grep -qx "\$next" || break
    done
    printf '%s %s\n' "\$next" "\$new" >>"$slots"
    ;;
  luksDump)
    echo "Keyslots:"
    awk '{ printf "  %s: luks2\\n", \$1 }' "$slots"
    if [[ -s "$tmp/token-slot" ]]; then
      printf 'Tokens:\\n  %s: luks2-keyring\\n\\tKeyslot:    %s\\n' "\$(cat "$tmp/token-slot")" "\$(cat "$tmp/token-slot")"
    fi
    ;;
  luksKillSlot)
    kill_slot=""
    while ((\$#)); do
      [[ \$1 =~ ^[0-9]+$ ]] && kill_slot=\$1
      shift
    done
    awk -v s="\$kill_slot" '\$1 != s { print }' "$slots" >"$slots.new"
    mv "$slots.new" "$slots"
    ;;
  luksUUID) echo $luks_uuid ;;
  *) exit 1 ;;
esac
SH

# Subvolumes are directories.
cat >"$stub_bin/btrfs" <<SH
#!/bin/bash
echo "btrfs \$*" >>"$calls"
case "\$1 \$2" in
  "subvolume snapshot") cp -a "\$3" "\$4" ;;
  "subvolume delete") rm -rf "\${!#}" ;;
  "subvolume show") exit 1 ;;
esac
exit 0
SH
cat >"$stub_bin/userdel" <<'SH'
#!/bin/bash
[[ $1 == --root ]] && sed -i "/^$3:/d" "$2/etc/passwd"
SH
printf '#!/bin/bash\necho %s\n' "$new_id" >"$stub_bin/systemd-id128"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/passwd"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/mountpoint"
for tool in mount umount update-grub update-m1n1; do
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$tool" "$calls" >"$stub_bin/$tool"
done
# chroot runs a command in the factory root: an absolute path is the factory
# root's own file, anything else a stub on PATH.
cat >"$stub_bin/chroot" <<SH
#!/bin/bash
echo "chroot \$*" >>"$calls"
factory=\$1
shift
[[ \$1 != /* ]] || set -- "\$factory\$1" "\${@:2}"
exec "\$@"
SH

# The Apple boot tools the entrypoints run.
cat >"$stub_bin/omarchy-mac-kernel" <<'SH'
#!/bin/bash
echo linux-aurora
SH
cat >"$stub_bin/omarchy-mac-esp" <<'SH'
#!/bin/bash
echo /boot/efi
SH
cat >"$stub_bin/findmnt" <<'SH'
#!/bin/bash
if [[ " $* " == *" --mountpoint "* && " $* " == *" UUID "* && ${*: -1} == */boot ]]; then
  echo 4f4d5801-424f-4f54-8000-000000000001
  exit 0
fi
exec /usr/bin/findmnt "$@"
SH
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
[[ $1 == -l && -f $2 ]] && cat "$2"
SH
cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
echo "mkinitcpio \$*" >>"$calls"
if [[ -e $tmp/build-without-firmware ]]; then
  echo ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator >"$live/boot/initramfs-linux-aurora.img"
else
  printf '%s\n' "$firmware_listing" >"$live/boot/initramfs-linux-aurora.img"
fi
SH
chmod +x "$stub_bin"/*

omarchy=$tmp/omarchy
mkdir -p "$omarchy/bin"
for command in omarchy-lifecycle-dispatch omarchy-hw-platform; do
  ln -s "$ROOT/bin/$command" "$omarchy/bin/$command"
done

base_path=$stub_bin:$PATH
export OMARCHY_PATH=$omarchy OMARCHY_LIFECYCLE_ROOT=$lifecycle
export OMARCHY_FACTORY_RESET_SOURCE=1 OMARCHY_FACTORY_RESET_LOG=$tmp/reset.log OMARCHY_LUKS_DEVICE=$device
export PATH=$base_path

# shellcheck disable=SC1091
source "$ROOT/bin/omarchy-system-factory-reset"
export PATH=$base_path
# shellcheck disable=SC2034 # read by the sourced reset
TOP_MNT=$top

# Visible failures: the sourced script replaces fail with its own gum exit.
test_fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

# shellcheck disable=SC2034 # read by the sourced reset
on_platform() {
  export OMARCHY_PROC_ROOT=$tmp/$1/proc PATH=$tmp/$1/bin:$base_path
  RESET_BOOT="" RESET_BOOT_PREPARED=0 RESET_LUKS_SLOT="" RESET_LUKS_DEVICE="" RESET_THROWAY="" reset_committed=0 swap_done=0
}

# The previous owner's root at @ and the installer's @factory, which predates
# the first boot's encryption. Its kernel is the one in the live /boot.
subvolumes() {
  rm -rf "$top"
  mkdir -p "$top/@" "$top/@factory"
  echo "previous owner" >"$top/@/owner"
  local factory=$top/@factory
  mkdir -p "$factory/etc/default" "$factory/usr/bin" "$factory/boot" "$factory/usr/lib/modules/7.1-aurora" \
    "$factory/usr/share/omarchy/install/provisioning" "$factory/usr/share/omarchy/default/limine"
  printf 'root:x:0:0::/root:/bin/bash\nseller:x:1000:1000::/home/seller:/bin/bash\n' >"$factory/etc/passwd"
  echo 0123456789abcdef0123456789abcdef >"$factory/etc/machine-id"
  : >"$factory/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
  : >"$factory/usr/share/omarchy/install/provisioning/omarchy-system-factory-reset-finish.service"
  printf '#!/bin/bash\n' >"$factory/usr/bin/omarchy-provision-owner"
  chmod +x "$factory/usr/bin/omarchy-provision-owner"
  printf 'timeout: 3\n' >"$factory/usr/share/omarchy/default/limine/limine.conf"
  printf 'GRUB_CMDLINE_LINUX="quiet"\n' >"$factory/etc/default/grub"
  echo linux-aurora >"$factory/usr/lib/modules/7.1-aurora/pkgbase"
  printf 'kernel' >"$factory/usr/lib/modules/7.1-aurora/vmlinuz"
  printf '0 current-pass\n' >"$slots"
  printf 'wrong-pass\ncurrent-pass\n' >"$tmp/gum-inputs"
  rm -f "$tmp/token-slot" "$tmp/build-without-firmware"
  : >"$calls"
  : >"$screen"
}

# x86: the ESP in fstab, and limine-update building a UKI with the keyfile.
x86_fixture() {
  subvolumes
  local factory=$top/@factory
  : >"$tmp/esp-device"
  printf '%s /boot vfat defaults 0 2\n' "$tmp/esp-device" >"$factory/etc/fstab"
  cat >"$factory/usr/bin/limine-update" <<SH
#!/bin/bash
echo "limine-update" >>"$calls"
root=\$(cd "\$(dirname "\$0")/../.." && pwd)
mkdir -p "\$root/boot/EFI/Linux"
printf 'uki with %s' "\$(cat "\$root/etc/omarchy/provisioning.key" 2>/dev/null)" >"\$root/boot/EFI/Linux/omarchy_linux.efi"
printf '  path: boot():/EFI/Linux/omarchy_linux.efi#%s\n' "\$(b2sum "\$root/boot/EFI/Linux/omarchy_linux.efi" | cut -d' ' -f1)" >>"\$root/boot/limine.conf"
SH
  chmod +x "$factory/usr/bin/limine-update"
}

# Apple: the live Mac boots GRUB from its Boot partition, its previous owner
# finished encryption, and the factory root rebuilds GRUB from its defaults.
apple_fixture() {
  subvolumes
  local factory=$top/@factory
  rm -rf "${live:?}/boot" "${live:?}/etc" "${live:?}/var" "${live:?}/run"
  mkdir -p "$live/boot/omarchy" "$live/boot/grub" "$live/boot/efi/EFI/BOOT" "$live/etc/default" \
    "$live/var/lib/omarchy/mac-first-boot" "$live/run"
  printf 'kernel' >"$live/boot/vmlinuz-linux-aurora"
  printf '%s\n' "$firmware_listing" >"$live/boot/initramfs-linux-aurora.img"
  printf 'linux /vmlinuz-linux-aurora quiet rd.luks.name=%s=root\n' "$luks_uuid" >"$live/boot/grub/grub.cfg"
  printf 'grub' >"$live/boot/efi/EFI/BOOT/BOOTAA64.EFI"
  printf 'format=1\nphase=finished\npartition=5f2b0c3e-0003\nluks_uuid=%s\nowner_slot=0\n' "$luks_uuid" >"$live/boot/omarchy/encrypt.state"
  printf 'GRUB_CMDLINE_LINUX="quiet rd.luks.name=%s=root"\n' "$luks_uuid" >"$live/etc/default/grub"
  printf 'root UUID=%s none luks\n' "$luks_uuid" >"$live/etc/crypttab"
  printf 'format=1\nencrypt=1\n' >"$live/var/lib/omarchy/mac-first-boot/install.conf"
  cat >"$factory/usr/bin/omarchy-mac-boot-update" <<SH
#!/bin/bash
root=\$(cd "\$(dirname "\$0")/../.." && pwd)
cmdline=\$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"/\1/p' "\$root/etc/default/grub")
echo "omarchy-mac-boot-update \$cmdline" >>"$calls"
printf 'linux /vmlinuz-linux-aurora %s\n' "\$cmdline" >"$live/boot/grub/grub.cfg"
SH
  chmod +x "$factory/usr/bin/omarchy-mac-boot-update"
}

# A reset as the command runs it: errexit on and the cleanup trap set. Called
# as a plain statement, since an if or || around it would switch errexit off
# inside; the status lands in reset_status.
run_reset() {
  reset_status=0
  (trap cleanup EXIT; stage_full_reset >/dev/null) &
  wait $! || reset_status=$?
}

live_tree() {
  (cd "$live/boot" && find . -type f -exec sha256sum {} + | sort)
}

old_root() {
  compgen -G "$top/@omarchy-old-*" | head -n 1
}

# ── x86: the generic path, whatever Mac entrypoints are on disk ────────────
on_platform x86
x86_fixture
run_reset
(( reset_status == 0 )) || test_fail "an x86 reset stages" "$(cat "$screen" "$tmp/reset.log")"
! grep -q '^reset-' "$calls" || test_fail "no Mac entrypoint runs on x86" "$(cat "$calls")"
throwaway=$(cat "$top/@/var/lib/omarchy/provisioning/luks-key")
[[ $(cat "$top/@/etc/omarchy/provisioning.key") == "$throwaway" ]] &&
  grep -Fq 'cryptkey=rootfs:/etc/omarchy/provisioning.key' "$top/@/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf" &&
  grep -Fq 'FILES+=(/etc/omarchy/provisioning.key)' "$top/@/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf" ||
  test_fail "x86 embeds the throwaway in the factory root's UKI"
grep -q '^chroot .*/usr/bin/limine-update' "$calls" && grep -Fq "uki with $throwaway" "$top/@/boot/EFI/Linux/omarchy_linux.efi" ||
  test_fail "x86 rebuilds the UKI with limine-update in the factory root" "$(cat "$calls")"
grep -Fq "1 $throwaway" "$slots" || test_fail "x86 adds the throwaway slot" "$(cat "$slots")"
[[ $(sed -n 's/^cryptsetup luksAddKey.*/add/p;/^chroot .*limine-update/s/.*/rebuild/p' "$calls" | tr '\n' ' ') == "add rebuild " ]] ||
  test_fail "x86 adds its slot before the rebuild, as before" "$(cat "$calls")"
[[ $(cat "$(old_root)/owner") == "previous owner" && ! -e $top/@/owner ]] || test_fail "the factory clone is the active root"
[[ ! -e $live/boot/omarchy/luks-key ]] || test_fail "x86 writes no Apple boot key"
pass "x86 resets through the generic Limine UKI path, and no Mac entrypoint runs"

# ── Apple: prepare, verify, slot, switch, commit ───────────────────────────
on_platform apple
apple_fixture
run_reset
(( reset_status == 0 )) || test_fail "an Apple reset stages" "$(cat "$screen" "$tmp/reset.log")"
throwaway=$(cat "$top/@/var/lib/omarchy/provisioning/luks-key")
next=$top/@omarchy-reset-next
[[ $(grep -E '^(reset-|cryptsetup luksAddKey)' "$calls" | sed 's/^cryptsetup luksAddKey.*/luksAddKey/') == "reset-prepare $next $device
reset-verify $next
luksAddKey
reset-commit " ]] || test_fail "the boot package prepares and verifies before the slot, and commits after the switch" "$(cat "$calls")"
! grep -Fq -- "$throwaway" "$calls" || test_fail "the throwaway never reaches an argument list"
[[ ! -e $top/@/etc/omarchy/provisioning.key ]] || test_fail "Apple embeds no UKI keyfile"
[[ $(cat "$live/boot/omarchy/luks-key") == "$throwaway" ]] || test_fail "reset-commit writes the throwaway to the Boot partition"
grep -Fq "1 $throwaway" "$slots" || test_fail "the throwaway slot opens the disk" "$(cat "$slots")"
grep -Fq "$token" "$live/boot/grub/grub.cfg" && grep -Fq "$token" "$top/@/etc/default/grub" ||
  test_fail "the factory root boots with the unlock on its command line" "$(cat "$live/boot/grub/grub.cfg")"
[[ $(cat "$live/boot/omarchy/encrypt.state") == $'format=1\nphase=configured\npartition=5f2b0c3e-0003\nluks_uuid='"$luks_uuid" ]] ||
  test_fail "encrypt.state is reopened for the next owner" "$(cat "$live/boot/omarchy/encrypt.state")"
[[ ! -e $live/run/omarchy-mac-boot/reset ]] || test_fail "commit drops the saved boot files"
[[ $(cat "$(old_root)/owner") == "previous owner" && $(cat "$top/@/etc/machine-id") == "$new_id" ]] ||
  test_fail "the scrubbed factory clone is the active root"
[[ -f $top/@/var/lib/omarchy/provisioning/pending && -f $top/@/var/lib/omarchy/provisioning/wipe-pending ]] ||
  test_fail "owner setup and the wipe are armed on the factory root"
pass "an Apple reset rebuilds and verifies through the boot package, adds the slot, switches, then writes the key"

# A failed verification rolls back to the previous root: its boot files and
# encryption state come back, no credential was added, and @ is untouched.
on_platform apple
apple_fixture
before=$(live_tree)
: >"$tmp/build-without-firmware"
run_reset
(( reset_status != 0 )) || test_fail "a failed verification fails the reset"
grep -q '^reset-verify ' "$calls" && grep -q '^reset-rollback' "$calls" || test_fail "verification fails, then rollback runs" "$(cat "$calls")"
grep -Fq 'before the keyboard firmware loads' "$screen" || test_fail "the owner sees why" "$(cat "$screen")"
[[ $(live_tree) == "$before" ]] || test_fail "the previous boot files and encryption state are back" "$(diff <(echo "$before") <(live_tree))"
! grep -q 'luksAddKey' "$calls" && [[ $(cat "$slots") == "0 current-pass" ]] || test_fail "no slot is added before verification passes"
[[ $(cat "$top/@/owner") == "previous owner" && -z $(old_root) && ! -e $next ]] ||
  test_fail "the previous root stays active and the clone is gone"
[[ ! -e $live/boot/omarchy/luks-key && ! -e $live/run/omarchy-mac-boot/reset ]] || test_fail "no key, no saved state left"
pass "a failed verification rolls back to the previous root with its boot files and encryption state"

# A failure after the slot, before the switch: rollback, then the slot goes.
on_platform apple
apple_fixture
before=$(live_tree)
export TEST_FAIL_AT="Activating the factory system"
run_reset
(( reset_status != 0 )) || test_fail "a failure before activation fails the reset"
unset TEST_FAIL_AT
grep -q 'luksAddKey' "$calls" && grep -q '^reset-rollback' "$calls" && ! grep -q '^reset-commit' "$calls" ||
  test_fail "the slot was added, then rollback ran without commit" "$(cat "$calls")"
[[ $(cat "$slots") == "0 current-pass" ]] || test_fail "the throwaway slot is revoked" "$(cat "$slots")"
[[ $(live_tree) == "$before" && $(cat "$top/@/owner") == "previous owner" ]] || test_fail "the previous root boots as before"
pass "a failure after the slot is added revokes it and restores the previous boot state"

# Apple without the boot package: the reset stops before it is confirmed.
on_platform apple
if (export OMARCHY_LIFECYCLE_ROOT=$tmp/no-package; reset_boot_owner) 2>"$tmp/err"; then
  test_fail "Apple without omarchy-mac-boot cannot be reset"
fi
grep -Fq 'needs omarchy-mac-boot' "$tmp/err" || test_fail "the error names the package" "$(cat "$tmp/err")"
pass "an Apple reset without omarchy-mac-boot's entrypoints fails, naming the package"

# ── The passphrase check and the throwaway slot ────────────────────────────
# A token enrolled on the disk (TPM2, FIDO2, keyring) answers a bare cryptsetup
# open for any passphrase: the reset asks again until the typed one opens a
# slot itself, and the throwaway slot is told apart from the token.
on_platform apple
subvolumes
mkdir -p "$tmp/next/var/lib/omarchy/provisioning"
echo 1 >"$tmp/token-slot"
stage_luks_rekey "$tmp/next" >/dev/null
(( $(grep -c 'does not unlock' "$screen") == 1 )) || test_fail "a passphrase only a token would accept is asked again" "$(cat "$screen")"
[[ $RESET_LUKS_AUTH == "current-pass" ]] || test_fail "the reset authorises with the passphrase that opens a slot"
! grep -q luksAddKey "$calls" || test_fail "the platform's slot waits for verification"
add_reset_luks_slot "$RESET_LUKS_DEVICE" "$RESET_THROWAY"
[[ $RESET_LUKS_SLOT == 1 && $(awk '$1 == 1 { print $2 }' "$slots") == "$RESET_THROWAY" ]] ||
  test_fail "the throwaway slot is found beside the token" "$RESET_LUKS_SLOT: $(cat "$slots")"
revoke_reset_luks
[[ $(cat "$slots") == "0 current-pass" && -z $RESET_LUKS_SLOT ]] || test_fail "cleanup revokes the slot this attempt added"
revoke_reset_luks
[[ $(cat "$slots") == "0 current-pass" ]] || test_fail "revoking twice is harmless"
pass "a token never answers for the current passphrase, and only the reset's own slot is revoked"

# The same on a real file-backed LUKS2 volume with a keyring token whose id a
# naive luksDump parse would read as a slot. PBKDF2 keeps it fast.
if [[ -z $real_cryptsetup ]]; then
  pass "cryptsetup is not installed; skipping the file-backed volume run"
else
  volume=$tmp/volume.img
  truncate -s 32M "$volume"
  "$real_cryptsetup" luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$volume" <(printf 'current-pass') 2>/dev/null
  printf '{"type":"luks2-keyring","keyslots":["0"],"key_description":"omarchy-reset-test"}' |
    "$real_cryptsetup" token import --token-id 5 "$volume" 2>/dev/null
  mv "$stub_bin/cryptsetup" "$tmp/cryptsetup.fake"
  cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
printf 'cryptsetup %s\n' "\$*" >>"$calls"
[[ \$1 != luksAddKey ]] || set -- luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "\${@:2}"
exec "$real_cryptsetup" "\$@"
SH
  chmod +x "$stub_bin/cryptsetup"
  opens() {
    "$real_cryptsetup" open --test-passphrase --token-type passphrase-only --key-file <(printf '%s' "$1") "$volume" 2>/dev/null
  }
  on_platform apple
  subvolumes
  mkdir -p "$tmp/real-next/var/lib/omarchy/provisioning"
  (
    export OMARCHY_LUKS_DEVICE=$volume
    stage_luks_rekey "$tmp/real-next" >/dev/null
    (( $(grep -c 'does not unlock' "$screen") == 1 )) || test_fail "a real volume refuses the wrong passphrase once" "$(cat "$screen")"
    add_reset_luks_slot "$RESET_LUKS_DEVICE" "$RESET_THROWAY"
    [[ $RESET_LUKS_SLOT == 1 ]] || test_fail "the throwaway's real slot is found beside token 5" "$RESET_LUKS_SLOT"
    opens "$RESET_THROWAY" || test_fail "the throwaway opens the real volume"
    revoke_reset_luks
    ! opens "$RESET_THROWAY" && opens current-pass || test_fail "revoking removes only the throwaway's slot"
  ) || exit 1
  mv "$tmp/cryptsetup.fake" "$stub_bin/cryptsetup"
  pass "on a real LUKS2 volume with a token, the reset checks the passphrase, adds and revokes exactly its own slot"
fi

# ── @factory and the next root ─────────────────────────────────────────────
factory="$tmp/factory"
mkdir -p "$factory/etc" \
  "$factory/var/lib/omarchy/mac-first-boot" \
  "$factory/var/lib/omarchy/provisioning" \
  "$factory/boot/efi/omarchy" \
  "$factory/boot/omarchy"
: >"$factory/etc/passwd"
: >"$factory/etc/machine-id"
touch "$factory/var/lib/omarchy/mac-first-boot/pending" \
  "$factory/var/lib/omarchy/mac-first-boot/deferred-steps" \
  "$factory/var/lib/omarchy/mac-first-boot/install.conf" \
  "$factory/var/lib/omarchy/provisioning/pending" \
  "$factory/var/lib/omarchy/provisioning/wipe-pending" \
  "$factory/boot/efi/omarchy/install.conf"
printf 'format=1\nphase=finished\npartition=p\nluks_uuid=u\n' >"$factory/boot/omarchy/encrypt.state"
sanitize_factory_baseline "$factory"
[[ ! -e $factory/var/lib/omarchy/mac-first-boot/pending ]] || test_fail "@factory does not keep mac-first-boot/pending"
[[ ! -e $factory/var/lib/omarchy/mac-first-boot/deferred-steps ]] || test_fail "@factory does not keep the fresh-image conversion token"
[[ ! -e $factory/var/lib/omarchy/mac-first-boot/install.conf ]] || test_fail "@factory does not keep install.conf"
[[ ! -e $factory/var/lib/omarchy/provisioning/pending ]] || test_fail "@factory does not keep provisioning/pending"
[[ ! -e $factory/var/lib/omarchy/provisioning/wipe-pending ]] || test_fail "@factory does not keep wipe-pending"
[[ ! -e $factory/boot/efi/omarchy/install.conf ]] || test_fail "@factory does not keep the ESP install.conf"
# /boot inside a subvolume is an empty mountpoint on a real system: the live
# Boot partition's state belongs to the boot package, never to the scrub.
[[ -f $factory/boot/omarchy/encrypt.state ]] || test_fail "the subvolume scrub leaves boot/omarchy alone"

cloned="$tmp/cloned"
mkdir -p "$cloned/var/lib/omarchy/mac-first-boot" "$cloned/boot/omarchy" "$cloned/boot/efi/omarchy"
mkdir -p "$cloned/var/lib/omarchy/image"
touch "$cloned/var/lib/omarchy/image/deferred-steps" \
  "$cloned/var/lib/omarchy/mac-first-boot/pending" \
  "$cloned/var/lib/omarchy/mac-first-boot/deferred-steps" \
  "$cloned/var/lib/omarchy/mac-first-boot/install.conf" \
  "$cloned/boot/efi/omarchy/install.conf"
printf 'format=1\nphase=finished\n' >"$cloned/boot/omarchy/encrypt.state"
scrub_factory_boot_state "$cloned"
arm_reset_markers "$cloned"
[[ -f $cloned/var/lib/omarchy/mac-first-boot/pending ]] || test_fail "reset re-arms mac-first-boot/pending"
[[ -f $cloned/var/lib/omarchy/provisioning/pending ]] || test_fail "reset re-arms provisioning/pending"
[[ -f $cloned/var/lib/omarchy/provisioning/wipe-pending ]] || test_fail "reset re-arms wipe-pending"
[[ ! -e $cloned/var/lib/omarchy/mac-first-boot/install.conf ]] || test_fail "reset next root does not keep install.conf"
[[ ! -e $cloned/var/lib/omarchy/mac-first-boot/deferred-steps ]] ||
  test_fail "reset next root carries no fresh-image conversion token, so the initramfs does not convert it again"
[[ -f $cloned/var/lib/omarchy/image/deferred-steps ]] || test_fail "reset next root keeps the image's hardware queue for its first boot"
[[ ! -e $cloned/boot/efi/omarchy/install.conf ]] || test_fail "reset next root does not keep the ESP install.conf"
[[ -f $cloned/boot/omarchy/encrypt.state ]] || test_fail "the next-root scrub leaves boot/omarchy alone"
pass "the reset re-arms both markers on the next root and keeps @factory clean"
