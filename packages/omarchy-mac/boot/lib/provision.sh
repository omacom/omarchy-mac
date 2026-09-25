# Sourced by the owner provisioning entrypoints in /usr/lib/omarchy/mac-boot
# (provision-prepare, provision-commit, provision-verify) and by luks-slots,
# which omarchy-lifecycle-dispatch runs; do not run independently. The
# runtime's docs/lifecycle-dispatch.md is their contract.
#
# The entrypoints set MAC_BOOT_ROOT before sourcing: empty on a live system, a
# fixture root in unprivileged tests. Everything here reads fixed paths below
# it. Output goes to stderr, which the caller shows or logs.

BOOT_LUKS_KEY=$MAC_BOOT_ROOT/boot/omarchy/luks-key
ENCRYPT_STATE=$MAC_BOOT_ROOT/boot/omarchy/encrypt.state
GRUB_DEFAULT=$MAC_BOOT_ROOT/etc/default/grub
GRUB_CFG=$MAC_BOOT_ROOT/boot/grub/grub.cfg
LIMINE_DEFAULT=$MAC_BOOT_ROOT/etc/default/limine
LIMINE_GATE=$MAC_BOOT_ROOT/var/lib/omarchy/limine.enabled
CRYPTTAB=$MAC_BOOT_ROOT/etc/crypttab
REKEY_STATE=$MAC_BOOT_ROOT/var/lib/omarchy/provisioning/luks-rekey.state
INSTALL_CONF=$MAC_BOOT_ROOT/var/lib/omarchy/mac-first-boot/install.conf
# The image's Boot partition, as omarchy-mac-encrypt names it in rd.luks.key=.
BOOT_UUID=4f4d5801-424f-4f54-8000-000000000001

log_step() { printf '%s\n' "$*" >&2; }

# One line for the owner: provision-prepare's stderr is shown on tty1.
refuse() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_apple_silicon() {
  [[ $(omarchy-hw-platform 2>/dev/null) == apple-silicon ]] ||
    refuse "omarchy-mac-boot provisioning runs only on Apple Silicon Macs."
}

# An image keeps the key, encrypt.state and the initramfs on its Boot
# partition: with that unmounted, /boot is a directory on the root and every
# check below would read the wrong files.
require_boot_partition() {
  [[ ! -e $INSTALL_CONF ]] ||
    [[ $(findmnt -n -o UUID --mountpoint "$MAC_BOOT_ROOT/boot" 2>/dev/null) == "$BOOT_UUID" ]] ||
    refuse "This Mac's Boot partition is not mounted at /boot."
}

grub_drop_rd_luks_key() {
  local file=${1:-$GRUB_DEFAULT} tmp
  [[ -f $file ]] || return 1
  grep -q 'rd.luks.key=' "$file" || return 0
  # Runs under `||`, where errexit is off: check every step and replace the
  # defaults durably, never truncating them on a failed write.
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if sed -E 's/[[:space:]]*rd\.luks\.key=[^[:space:]"]+//g' "$file" >"$tmp" &&
    ! grep -q 'rd.luks.key=' "$tmp" && grep -q '^GRUB_CMDLINE_LINUX' "$tmp" &&
    chmod --reference="$file" "$tmp" && sync "$tmp" && mv -f "$tmp" "$file"; then
    sync "$(dirname "$file")"
    return
  fi
  rm -f "$tmp"
  return 1
}

# While the boot-partition key exists, GRUB's command line names it, as
# omarchy-mac-encrypt wrote it, so sd-encrypt unlocks unattended too.
grub_restore_rd_luks_key() {
  local uuid tmp
  [[ -f $GRUB_DEFAULT ]] && ! grep -q 'rd.luks.key=' "$GRUB_DEFAULT" || return 0
  uuid=$(encrypt_state_get luks_uuid || true)
  [[ $uuid =~ ^[0-9a-fA-F-]+$ ]] || return 1
  tmp=$(mktemp "$GRUB_DEFAULT.XXXXXX") || return 1
  if sed -E "s|^(GRUB_CMDLINE_LINUX=\"[^\"]*)\"|\\1 rd.luks.key=$uuid=/omarchy/luks-key:UUID=$BOOT_UUID\"|" "$GRUB_DEFAULT" >"$tmp" &&
    grep -q 'rd.luks.key=' "$tmp" && chmod --reference="$GRUB_DEFAULT" "$tmp" && sync "$tmp" &&
    mv -f "$tmp" "$GRUB_DEFAULT"; then
    sync "$(dirname "$GRUB_DEFAULT")"
    return
  fi
  rm -f "$tmp"
  return 1
}

apple_rekey_boot() {
  [[ -f $GRUB_DEFAULT ]] || {
    log_step "no $GRUB_DEFAULT to drop rd.luks.key="
    return 1
  }
  if grep -q 'rd.luks.key=' "$GRUB_DEFAULT"; then
    grub_drop_rd_luks_key "$GRUB_DEFAULT" || return 1
  fi
  if ! mkinitcpio -P </dev/null >&2 || ! omarchy-mac-boot-update >&2; then
    log_step "mkinitcpio or omarchy-mac-boot-update failed while dropping the staged key"
    return 1
  fi
}

state_get() {
  [[ -f $1 ]] || return 1
  awk -F= -v k="$2" '$1 == k { print $2; exit }' "$1"
}

encrypt_state_get() {
  state_get "$ENCRYPT_STATE" "$1"
}

limine_mac() {
  [[ -e $LIMINE_GATE && -f $LIMINE_DEFAULT ]]
}

# The initramfs that asks for the owner's password must load the vendor
# firmware first, or an M2 or later laptop's keyboard cannot type it.
initramfs_orders_firmware() {
  local kernel listing
  kernel=$(omarchy-mac-kernel) || return 1
  if ! listing=$(lsinitcpio -l "$MAC_BOOT_ROOT/boot/initramfs-$kernel.img" 2>/dev/null); then
    log_step "cannot list /boot/initramfs-$kernel.img"
    return 1
  fi
  grep -Eq '(^|/)usr/lib/systemd/system-generators/systemd-cryptsetup-generator$' <<<"$listing" &&
    grep -Eq '(^|/)usr/lib/systemd/system/omarchy-vendorfw-initrd\.service$' <<<"$listing" &&
    grep -Eq '(^|/)usr/lib/systemd/system/systemd-cryptsetup@\.service\.d/omarchy-vendorfw-initrd\.conf$' <<<"$listing" || {
    log_step "/boot/initramfs-$kernel.img does not load the vendor firmware before the disk password prompt"
    return 1
  }
}

# Phase moves to finished. partition= and luks_uuid= stay as the initramfs
# wrote them; the owner slot, and a recovery slot the owner acknowledged, come
# from the re-key journal so later boot checks can prove the header holds
# exactly those slots. luks-slots records them again whenever they change.
write_encrypt_state() {
  local phase=$1 owner_slot recovery_slot value

  owner_slot=$(encrypt_state_get owner_slot || true)
  recovery_slot=$(encrypt_state_get recovery_slot || true)
  value=$(state_get "$REKEY_STATE" owner_slot || true)
  if [[ -n $value ]]; then
    owner_slot=$value
    recovery_slot=""
    [[ $(state_get "$REKEY_STATE" recovery_shown || true) != 1 ]] ||
      recovery_slot=$(state_get "$REKEY_STATE" recovery_slot || true)
    [[ $recovery_slot != "$owner_slot" ]] || recovery_slot=""
  fi
  put_encrypt_state "$phase" "$owner_slot" "$recovery_slot"
}

# Rewrite encrypt.state durably with this phase and these slots.
put_encrypt_state() {
  local phase=$1 owner_slot=$2 recovery_slot=$3 format=1 partition luks_uuid tmp

  partition=$(encrypt_state_get partition || true)
  luks_uuid=$(encrypt_state_get luks_uuid || true)
  install -d -m 755 "$(dirname "$ENCRYPT_STATE")" || return 1
  tmp=$(mktemp "$ENCRYPT_STATE.XXXXXX") || return 1
  {
    printf 'format=%s\nphase=%s\npartition=%s\nluks_uuid=%s\n' "$format" "$phase" "$partition" "$luks_uuid"
    [[ -z $owner_slot ]] || printf 'owner_slot=%s\n' "$owner_slot"
    [[ -z $recovery_slot ]] || printf 'recovery_slot=%s\n' "$recovery_slot"
  } >"$tmp" && chmod 644 "$tmp" && sync "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ENCRYPT_STATE" || { rm -f "$tmp"; return 1; }
  sync "$(dirname "$ENCRYPT_STATE")"
}

# What the first boot recorded from the installer's install.conf: 1, 0, or
# nothing when this Mac did not start from an image. An absent install.conf
# was recorded as encrypt=1.
install_conf_encrypt() {
  state_get "$INSTALL_CONF" encrypt || true
}

# The root the initramfs encrypted, as crypttab names it.
luks_root_device() {
  local uuid recorded
  uuid=$(awk '$1 == "root" && $2 ~ /^UUID=/ { sub(/^UUID=/, "", $2); print $2; exit }' "$CRYPTTAB" 2>/dev/null || true)
  [[ -n $uuid && -e $MAC_BOOT_ROOT/dev/disk/by-uuid/$uuid ]] || return 1
  recorded=$(encrypt_state_get luks_uuid || true)
  [[ -z $recorded || $recorded == "$uuid" ]] || return 1
  printf '%s\n' "$MAC_BOOT_ROOT/dev/disk/by-uuid/$uuid"
}

luks_device_found() {
  luks_root_device >/dev/null
}

# The key slots in use, one per line. A luks2-keyring token under "Tokens:"
# looks like a keyslot, so read only the keyslot section.
luks_keyslots() {
  local dump
  dump=$(cryptsetup luksDump "$1") || return 1
  awk '
    /^[^ \t]/ { keyslots = ($0 == "Keyslots:") }
    keyslots && /^ +[0-9]+: luks2/ { sub(":", "", $1); print $1 }
    /^Key Slot [0-9]+: ENABLED/ { sub(":", "", $3); print $3 }' <<<"$dump"
}

# Limine and its UKI go on the ESP the device tree says this Mac boots from.
esp_selected() {
  local esp limine_esp
  esp=$(omarchy-mac-esp) || return 1
  limine_mac || return 0
  limine_esp=$(sed -n -E 's/^[[:space:]]*ESP_PATH=("([^"]*)"|'\''([^'\'']*)'\''|([^[:space:]#"'\'']*)).*/\2\3\4/p' "$LIMINE_DEFAULT" | tail -n 1)
  [[ $limine_esp == "$esp" ]] || {
    log_step "Limine writes to ${limine_esp:-no ESP_PATH}, but this Mac boots from the ESP at $esp"
    return 1
  }
}

# The phases the initramfs leaves once the root is encrypted and boots with
# the staged key.
encrypted_phase() {
  [[ $1 == configured || $1 == rekeyed || $1 == finished ]]
}

provision_prepare() {
  local phase
  require_apple_silicon
  require_boot_partition
  phase=$(encrypt_state_get phase || true)

  if [[ -z $phase ]]; then
    [[ $(install_conf_encrypt) != 1 ]] ||
      refuse "This Mac was set up to encrypt its disk, but the disk was not encrypted. Reinstall Omarchy, or choose no encryption in the installer."
    return 0
  fi
  [[ $phase != declined ]] || return 0
  encrypted_phase "$phase" ||
    refuse "Encrypting this Mac's disk did not finish (encrypt.state phase=$phase). Restart to let it continue."

  luks_device_found ||
    refuse "Could not find the encrypted disk that /etc/crypttab names."
  initramfs_orders_firmware ||
    refuse "The boot image would ask for the disk password before the keyboard firmware loads."
  esp_selected ||
    refuse "The EFI partition this Mac boots from is not where its boot files are written."
}

provision_commit() {
  local phase
  require_apple_silicon
  require_boot_partition
  phase=$(encrypt_state_get phase || true)
  # The initramfs resumes an unfinished conversion with the boot-partition key.
  if [[ -e $ENCRYPT_STATE && -z $phase ]] || { [[ -n $phase && $phase != declined ]] && ! encrypted_phase "$phase"; }; then
    log_step "encrypt.state is phase=${phase:-unreadable}; the conversion still needs $BOOT_LUKS_KEY"
    return 1
  fi

  # The boot-partition key goes last: until then the initramfs still unlocks
  # with it, so a failure only has to put rd.luks.key= back, whichever attempt
  # dropped it.
  if ! apple_rekey_boot || ! initramfs_orders_firmware; then
    if [[ -f $BOOT_LUKS_KEY ]] && ! grep -q 'rd.luks.key=' "$GRUB_DEFAULT" 2>/dev/null; then
      log_step "restoring rd.luks.key= for the retry"
      grub_restore_rd_luks_key && omarchy-mac-boot-update >&2 || true
    fi
    return 1
  fi

  if [[ -e $BOOT_LUKS_KEY || -L $BOOT_LUKS_KEY ]]; then
    shred -u "$BOOT_LUKS_KEY" 2>/dev/null || rm -f "$BOOT_LUKS_KEY" || return 1
    sync "$(dirname "$BOOT_LUKS_KEY")"
  fi
  if encrypted_phase "$phase"; then
    write_encrypt_state finished || return 1
  fi
}

# Read-only. Succeeds only when nothing in the boot chain can still unlock the
# root with the staged install key.
provision_verify() {
  local phase
  require_apple_silicon
  require_boot_partition

  if [[ -e $BOOT_LUKS_KEY || -L $BOOT_LUKS_KEY ]]; then
    log_step "$BOOT_LUKS_KEY still holds the staged install key"
    return 1
  fi
  if grep -qs 'rd\.luks\.key=' "$GRUB_DEFAULT"; then
    log_step "$GRUB_DEFAULT still names the staged install key (rd.luks.key=)"
    return 1
  fi
  if limine_mac; then
    ! grep -qs 'rd\.luks\.key=' "$LIMINE_DEFAULT" || {
      log_step "$LIMINE_DEFAULT still names the staged install key (rd.luks.key=)"
      return 1
    }
  elif grep -qs 'rd\.luks\.key=' "$GRUB_CFG"; then
    log_step "$GRUB_CFG still names the staged install key (rd.luks.key=)"
    return 1
  fi
  if [[ -e $ENCRYPT_STATE ]]; then
    phase=$(encrypt_state_get phase || true)
    [[ $phase == declined || $phase == finished ]] || {
      log_step "encrypt.state is phase=${phase:-unreadable}, not finished"
      return 1
    }
  fi
}

# luks-slots owner=<slot> [recovery=<slot>]: record the slots of the owner's
# password and of the recovery key in encrypt.state, whenever setup or a
# password change leaves them in other slots, so the boot check can prove the
# header holds exactly those. Without recovery=, the recorded one stays; an
# empty one records none. Each must be a key slot the root's header holds. A
# Mac whose disk the image did not encrypt records nothing.
record_luks_slots() {
  local arg owner="" recovery="" recovery_given=0 phase device slots slot

  require_apple_silicon
  require_boot_partition
  for arg in "$@"; do
    case $arg in
      owner=*) owner=${arg#owner=} ;;
      recovery=*) recovery=${arg#recovery=} recovery_given=1 ;;
      *) refuse "luks-slots takes owner=<slot> and recovery=<slot>, not: $arg" ;;
    esac
  done
  [[ $owner =~ ^([0-9]|[12][0-9]|3[01])$ ]] || refuse "luks-slots needs owner=<slot>, a LUKS key slot number."

  [[ -e $ENCRYPT_STATE ]] || return 0
  phase=$(encrypt_state_get phase || true)
  [[ $phase != declined ]] || return 0
  encrypted_phase "$phase" ||
    refuse "encrypt.state is phase=${phase:-unreadable}; the disk's conversion has not finished."

  (( recovery_given )) || recovery=$(encrypt_state_get recovery_slot || true)
  [[ -z $recovery || $recovery =~ ^([0-9]|[12][0-9]|3[01])$ ]] ||
    refuse "luks-slots needs recovery=<slot>, a LUKS key slot number."
  [[ $recovery != "$owner" ]] || refuse "The owner's password and the recovery key cannot share key slot $owner."

  device=$(luks_root_device) || refuse "Could not find the encrypted disk that /etc/crypttab names."
  slots=$(luks_keyslots "$device") || refuse "Could not read the key slots of $device."
  for slot in $owner $recovery; do
    grep -Fxq "$slot" <<<"$slots" || refuse "The LUKS header of $device has no key in slot $slot."
  done
  put_encrypt_state "$phase" "$owner" "$recovery" || refuse "Could not write $ENCRYPT_STATE."
}
