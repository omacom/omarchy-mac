#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Owner provisioning on an Apple Silicon image, from the recovery key to a
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
bash "$ROOT/packages/omarchy-mac/boot/install" "$root"

# Dispatch runs an entrypoint with an empty environment; each fixture
# entrypoint hands the staged one its root, stubs and platform fixture.
lifecycle=$tmp/lifecycle
mkdir -p "$lifecycle/usr/lib/omarchy/mac-boot"
for operation in provision-prepare provision-commit provision-verify; do
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
cat >"$stub_bin/lsinitcpio" <<'SH'
#!/bin/bash
[[ $1 == -l && -f $2 ]] && cat "$2"
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
    keyfile="" verbose=0
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
    awk '{ printf "  %s: luks2\\n", \$1 }' "\$slots_file"
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
cp "$ROOT/install/provisioning/luks-rekey.sh" "$ROOT/install/provisioning/luks-recovery.sh" "$omarchy/install/provisioning/"
for command in omarchy-lifecycle-dispatch omarchy-hw-platform omarchy-hw-apple-silicon; do
  ln -s "$ROOT/bin/$command" "$omarchy/bin/$command"
done

export PATH="$stub_bin:$tmp/apple/bin:$PATH"
export OMARCHY_PATH=$omarchy OMARCHY_PROC_ROOT=$tmp/apple/proc OMARCHY_LIFECYCLE_ROOT=$lifecycle
export OMARCHY_PROVISIONING_DIR=$prov OMARCHY_PROVISION_OWNER_LOG=$tmp/provision.log
export OMARCHY_LUKS_DEVICE=$device OMARCHY_PROVISION_OWNER_SOURCE=1 COLUMNS=80

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
  rm -f "$tmp"/fail-* "$screen" "$tmp/gum-stdin"
  : >"$OMARCHY_PROVISION_OWNER_LOG"
  printf 'nope\n%s\n' "$RECOVERY_ACK_PHRASE" >"$tmp/gum-input"
  password=owner-secret
  recovery_key=""
  RECOVERY_ACKED=0
  UNLOCK_OWNER=""
}

slot_of() {
  awk -v m="$1" '$2 == m { print $1; exit }' "$slots"
}

# ── the whole first-boot setup ─────────────────────────────────────────────
fixture
platform_ready || fail "an encrypted image is ready for owner setup" "$(cat "$screen" 2>/dev/null)"
prepare_luks_recovery "$device" >"$tmp/show.out"
grep -aqF $'\e[3J' "$tmp/show.out" || fail "the recovery screen clears the scrollback"
[[ $(<"$tmp/gum-stdin") == "$recovery_key" ]] || fail "the recovery key reaches gum on stdin only"
! grep -F "$recovery_key" "$calls" >/dev/null || fail "the recovery key is never a command argument"
owner=$(slot_of owner-secret)
recovery=$(slot_of "$recovery_key")
[[ -n $owner && -n $recovery ]] || fail "the owner and recovery slots exist before the worker runs" "$(cat "$slots")"
: >"$calls"
OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "first-boot setup finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"

[[ $(awk '{ print $1 }' "$slots" | sort -n | paste -sd' ') == "$(printf '%s\n' "$owner" "$recovery" | sort -n | paste -sd' ')" ]] ||
  fail "only the owner's and the acknowledged recovery slots remain" "$(cat "$slots")"
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
owner_slot=$owner
recovery_slot=$recovery" ]] || fail "encrypt.state is finished with the kept slots" "$(cat "$encrypt_state")"
grep -qx provision-commit "$calls" && grep -qx provision-verify "$calls" ||
  fail "the boot package commits and verifies the unlock through dispatch" "$(cat "$calls")"
! grep -Eq '^(limine-update|update-grub)$' "$calls" || fail "the Limine UKI path never runs on Apple Silicon" "$(cat "$calls")"
! grep -Fq -e "$recovery_key" -e owner-secret -e throwaway-install-key "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "no key material reaches the provision log"
pass "an encrypted Apple image's first boot re-keys to the owner, keeps the recovery key and takes the throwaway key out of the boot chain"

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
OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "a plain Mac finishes setup" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
! grep -q provision-commit "$calls" && ! grep -q 'cryptsetup luks' "$calls" || fail "a plain Mac is not re-keyed" "$(cat "$calls")"
pass "provision-prepare holds setup to the encryption install.conf asked for"

# ── failures and retries ──────────────────────────────────────────────────
# A failed boot rebuild keeps the unattended unlock and every slot.
fixture
prepare_luks_recovery "$device" >/dev/null
touch "$tmp/fail-mkinitcpio"
if OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
  fail "a failed boot rebuild fails the attempt"
fi
[[ -f $boot_key && -f $prov/luks-key && -f $prov/pending ]] || fail "a failed rebuild keeps the throwaway key and setup pending"
grep -q "$key_line" "$grub_default" || fail "a failed rebuild restores rd.luks.key="
[[ -n $(slot_of throwaway-install-key) ]] || fail "a failed rebuild retires no slot"
grep -Fxq 'phase=configured' "$encrypt_state" || fail "a failed rebuild leaves encrypt.state configured"
rm "$tmp/fail-mkinitcpio"
prepare_luks_recovery "$device" >/dev/null || fail "the retry's recovery step keeps the acknowledged key"
OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "the retry finishes" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
[[ $(wc -l <"$slots") == 2 && ! -e $boot_key && ! -e $prov/pending ]] || fail "the retry finishes with two slots" "$(cat "$slots")"
pass "a failed boot rebuild keeps the unattended unlock and every slot for the retry"

# Interrupted after the boot package committed, before the slots were retired:
# encrypt.state is already finished while the throwaway slot and file remain.
fixture
prepare_luks_recovery "$device" >/dev/null
touch "$tmp/fail-kill"
if OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
  fail "a failed slot retirement fails the attempt"
fi
grep -Fxq 'phase=finished' "$encrypt_state" && [[ ! -e $boot_key && -f $prov/luks-key ]] ||
  fail "the boot chain was committed before the retirement failed"
rm "$tmp/fail-kill"
password=another-password
rekey_accepts_password && fail "a retry cannot change the password once a recovery key sits beside it"
password=owner-secret
rekey_accepts_password || fail "the retry keeps the password the disk holds"
prepare_luks_recovery "$device" >/dev/null || fail "the retry keeps the acknowledged recovery key"
OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1 ||
  fail "the retry finishes after the commit" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
[[ $(wc -l <"$slots") == 2 && -z $(slot_of throwaway-install-key) && ! -e $prov/luks-key ]] ||
  fail "the retry retires the throwaway slot and destroys the key" "$(cat "$slots")"
pass "a retry after the commit finishes with the password and recovery key already set"

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
  if OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1; then
    fail "setup does not finish with a leftover $leftover unlock"
  fi
  grep -q 'the boot-time auto-unlock is still configured' "$OMARCHY_PROVISION_OWNER_LOG" ||
    fail "$leftover: provision-verify is what stops setup" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
  [[ -f $prov/pending ]] || fail "a leftover $leftover unlock keeps setup pending"
done
pass "a finished encrypt.state never ends setup while a boot-time unlock remains"

# The recovery step never runs in the background worker, whose output is a log.
fixture
if OMARCHY_PROVISION_WORKER=1 prepare_luks_recovery "$device"; then fail "the worker cannot show a recovery key"; fi
[[ $(wc -l <"$slots") == 1 ]] || fail "the worker adds no slot for a recovery key it cannot show"
pass "the recovery key is shown only on the setup terminal"

# xtrace never records the owner's password or the recovery key.
fixture
password=owner-secret-xtrace
prepare_luks_recovery "$device" >/dev/null
set -x
OMARCHY_PROVISION_WORKER=1 run_provisioning >>"$OMARCHY_PROVISION_OWNER_LOG" 2>&1
set +x
! grep -Fq -e "$recovery_key" -e "$password" "$OMARCHY_PROVISION_OWNER_LOG" ||
  fail "xtrace keeps secrets out of the provision log" "$(cat "$OMARCHY_PROVISION_OWNER_LOG")"
pass "secret-bearing re-key commands are not captured under xtrace"
