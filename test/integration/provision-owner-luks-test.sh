#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"

# Owner provisioning on an Apple Silicon image, from the owner's password to a
# finished setup: omarchy-provision-owner's own functions, the shared re-key
# journal, the real omarchy-lifecycle-dispatch and omarchy-mac-boot's real
# provisioning entrypoints, staged by its install script into a fixture root.
# cryptsetup is a slot-table fake; the boot tools the entrypoints run are stubs.
require_platform_fixtures "the Apple Silicon owner provisioning path"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_platform "$tmp/apple" apple-silicon
stub_bin=$tmp/bin
root=$tmp/root
calls=$tmp/calls
slots=$tmp/slots
device=$tmp/luks-device
prov=$root/var/lib/omarchy/provisioning
boot_key=$root/boot/omarchy/luks-key
encrypt_state=$root/boot/omarchy/encrypt.state
grub_default=$root/etc/default/grub
mkdir -p "$stub_bin"
: >"$device"
bash "$BOOT/install" "$root"

# Dispatch runs an entrypoint with an empty environment; each fixture
# entrypoint hands the staged one its root, stubs and platform fixture.
lifecycle=$tmp/lifecycle
mkdir -p "$lifecycle/usr/lib/omarchy/mac-boot"
for operation in provision-prepare provision-commit provision-verify luks-slots; do
  cat >"$lifecycle/usr/lib/omarchy/mac-boot/$operation" <<SH
#!/bin/bash
echo "$operation" >>"$calls"
exec /usr/bin/env OMARCHY_MAC_BOOT_ROOT="$root" OMARCHY_PROC_ROOT="$tmp/apple/proc" \\
  PATH="$stub_bin:$tmp/apple/bin:$ROOT/bin:/usr/bin:/bin" "$root/usr/lib/omarchy/mac-boot/$operation" "\$@"
SH
done
chmod 755 "$lifecycle/usr/lib/omarchy/mac-boot"/*
chmod -R go-w "$lifecycle"

cat >"$stub_bin/mkinitcpio" <<SH
#!/bin/bash
echo "mkinitcpio \$*" >>"$calls"
[[ ! -e $tmp/fail-mkinitcpio ]] || exit 1
printf '%s\n' ./usr/lib/systemd/system-generators/systemd-cryptsetup-generator \\
  ./usr/lib/systemd/system/omarchy-vendorfw-initrd.service \\
  ./usr/lib/systemd/system/systemd-cryptsetup@.service.d/omarchy-vendorfw-initrd.conf >"$root/boot/initramfs-linux-aurora.img"
SH
# The image holds no vconsole.conf, like one built for a Mac left on the US map.
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
[[ $1 == -l && -f $2 ]] && exec cat "$2"
[[ $1 == -x && -f $2 ]]
SH
cat >"$stub_bin/omarchy-mac-kernel" <<'SH'
#!/bin/bash
echo linux-aurora
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
echo /boot/efi
SH
cat >"$stub_bin/omarchy-mac-boot-update" <<SH
#!/bin/bash
echo "omarchy-mac-boot-update" >>"$calls"
sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"/linux \/vmlinuz-linux-aurora \1/p' "$grub_default" >"$root/boot/grub/grub.cfg"
SH
for tool in limine-update update-grub; do
  printf '#!/bin/bash\necho %s >>"%s"\n' "$tool" "$calls" >"$stub_bin/$tool"
done
cat >"$stub_bin/stty" <<'SH'
#!/bin/bash
echo "24 80"
SH
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/systemctl"

cat >"$stub_bin/cryptsetup" <<SH
#!/bin/bash
printf 'cryptsetup %s\n' "\$*" >>"$calls"
slots_file="$slots"
read_key() {
  [[ -n "\$1" && -e "\$1" ]] || return 1
  cat "\$1"
}
slot_for() {
  local slot rest
  while read -r slot rest; do
    [[ \$rest == "\$1" ]] && { printf '%s' "\$slot"; return 0; }
  done <"\$slots_file"
  return 1
}
case "\$1" in
  open)
    keyfile="" token_type="" verbose=0
    while ((\$#)); do
      case "\$1" in
        --verbose) verbose=1 ;;
        --key-file) keyfile=\$2; shift ;;
        --token-type) token_type=\$2; shift ;;
      esac
      shift
    done
    # An enrolled token unlocks its slot whatever key is given, unless the
    # allowed token types exclude it, as with cryptsetup.
    if [[ -z \$token_type && -s "$tmp/token-slot" ]]; then
      (( verbose )) && echo "Key slot \$(cat "$tmp/token-slot") unlocked." >&2
      exit 0
    fi
    material=\$(read_key "\$keyfile") || exit 1
    slot=\$(slot_for "\$material") || exit 1
    (( verbose )) && echo "Key slot \$slot unlocked" >&2
    exit 0
    ;;
  luksAddKey)
    keyfile="" target="" newfile="" requested=""
    shift
    while ((\$#)); do
      case "\$1" in
        --key-file) keyfile=\$2; shift 2 ;;
        --key-slot) requested=\$2; shift 2 ;;
        --*) shift ;;
        *) if [[ -z \$target ]]; then target=\$1; else newfile=\$1; fi; shift ;;
      esac
    done
    material=\$(read_key "\$keyfile") || exit 1
    slot_for "\$material" >/dev/null || exit 1
    new=\$(read_key "\$newfile") || exit 1
    next=\$requested
    if [[ -z \$next ]]; then
      for (( next = 0; next < 32; next++ )); do
        awk '{ print \$1 }' "\$slots_file" | grep -qx "\$next" || break
      done
    fi
    printf '%s %s\n' "\$next" "\$new" >>"\$slots_file"
    ;;
  luksDump)
    echo "Keyslots:"
    awk '{ printf "  %s: luks2\\n", \$1 }' "\$slots_file"
    if [[ -s "$tmp/token-slot" ]]; then
      printf 'Tokens:\\n  %s: luks2-keyring\\n\\tKeyslot:    %s\\n' "\$(cat "$tmp/token-id" 2>/dev/null || echo 0)" "\$(cat "$tmp/token-slot")"
    fi
    echo "Digests:"
    ;;
  luksKillSlot)
    [[ ! -e $tmp/fail-kill ]] || exit 1
    kill_slot=""
    while ((\$#)); do
      [[ \$1 =~ ^[0-9]+$ ]] && kill_slot=\$1
      shift
    done
    awk -v s="\$kill_slot" '\$1 != s { print }' "\$slots_file" >"\$slots_file.new"
    mv "\$slots_file.new" "\$slots_file"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$stub_bin"/*

omarchy=$tmp/omarchy
mkdir -p "$omarchy/install/provisioning" "$omarchy/bin"
printf 'OMARCHY\n' >"$omarchy/logo.txt"
: >"$omarchy/install/provisioning/setup-form.sh"
cp "$ROOT/install/provisioning/luks-rekey.sh" "$omarchy/install/provisioning/"
for command in omarchy-lifecycle-dispatch omarchy-hw-platform omarchy-hw-apple-silicon; do
  ln -s "$ROOT/bin/$command" "$omarchy/bin/$command"
done

export PATH="$stub_bin:$tmp/apple/bin:$PATH"
export OMARCHY_PATH=$omarchy OMARCHY_PROC_ROOT=$tmp/apple/proc OMARCHY_LIFECYCLE_ROOT=$lifecycle
export OMARCHY_PROVISIONING_DIR=$prov OMARCHY_PROVISION_OWNER_LOG=$tmp/provision.log
export OMARCHY_LUKS_DEVICE=$device OMARCHY_PROVISION_OWNER_SOURCE=1 COLUMNS=80
units=$tmp/units
export OMARCHY_SYSTEMD_UNIT_DIR=$units

# shellcheck disable=SC1091
source "$ROOT/bin/omarchy-provision-owner"

# The worker's account steps and the screen are not under test.
STATE_FILE=$tmp/state
FINALIZE_WARNING_FLAG=$tmp/finalize-warning
username=owner hostname="" timezone=""
create_user() { :; }
install_authorized_keys() { :; }
configure_login() { :; }
configure_hostname() { :; }
configure_timezone() { :; }
finalize_user() { :; }
limine_entries_stale() { return 1; }
clear_logo() { :; }
PADDING_LEFT=0
sleep() { :; }
screen=$tmp/screen
say() { [[ $1 != --foreground ]] || shift 2; printf '%s\n' "$*" >>"$screen"; }

cat >"$stub_bin/gum" <<SH
#!/bin/bash
printf 'gum %s\n' "\$*" >>"$calls"
if [[ "\$1" == "style" ]]; then
  cat >>"$tmp/gum-stdin"
elif [[ "\$1" == "input" ]]; then
  cat >/dev/null
  # Out of answers: fail the attempt rather than loop on the prompt.
  IFS= read -r line <"$tmp/gum-input" || { echo "gum input exhausted" >>"$calls"; kill -TERM "\$PPID"; exit 1; }
  tail -n +2 "$tmp/gum-input" >"$tmp/gum-input.new"
  mv "$tmp/gum-input.new" "$tmp/gum-input"
  printf '%s\n' "\$line"
fi
SH
chmod +x "$stub_bin/gum"

luks_uuid=1b2c3d4e-0000-4000-8000-000000000001
key_line="rd.luks.key=$luks_uuid=/omarchy/luks-key:UUID=4f4d5801-424f-4f54-8000-000000000001"

# The state an encrypted image's first boot hands owner setup: the initramfs
# converted the root with a throwaway key, staged on the boot partition and in
# the provisioning directory, and named on GRUB's command line.
fixture() {
  rm -rf "$root/boot" "$root/etc" "$root/var" "$root/dev"
  mkdir -p "$root/boot/omarchy" "$root/boot/grub" "$root/etc/default" "$root/dev/disk/by-uuid" "$prov" \
    "$root/var/lib/omarchy/mac-first-boot"
  chmod 755 "$prov"
  printf 'throwaway-install-key' >"$prov/luks-key"
  printf 'throwaway-install-key' >"$boot_key"
  chmod 600 "$prov/luks-key" "$boot_key"
  touch "$prov/pending"
  printf 'format=1\nphase=configured\npartition=5f2b0c3e-0003\nluks_uuid=%s\n' "$luks_uuid" >"$encrypt_state"
  printf 'GRUB_CMDLINE_LINUX="rd.luks.name=%s=root %s root=/dev/mapper/root"\n' "$luks_uuid" "$key_line" >"$grub_default"
  printf 'linux /vmlinuz-linux-aurora rd.luks.name=%s=root %s\n' "$luks_uuid" "$key_line" >"$root/boot/grub/grub.cfg"
  printf 'root UUID=%s none luks\n' "$luks_uuid" >"$root/etc/crypttab"
  : >"$root/dev/disk/by-uuid/$luks_uuid"
  printf 'format=1\nencrypt=1\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
  "$stub_bin/mkinitcpio" && : >"$calls"
  printf '0 throwaway-install-key\n' >"$slots"
  rm -f "$tmp"/fail-* "$tmp/token-slot" "$tmp/token-id" "$screen" "$tmp/gum-stdin"
  rm -rf "$units"
  : >"$OMARCHY_PROVISION_OWNER_LOG"
  : >"$tmp/gum-input"
  password=owner-secret
  UNLOCK_OWNER=""
}

slot_of() {
  awk -v m="$1" '$2 == m { print $1; exit }' "$slots"
}

# ── the whole first-boot setup ─────────────────────────────────────────────
fixture
platform_ready || fail "an encrypted image is ready for owner setup" "$(cat "$screen" 2>/dev/null)"
: >"$calls"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "first-boot setup finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
owner=$(slot_of owner-secret)

[[ -n $owner && $(awk '{ print $1 }' "$slots") == "$owner" ]] ||
  fail "only the owner's slot remains" "$(cat "$slots")"
[[ -z $(slot_of throwaway-install-key) ]] || fail "the throwaway key opens nothing"
[[ ! -e $prov/luks-key && ! -e $boot_key ]] || fail "both copies of the throwaway key are gone"
[[ ! -e $prov/pending && ! -e $prov/luks-rekey.state ]] || fail "setup drops pending and the journal"
[[ $(<"$grub_default") == "GRUB_CMDLINE_LINUX=\"rd.luks.name=$luks_uuid=root root=/dev/mapper/root\"" ]] ||
  fail "only rd.luks.key= leaves GRUB's defaults" "$(cat "$grub_default")"
! grep -q 'rd.luks.key=' "$root/boot/grub/grub.cfg" || fail "the rebuilt grub.cfg asks for the password"
[[ $(<"$encrypt_state") == "format=1
phase=finished
partition=5f2b0c3e-0003
luks_uuid=$luks_uuid
owner_slot=$owner" ]] || fail "encrypt.state is finished with the owner's slot alone" "$(cat "$encrypt_state")"
grep -qx provision-commit "$calls" && grep -qx provision-verify "$calls" && grep -qx luks-slots "$calls" ||
  fail "the boot package commits and verifies the unlock and records the slot through dispatch" "$(cat "$calls")"
! grep -Eq '^(limine-update|update-grub)$' "$calls" || fail "the Limine UKI path never runs on Apple Silicon" "$(cat "$calls")"
! declare -F show_recovery_key >/dev/null && ! declare -F prepare_luks_recovery >/dev/null && ! grep -q "^gum " "$calls" && [[ ! -e $screen ]] || fail "setup shows no recovery key" "$(cat "$calls" "$screen" 2>&1)"
! grep -Fq -e owner-secret -e throwaway-install-key "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "no key material reaches the provision log"
[[ ! -e $units ]] || fail "setup arms no password reset" "$(ls -R "$units" 2>&1)"
pass "an encrypted Apple image's first boot re-keys to the owner's password alone and takes the throwaway key out of the boot chain"

# A Mac whose setup an older runtime began journaled a recovery key it added.
# Finishing that setup keeps the owner's password alone: the recovery slot is
# retired with the throwaway and encrypt.state records none.
fixture
printf '0 throwaway-install-key\n3 OLD-RECOVERY-KEY\n' >"$slots"
printf 'staged_slot=0\nrecovery_slot=3\nrecovery_shown=1\nphase=staged\n' >"$prov/luks-rekey.state"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "setup begun with a recovery key finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
owner=$(slot_of owner-secret)
[[ -n $owner && $(awk '{ print $1 }' "$slots") == "$owner" ]] ||
  fail "the older setup's recovery slot is retired" "$(cat "$slots")"
grep -Fxq "owner_slot=$owner" "$encrypt_state" && ! grep -q '^recovery_slot=' "$encrypt_state" ||
  fail "encrypt.state records the owner's slot and no recovery slot" "$(cat "$encrypt_state")"
[[ ! -e $units ]] || fail "finishing an older setup arms no password reset"
pass "setup an older runtime began with a recovery key finishes with the owner's password alone"

# ── install.conf handoff before the owner is asked anything ────────────────
fixture
rm "$encrypt_state"
if platform_ready; then fail "setup stops on a plain root when install.conf asked for encryption"; fi
grep -q 'set up to encrypt its disk, but the disk was not encrypted' "$screen" &&
  grep -q 'set up to encrypt its disk' "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "the boot package's reason reaches the owner and the log" "$(cat "$screen" "$OMARCHY_PROVISION_OWNER_LOG")"
printf 'format=1\nencrypt=0\n' >"$root/var/lib/omarchy/mac-first-boot/install.conf"
rm -f "$prov/luks-key" "$boot_key" "$screen"
sed -i "s| $key_line||" "$grub_default" "$root/boot/grub/grub.cfg"
platform_ready || fail "encrypt=0 lets a plain root be set up" "$(cat "$screen" 2>/dev/null)"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "a plain Mac finishes setup" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
! grep -q provision-commit "$calls" && ! grep -q 'cryptsetup luks' "$calls" || fail "a plain Mac is not re-keyed" "$(cat "$calls")"
pass "provision-prepare holds setup to the encryption install.conf asked for"

# ── failures and retries ──────────────────────────────────────────────────
# A failed boot rebuild keeps the unattended unlock and every slot.
fixture
touch "$tmp/fail-mkinitcpio"
if run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
  fail "a failed boot rebuild fails the attempt"
fi
[[ -f $boot_key && -f $prov/luks-key && -f $prov/pending ]] || fail "a failed rebuild keeps the throwaway key and setup pending"
grep -q "$key_line" "$grub_default" || fail "a failed rebuild restores rd.luks.key="
[[ -n $(slot_of throwaway-install-key) ]] || fail "a failed rebuild retires no slot"
grep -Fxq 'phase=configured' "$encrypt_state" || fail "a failed rebuild leaves encrypt.state configured"
rm "$tmp/fail-mkinitcpio"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "the retry finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
[[ $(wc -l <"$slots") == 1 && ! -e $boot_key && ! -e $prov/pending ]] || fail "the retry finishes with one slot" "$(cat "$slots")"
pass "a failed boot rebuild keeps the unattended unlock and every slot for the retry"

# Interrupted after the boot package committed, before the slots were retired:
# encrypt.state is already finished while the throwaway slot and file remain.
fixture
touch "$tmp/fail-kill"
if run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
  fail "a failed slot retirement fails the attempt"
fi
grep -Fxq 'phase=finished' "$encrypt_state" && [[ ! -e $boot_key && -f $prov/luks-key ]] ||
  fail "the boot chain was committed before the retirement failed"
rm "$tmp/fail-kill"
first_owner=$(slot_of owner-secret)
grep -Fxq "owner_slot=$first_owner" "$encrypt_state" || fail "the commit recorded the first password's slot"
password=another-password
rekey_accepts_password || fail "while the throwaway key opens the disk a retry may choose a new password"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "the retry finishes after the commit" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
owner=$(slot_of another-password)
[[ $(wc -l <"$slots") == 1 && -n $owner && -z $(slot_of throwaway-install-key) &&
  -z $(slot_of owner-secret) && ! -e $prov/luks-key ]] ||
  fail "the retry keeps the new password and retires the rest" "$(cat "$slots")"
[[ $owner != "$first_owner" ]] && grep -Fxq "owner_slot=$owner" "$encrypt_state" && ! grep -q '^recovery_slot=' "$encrypt_state" ||
  fail "encrypt.state follows the owner's slot the retry moved" "$(cat "$encrypt_state")"
pass "a retry after the commit may still change the password, and encrypt.state records the slot setup kept"

# A finished re-key never ends setup while any boot-time unlock remains: the
# journal's last check asks the boot package.
for leftover in boot cmdline; do
  fixture
  rm "$prov/luks-key"
  printf '1 owner-secret\n' >"$slots"
  printf 'staged_slot=0\nowner_slot=1\nphase=done\n' >"$prov/luks-rekey.state"
  sed -i 's/^phase=.*/phase=finished/' "$encrypt_state"
  if [[ $leftover == boot ]]; then
    sed -i "s| $key_line||" "$grub_default" "$root/boot/grub/grub.cfg"
  else
    rm "$boot_key"
  fi
  if run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
    fail "setup does not finish with a leftover $leftover unlock"
  fi
  grep -q 'the boot-time auto-unlock is still configured' "$OMARCHY_PROVISION_OWNER_LOG" ||
    fail "$leftover: provision-verify is what stops setup" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
  [[ -f $prov/pending ]] || fail "a leftover $leftover unlock keeps setup pending"
done
pass "a finished encrypt.state never ends setup while a boot-time unlock remains"

# A token a previous owner enrolled (TPM2, FIDO2, keyring) answers a bare
# cryptsetup open for any key. It never stands in for the owner's password:
# that gets its own slot, and the token's slot is retired.
fixture
printf '5 tpm-sealed-key\n' >>"$slots"
echo 5 >"$tmp/token-slot"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "setup finishes beside a token" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
owner=$(slot_of owner-secret)
[[ -n $owner && $owner != 5 ]] ||
  fail "the owner's password gets its own slot beside a token" "$(cat "$slots")"
[[ $(awk '{ print $1 }' "$slots") == "$owner" ]] ||
  fail "the token's slot is retired with the throwaway" "$(cat "$slots")"
grep -Fxq "owner_slot=$owner" "$encrypt_state" && ! grep -q '^recovery_slot=' "$encrypt_state" ||
  fail "encrypt.state records the owner's own slot" "$(cat "$encrypt_state")"
pass "a previous owner's token never answers for the owner's password"

# A retry beside a token, once the throwaway key is retired: only the password
# the owner slot holds is taken.
fixture
printf '5 tpm-sealed-key\n' >>"$slots"
echo 5 >"$tmp/token-slot"
touch "$tmp/fail-kill"
if run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
  fail "a failed slot retirement beside a token fails the attempt"
fi
rm "$tmp/fail-kill"
awk '$1 != 0' "$slots" >"$slots.next" && mv "$slots.next" "$slots"
password=another-password
rekey_accepts_password && fail "beside a token, a retry refuses a password that opens nothing"
password=owner-secret
rekey_accepts_password || fail "beside a token, a retry takes the password the owner slot holds"
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "the retry beside a token finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
[[ $(wc -l <"$slots") == 1 && -z $(slot_of tpm-sealed-key) ]] || fail "the retry retires the token's slot" "$(cat "$slots")"
pass "a retry beside a token takes only the password the owner slot holds"

# xtrace never records the owner's password.
fixture
password=owner-secret-xtrace
set -x
run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1
set +x
! grep -Fq "$password" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "xtrace keeps secrets out of the provision log" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
pass "secret-bearing re-key commands are not captured under xtrace"
