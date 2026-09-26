#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FILES=$ROOT/files
SCRIPT=$FILES/usr/lib/omarchy/initcpio/omarchy-mac-encrypt
INSTALL=$FILES/usr/lib/initcpio/install/omarchy-mac-encrypt
UNIT=$FILES/usr/lib/omarchy/initcpio/omarchy-mac-encrypt.service
DROPIN=$FILES/etc/mkinitcpio.conf.d/91-omarchy-mac-encrypt.conf
RUNTIME_HOOK=$FILES/usr/lib/initcpio/hooks/omarchy-mac-encrypt
ESP_UUID=4F4D-5801
BOOT_UUID=4f4d5801-424f-4f54-8000-000000000001
REDUCE_BYTES=$((32 * 1024 * 1024))
# The drop-ins ask omarchy-hw-platform; the stand-in answers apple-silicon.
export PATH="$ROOT/test/helpers:$PATH"

fail() {
  echo "not ok - $1" >&2
  [[ -z ${case_dir:-} || ! -f $case_dir/out ]] || cat "$case_dir/out" >&2
  exit 1
}

# ── static ─────────────────────────────────────────────────────────────────
[[ -x $SCRIPT && -x $INSTALL && -f $UNIT && -f $DROPIN ]] ||
  fail "T4a ships the script, install hook, unit and drop-in"
[[ ! -e $RUNTIME_HOOK ]] || fail "v3 ships no mkinitcpio runtime hook"
! grep -Fq '/usr/lib/initcpio/hooks/omarchy-mac-encrypt' "$INSTALL" ||
  fail "the install hook must not add a runtime hook"

grep -Eq '\bcryptsetup\b' "$INSTALL" && grep -Eq '\bbtrfs\b' "$INSTALL" && grep -Fq 'add_binary "$binary"' "$INSTALL" ||
  fail "the install hook puts cryptsetup and btrfs in the image"
grep -Fq 'add_file /usr/lib/omarchy/initcpio/omarchy-mac-encrypt' "$INSTALL" ||
  fail "the install hook copies the unit script into the initramfs"

grep -Fq 'After=systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service omarchy-vendorfw-initrd.service' "$UNIT" &&
  grep -Fq 'Wants=systemd-udevd.service systemd-udev-trigger.service omarchy-vendorfw-initrd.service' "$UNIT" &&
  grep -Fq 'Before=cryptsetup-pre.target sysroot.mount initrd-root-device.target' "$UNIT" &&
  grep -Fxq 'DefaultDependencies=no' "$UNIT" &&
  grep -Fq 'TimeoutStartSec=infinity' "$UNIT" &&
  grep -Fxq 'ExecStart=/usr/lib/omarchy/initcpio/omarchy-mac-encrypt' "$UNIT" ||
  fail "the initrd unit matches v3 ordering (udev settle + vendorfw-initrd, before cryptsetup-pre/sysroot)"
grep -Fxq 'StandardOutput=kmsg' "$UNIT" && grep -Fxq 'StandardError=kmsg' "$UNIT" &&
  grep -Fxq 'SyslogLevel=notice' "$UNIT" && ! grep -Eq '^(TTYPath|StandardInput)=' "$UNIT" ||
  fail "the initrd unit logs to the journal and kmsg (serial harness), never the console"
grep -Fxq 'After=plymouth-start.service' "$UNIT" ||
  fail "the initrd unit starts once the splash it reports progress on is up"
for binary in chroot grep mv cat mkdir chmod readlink stat sync date sleep; do
  grep -Eq "\b$binary\b" "$INSTALL" || fail "the install hook adds $binary (busybox is not guaranteed)"
done
! grep -Eq 'blockdev|dmsetup' "$INSTALL" || fail "the install hook adds nothing the script does not run"

grep -Fq 'omarchy-mac-encrypt' "$DROPIN" && grep -Fq 'sd-encrypt' "$DROPIN" ||
  fail "91-omarchy-mac-encrypt.conf mentions both hooks"

hooks_after() {
  HOOKS=("$@")
  # shellcheck disable=SC1090
  source "$DROPIN"
  printf '%s\n' "${HOOKS[*]}"
}
[[ $(hooks_after base systemd autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw filesystems fsck) == \
  "base systemd autodetect microcode modconf kms keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "the drop-in places omarchy-mac-encrypt and sd-encrypt after vendorfw and before filesystems"
[[ $(hooks_after base systemd block filesystems fsck) == "base systemd block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "without vendorfw the encrypt hooks still land before filesystems"
[[ $(hooks_after base systemd block sd-encrypt filesystems fsck) == \
  "base systemd block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "pre-existing sd-encrypt still gets omarchy-mac-encrypt before it"
[[ $(hooks_after base systemd block omarchy-mac-encrypt filesystems fsck) == \
  "base systemd block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "pre-existing omarchy-mac-encrypt still gets sd-encrypt before filesystems"
[[ $(hooks_after base systemd block omarchy-mac-encrypt sd-encrypt filesystems fsck) == \
  "base systemd block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "both hooks already present must not be duplicated"
[[ $(hooks_after base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck) == \
  "base systemd autodetect microcode modconf kms keyboard sd-vconsole block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "the stock mkinitcpio HOOKS line is moved to the systemd hook (udev→systemd, keymap/consolefont→sd-vconsole)"
[[ $(hooks_after base autodetect block filesystems) == "base systemd autodetect block omarchy-mac-encrypt sd-encrypt filesystems" ]] ||
  fail "a HOOKS line without udev still gets the systemd hook after base"
[[ $(hooks_after base udev autodetect keyboard keymap block encrypt filesystems fsck) == \
  "base udev autodetect keyboard keymap block encrypt filesystems fsck" ]] ||
  fail "a cryptdevice= Mac (busybox encrypt hook) keeps its HOOKS line untouched"
for platform in qualcomm generic-aarch64 generic ""; do
  [[ $(OMARCHY_TEST_HW_PLATFORM=$platform hooks_after base udev autodetect keyboard keymap block filesystems fsck) == \
    "base udev autodetect keyboard keymap block filesystems fsck" ]] ||
    fail "the drop-in leaves HOOKS alone off Apple Silicon (detector: ${platform:-empty})"
done
if OMARCHY_TEST_HW_PLATFORM=fail bash -c 'HOOKS=(base systemd block filesystems); source "$1"' _ "$DROPIN"; then
  fail "a detector that cannot place the machine stops the build"
fi
[[ $(PATH=/nonexistent hooks_after base udev autodetect keyboard keymap block filesystems fsck) == \
  "base systemd autodetect keyboard sd-vconsole block omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "a runtime without the detector keeps the Apple hooks"
[[ $(OMARCHY_TEST_HW_PLATFORM=generic-aarch64 hooks_after base systemd block asahi omarchy-vendorfw filesystems fsck) == \
  "base systemd block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck" ]] ||
  fail "the asahi hook marks an Apple root off a Mac, as the baseline has it"

grep -Fq 'cryptsetup reencrypt --encrypt' "$SCRIPT" &&
  grep -Fq -- '--reduce-device-size' "$SCRIPT" && grep -Fq -- '--device-size' "$SCRIPT" &&
  grep -Fq -- '--resilience checksum' "$SCRIPT" && grep -Fq -- '--resume-only' "$SCRIPT" ||
  fail "the script runs foreground LUKS2 reencrypt with the contracted flags"
grep -Fq 'btrfs filesystem usage -b' "$SCRIPT" || fail "extent comes from btrfs filesystem usage -b"
! grep -Fq 'findmnt -bno SIZE' "$SCRIPT" || fail "extent must not use findmnt heuristics"
! grep -Fq 'part - fs' "$SCRIPT" || fail "shrink must not skip when spare partition space exists"
grep -Fq 'btrfs filesystem resize "-$REDUCE"' "$SCRIPT" || fail "shrink is always -32M"
grep -Fq 'update-grub' "$SCRIPT" && grep -Fq '/usr/bin/mkinitcpio -P' "$SCRIPT" ||
  fail "a GRUB Mac regenerates GRUB the way the fresh installer does, then mkinitcpio -P"
grep -Fq 'limine.enabled' "$SCRIPT" &&
  grep -Fq 'OMARCHY_MAC_BOOT_UPDATE_GRUB=0 chroot "$ROOT_MNT" omarchy-mac-boot-update' "$SCRIPT" ||
  fail "a Limine Mac only rebuilds its UKI (limine.enabled + omarchy-mac-boot-update without GRUB)"
grep -Fq -- '--progress-json' "$SCRIPT" && grep -Fq 'omarchy_mac_encrypt_follow_reencrypt' "$SCRIPT" ||
  fail "the reencrypt progress is read from cryptsetup --progress-json"
GATE_HOOK=$FILES/etc/boot/hooks/pre.d/05-omarchy-mac-limine-gate
GATE_HELPER=$FILES/usr/lib/omarchy/mac-boot/limine-ready
[[ -x $GATE_HOOK && -x $GATE_HELPER ]] && grep -Fq '/usr/lib/omarchy/mac-boot/limine-ready' "$GATE_HOOK" &&
  grep -Fq 'exit 100' "$GATE_HELPER" && grep -Fq 'limine.enabled' "$GATE_HELPER" && grep -Fq '/etc/default/limine' "$GATE_HELPER" ||
  fail "the pre hook shares the early package activation gate"
grep -Fq 'rd.luks.key=' "$SCRIPT" && grep -Fq "UUID=$BOOT_UUID" "$SCRIPT" &&
  grep -Fq 'rd.luks.name=' "$SCRIPT" && ! grep -Fq 'root=/dev/mapper/root' "$SCRIPT" ||
  fail "the GRUB cmdline names the mapper, the LUKS UUID and the Boot-partition key"
grep -Fq 'root UUID=' "$SCRIPT" && grep -Fq 'none luks' "$SCRIPT" ||
  fail "crypttab is root UUID=<luks uuid> none luks (the key rides on the cmdline until re-key)"
grep -Fq 'PROVISIONING_DIR=/var/lib/omarchy/provisioning' "$SCRIPT" ||
  fail "the throwaway key is copied to the provisioning dir"
grep -Fq 'encrypt.state' "$SCRIPT" &&
  grep -Fq 'declined|plaintext|shrunk|reencrypting|encrypted|configured|rekeyed|finished' "$SCRIPT" ||
  fail "transaction state is /boot/omarchy/encrypt.state"
! grep -Fq 'encrypt-pending' "$SCRIPT" || fail "v3 has no encrypt-pending marker"
grep -Fq 'sysroot.mount.d' "$SCRIPT" && grep -Fq 'What=/dev/mapper/root' "$SCRIPT" &&
  grep -Fq 'Requires=dev-mapper-root.device' "$SCRIPT" &&
  grep -Fq 'systemctl daemon-reload' "$SCRIPT" ||
  fail "sysroot is repointed by a drop-in + daemon-reload"
! grep -E '^[[:space:]]*mount[[:space:]]+--move' "$SCRIPT" ||
  fail "sysroot continuation must not relocate /sysroot with mount"
! grep -Eq 'btrfs filesystem resize (max|1:max)' "$SCRIPT" ||
  fail "the script leaves btrfs growfs to x-systemd.growfs"
grep -Fq 'by-partuuid' "$SCRIPT" && grep -Fq 'PARTLABEL' "$SCRIPT" &&
  grep -Fq 'OMARCHY_ROOT' "$SCRIPT" && grep -Fq 'UUID=*)' "$SCRIPT" && grep -Fq 'rd.luks.name=' "$SCRIPT" ||
  fail "root is resolved by encrypt.state PARTUUID, root=UUID= (the image cmdline), rd.luks.name= or label OMARCHY_ROOT"
! grep -Fq 'OMARCHY_MAC_ENCRYPT_ROOT' "$SCRIPT" ||
  fail "tests must not inject OMARCHY_MAC_ENCRYPT_ROOT; the script must not honour it"
! grep -Fq 'dmsetup remove -f' "$SCRIPT" || fail "must not force-remove a mapper with dmsetup -f"
grep -Fq 'refusing to encrypt a mounted filesystem' "$SCRIPT" ||
  fail "a failed plaintext unmount must abort"
grep -Fq -- '--rbind' "$SCRIPT" && grep -Fq -- '--make-rslave' "$SCRIPT" ||
  fail "chroot bind-mounts API filesystems recursively"
grep -Fq 'Boot partition node is absent' "$SCRIPT" ||
  fail "chroot/boot setup fails when the Boot node is absent"
KEYDEV_DROPIN=$FILES/usr/lib/omarchy/initcpio/omarchy-mac-encrypt-keydev.conf
grep -Fxq 'After=omarchy-mac-encrypt.service' "$KEYDEV_DROPIN" &&
  grep -Fq 'run-systemd-cryptsetup-keydev\x2droot.mount.d/' "$INSTALL" &&
  grep -Fq 'omarchy-mac-encrypt-keydev.conf' "$INSTALL" ||
  fail "the sd-encrypt key-device mount of the Boot partition is ordered after the unit"
grep -Fq 'dir=$mnt/var/lib/omarchy/mac-first-boot' "$SCRIPT" &&
  grep -Fq '[[ -f $dir/pending && -f $dir/deferred-steps ]] || fresh=0' "$SCRIPT" &&
  [[ $(grep -v '^[[:space:]]*#' "$SCRIPT") != *omarchy/image* ]] ||
  fail "a fresh image is the first-boot marker with its conversion token, never the image hardware queue a reset restores"
echo 'ok - script, unit and drop-in match INTERFACES §5 T4a v3'

# systemd ignores a setting it cannot parse and still exits 0, so any output
# fails. Emulated containers cannot verify even a trivial unit; skip there.
if command -v systemd-analyze >/dev/null; then
  verify_root=$(mktemp -d)
  verify_units=$verify_root/usr/lib/systemd/system
  install -D -m 755 "$SCRIPT" "$verify_root/usr/lib/omarchy/initcpio/omarchy-mac-encrypt"
  install -D -m 644 "$UNIT" "$verify_units/omarchy-mac-encrypt.service"
  printf '[Unit]\nDefaultDependencies=no\n[Service]\nType=oneshot\nExecStart=/usr/lib/omarchy/initcpio/omarchy-mac-encrypt\n' \
    >"$verify_units/probe.service"
  verify_out=""
  if probe_out=$(systemd-analyze verify --man=no --root="$verify_root" "$verify_units/probe.service" 2>&1) && [[ -z $probe_out ]]; then
    verify_out=$(systemd-analyze verify --man=no --root="$verify_root" "$verify_units/omarchy-mac-encrypt.service" 2>&1) ||
      verify_out+=$'\n'"exit $?"
    verified=true
  else
    verified=false
  fi
  rm -rf "$verify_root"
  if [[ $verified == "true" ]]; then
    [[ -z $verify_out ]] || fail "systemd-analyze verify accepts the initrd unit: $verify_out"
    echo 'ok - systemd-analyze verify accepts the initrd unit'
  else
    echo 'ok - systemd-analyze cannot verify units here; unit verification not run'
  fi
fi

# ── splash progress ────────────────────────────────────────────────────────
# A stub plymouth records what the splash is told; the follower turns
# cryptsetup's JSON progress into the bar and the line under it.
progress_tmp=$(mktemp -d)
mkdir -p "$progress_tmp/bin"
cat >"$progress_tmp/bin/plymouth" <<'STUB'
#!/bin/bash
if [[ $1 == --ping ]]; then
  [[ ! -e $PROGRESS_TMP/no-splash ]]
  exit
fi
printf '%s\n' "$*" >>"$PROGRESS_TMP/plymouth.log"
STUB
printf '#!/bin/bash\n' >"$progress_tmp/bin/sleep"
chmod +x "$progress_tmp/bin/plymouth" "$progress_tmp/bin/sleep"
with_splash() {
  PROGRESS_TMP=$progress_tmp PATH="$progress_tmp/bin:$PATH" OMARCHY_MAC_ENCRYPT_PROGRESS_FILE="$progress_tmp/progress" \
    bash -c 'set -euo pipefail; source "$1"; PROGRESS_CREEP=""; eval "$2"' bash "$SCRIPT" "$1"
}
json() {
  printf '{"device":"/dev/nvme0n1p6","device_bytes":"%s","device_size":"%s","speed":"659554304","eta_ms":"1","time_ms":"2"}\n' "$1" "$2"
}
follow_out=$( { json 0 1000; json 424 1000; json 425 1000; json 430 1000; echo 'a line that is not progress'; json 1000 1000; } |
  with_splash omarchy_mac_encrypt_follow_reencrypt) || fail "the progress follower never fails the pipeline"
[[ $follow_out == 'a line that is not progress' ]] ||
  fail "JSON progress is consumed and other cryptsetup output passes through: $follow_out"
[[ $(cat "$progress_tmp/plymouth.log") == $'system-update --progress=0\nsystem-update --progress=16\nsystem-update --progress=17\nsystem-update --progress=40' ]] ||
  fail "the encryption moves the bar across 0-40% and leaves the line alone: $(cat "$progress_tmp/plymouth.log")"
[[ $(<"$progress_tmp/progress") == 40 ]] || fail "the progress file keeps the last value for first boot"
rm -f "$progress_tmp/plymouth.log"
: >"$progress_tmp/no-splash"
{ json 500 1000; json 1000 1000; } | with_splash omarchy_mac_encrypt_follow_reencrypt >/dev/null ||
  fail "the follower runs without a splash"
with_splash 'omarchy_mac_encrypt_progress_creep 42 52; omarchy_mac_encrypt_progress_creep_stop' ||
  fail "the creep is a no-op without a splash"
[[ ! -e $progress_tmp/plymouth.log ]] || fail "without a running splash nothing is sent to it"
rm -f "$progress_tmp/no-splash"
# A reader that stops early would close the pipe on cryptsetup mid-conversion.
{
  printf 'garbage {"device_bytes":"x"}\n'
  json 5 0
  json 1 3
  for _ in $(seq 2000); do json 1 2; done
} | with_splash omarchy_mac_encrypt_follow_reencrypt >/dev/null || fail "the follower reads to the end whatever it is given"
rm -f "$progress_tmp/plymouth.log"
with_splash 'omarchy_mac_encrypt_progress_creep 42 52; wait "$PROGRESS_CREEP"; omarchy_mac_encrypt_progress_creep_stop' ||
  fail "the creep runs and stops"
[[ $(sed -n 's/^system-update --progress=//p' "$progress_tmp/plymouth.log" | tr '\n' ' ') == '45 47 49 50 51 52 ' ]] ||
  fail "the creep eases the bar to the end of its band: $(tr '\n' ' ' <"$progress_tmp/plymouth.log")"
rm -rf "$progress_tmp"
echo 'ok - cryptsetup JSON progress drives the splash bar and its line; nothing is sent without a splash'

if [[ ${OMARCHY_DISPOSABLE_BOOT_TESTS:-0} != "1" && ${OMARCHY_MAC_ENCRYPT_TEST_INNER:-0} != "1" ]]; then
  echo 'ok - source checks passed; disposable initramfs/block tests not run (OMARCHY_DISPOSABLE_BOOT_TESTS=1 opts in)'
  exit 0
fi

linux_block_ready() {
  [[ -e /dev/loop-control && -w /dev/loop-control ]] &&
    command -v losetup >/dev/null && command -v cryptsetup >/dev/null &&
    command -v mkfs.btrfs >/dev/null && command -v mkfs.vfat >/dev/null &&
    command -v mkfs.ext4 >/dev/null && command -v findmnt >/dev/null &&
    command -v sgdisk >/dev/null && command -v kpartx >/dev/null
}

run_in_arch_container() {
  command -v docker >/dev/null || return 1
  docker info >/dev/null 2>&1 || return 1
  docker run --rm --privileged --platform linux/amd64 \
    -e OMARCHY_MAC_ENCRYPT_TEST_INNER=1 -e TMPDIR=/var/tmp \
    -v "$ROOT:/repo" -w /repo archlinux:latest bash -lc '
      set -euo pipefail
      pacman --disable-sandbox -Sy --noconfirm --needed cryptsetup btrfs-progs e2fsprogs util-linux dosfstools procps-ng gptfdisk multipath-tools >/dev/null
      bash test/mac-encrypt-test.sh
    '
}

if [[ ${OMARCHY_MAC_ENCRYPT_TEST_INNER:-} != 1 ]] && ! linux_block_ready; then
  echo 'omarchy-mac-encrypt: host has no loop/cryptsetup; trying a privileged archlinux container' >&2
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    run_in_arch_container
    exit $?
  fi
  echo "skipped: loop devices, cryptsetup and privileged docker are unavailable" >&2
  exit 1
fi

linux_block_ready || fail "inner run still lacks loop devices and cryptsetup"
# A run killed mid-way leaves loop devices carrying the fixture UUIDs and
# labels on the host; the script would then resolve those instead of ours.
stale=$(for tag in UUID=4F4D-5801 "UUID=$BOOT_UUID" LABEL=OMARCHY_ROOT PARTLABEL=OMARCHY_ROOT; do
  blkid -c /dev/null -t "$tag" -o device 2>/dev/null || true
done)
[[ -z $stale ]] || fail "stale fixture devices on this host (detach them first): $(printf '%s ' $stale)"
for i in $(seq 0 63); do
  [[ -e /dev/loop$i ]] || mknod /dev/loop$i b 7 "$i" 2>/dev/null || true
done

tmp=$(mktemp -d "${TMPDIR:-/var/tmp}/omarchy-mac-encrypt.XXXXXX")
loops=()
kpartx_disks=()
bg_pids=()
gpt_links=()
cleanup() {
  local pid loop mnt link disk
  for pid in "${bg_pids[@]+"${bg_pids[@]}"}"; do
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cryptsetup close root 2>/dev/null || true
  for mnt in "$tmp"/mnt-*; do
    [[ -d $mnt ]] || continue
    umount -R "$mnt" 2>/dev/null || umount "$mnt" 2>/dev/null || true
  done
  for disk in "${kpartx_disks[@]+"${kpartx_disks[@]}"}"; do
    kpartx -d "$disk" >/dev/null 2>&1 || true
  done
  for loop in "${loops[@]+"${loops[@]}"}"; do
    losetup -d "$loop" 2>/dev/null || true
  done
  for link in "${gpt_links[@]+"${gpt_links[@]}"}"; do
    [[ -L $link ]] || continue
    rm -f "$link"
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

track_pid() {
  bg_pids+=("$1")
}

forget_pid() {
  local pid=$1 i
  local kept=()
  for i in "${bg_pids[@]+"${bg_pids[@]}"}"; do
    [[ $i == "$pid" ]] || kept+=("$i")
  done
  bg_pids=("${kept[@]+"${kept[@]}"}")
}

attach_loop() {
  local img=$1
  ATTACHED_LOOP=$(losetup --find --show --sector-size 512 "$img")
  loops+=("$ATTACHED_LOOP")
}

detach_loop() {
  local loop=$1 i
  losetup -d "$loop" 2>/dev/null || true
  local kept=()
  for i in "${loops[@]+"${loops[@]}"}"; do
    [[ $i == "$loop" ]] || kept+=("$i")
  done
  loops=("${kept[@]+"${kept[@]}"}")
}

unpublish_part() {
  local part=$1 uuid
  uuid=$(blkid -c /dev/null -o value -s PARTUUID "$part" 2>/dev/null || true)
  if [[ -n $uuid && -L /dev/disk/by-partuuid/$uuid ]]; then
    rm -f "/dev/disk/by-partuuid/$uuid"
  fi
  if [[ -L /dev/disk/by-partlabel/OMARCHY_ROOT ]] &&
     [[ $(readlink -f /dev/disk/by-partlabel/OMARCHY_ROOT) == $(readlink -f "$part") ]]; then
    rm -f /dev/disk/by-partlabel/OMARCHY_ROOT
  fi
}

publish_part() {
  local part=$1
  ROOT_PARTUUID=$(blkid -c /dev/null -o value -s PARTUUID "$part")
  [[ -n $ROOT_PARTUUID ]] || fail "partition $part has no PARTUUID"
  [[ -z $(blkid -c /dev/null -o value -s PARTLABEL "$part") ]] ||
    fail "the fixture must not carry a GPT label: real installs have none"
  mkdir -p /dev/disk/by-partuuid 2>/dev/null || true
  ln -sfn "$part" "/dev/disk/by-partuuid/$ROOT_PARTUUID" 2>/dev/null || true
  gpt_links+=("/dev/disk/by-partuuid/$ROOT_PARTUUID")
}

# The image boots with root=UUID=<btrfs uuid>; the script reads that from
# OMARCHY_MAC_ENCRYPT_CMDLINE here instead of /proc/cmdline.
set_cmdline() {
  printf '%s\n' "$*" >"$tmp/cmdline"
}

cmdline_for_part() {
  local part=$1 uuid
  uuid=$(blkid -c /dev/null -o value -s UUID "$part")
  [[ -n $uuid ]] || fail "partition $part has no filesystem UUID"
  set_cmdline "quiet root=UUID=$uuid rw"
}

wait_part() {
  local part=$1 i
  for i in $(seq 1 50); do
    [[ -b $part ]] && return 0
    sleep 0.1
  done
  return 1
}

make_root_disk() {
  local img=$1 megas=${2:-384} byte_count=${3:-} map
  dd if=/dev/zero of="$img" bs=1M count="$megas" status=none
  sgdisk -n 1:2048:0 -t 1:8300 "$img" >/dev/null
  attach_loop "$img"
  ROOT_DISK=$ATTACHED_LOOP
  kpartx -av "$ROOT_DISK" >/dev/null
  kpartx_disks+=("$ROOT_DISK")
  map=${ROOT_DISK##*/}p1
  ROOT_PART=/dev/mapper/$map
  wait_part "$ROOT_PART" || fail "GPT partition node missing for $ROOT_DISK ($ROOT_PART)"
  if [[ -n $byte_count ]]; then
    mkfs.btrfs -q -f --byte-count "$byte_count" "$ROOT_PART"
  else
    mkfs.btrfs -q -f "$ROOT_PART"
  fi
  publish_part "$ROOT_PART"
  cmdline_for_part "$ROOT_PART"
}

drop_root_disk() {
  local kept=() disk
  cryptsetup close root 2>/dev/null || true
  [[ -n ${ROOT_PART:-} ]] && unpublish_part "$ROOT_PART"
  if [[ -n ${ROOT_DISK:-} ]]; then
    kpartx -d "$ROOT_DISK" >/dev/null 2>&1 || true
    for disk in "${kpartx_disks[@]+"${kpartx_disks[@]}"}"; do
      [[ $disk == "$ROOT_DISK" ]] || kept+=("$disk")
    done
    kpartx_disks=("${kept[@]+"${kept[@]}"}")
    detach_loop "$ROOT_DISK"
  fi
  ROOT_PART=""
  ROOT_DISK=""
  ROOT_PARTUUID=""
}

write_state() {
  local boot=$1 phase=$2 part=${3:-unknown} uuid=${4:-}
  mkdir -p "$boot/omarchy"
  printf 'format=1\nphase=%s\npartition=%s\nluks_uuid=%s\n' "$phase" "$part" "$uuid" >"$boot/omarchy/encrypt.state"
}

make_esp() {
  local img=$tmp/esp.img
  dd if=/dev/zero of="$img" bs=1M count=32 status=none
  mkfs.vfat -F 32 -i 4F4D5801 "$img" >/dev/null 2>&1
  attach_loop "$img"
  ESP_LOOP=$ATTACHED_LOOP
  ESP_MNT=$tmp/mnt-esp
  mkdir -p "$ESP_MNT"
  mount "$ESP_LOOP" "$ESP_MNT"
  mkdir -p "$ESP_MNT/omarchy" "$ESP_MNT/EFI/BOOT"
}

make_boot() {
  local img=$tmp/boot.img
  dd if=/dev/zero of="$img" bs=1M count=64 status=none
  mkfs.ext4 -F -q -U "$BOOT_UUID" "$img"
  attach_loop "$img"
  BOOT_LOOP=$ATTACHED_LOOP
  BOOT_MNT=$tmp/mnt-boot
  mkdir -p "$BOOT_MNT"
  mount "$BOOT_LOOP" "$BOOT_MNT"
}

seed_chroot_shell() {
  local root=$1 bash_path tok real
  bash_path=$(command -v bash)
  mkdir -p "$root/usr/bin" "$root/bin"
  cp -a "$bash_path" "$root/usr/bin/bash"
  ln -sfn /usr/bin/bash "$root/bin/bash"
  ln -sfn bash "$root/bin/sh"
  ln -sfn bash "$root/usr/bin/sh"
  while read -r tok; do
    [[ $tok == /* ]] || continue
    real=$(readlink -f "$tok")
    [[ -f $real ]] || continue
    mkdir -p "$root$(dirname "$tok")" "$root$(dirname "$real")"
    [[ -e $root$real ]] || cp -a "$real" "$root$real"
    if [[ $tok != "$real" && ! -e $root$tok ]]; then
      ln -sfn "$real" "$root$tok"
    fi
  done < <(ldd "$bash_path" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }')
}

populate_root() {
  local mnt=$1
  btrfs subvolume create "$mnt/@" >/dev/null
  mkdir -p "$mnt/@/var/lib/omarchy/mac-first-boot" "$mnt/@/var/lib/omarchy/provisioning" \
    "$mnt/@/etc/default" "$mnt/@/usr/bin" "$mnt/@/boot/efi" "$mnt/@/root" \
    "$mnt/@/proc" "$mnt/@/sys" "$mnt/@/dev" "$mnt/@/run"
  # The image arms the first-boot marker and ships the deferred hardware
  # steps; the unit encrypts nothing without both.
  : >"$mnt/@/var/lib/omarchy/mac-first-boot/pending"
  printf 'hardware/apple/example.sh\n' >"$mnt/@/var/lib/omarchy/mac-first-boot/deferred-steps"
  seed_chroot_shell "$mnt/@"
  printf 'GRUB_CMDLINE_LINUX=""\n' >"$mnt/@/etc/default/grub"
  printf 'UUID=4f4d5801-524f-4f54-8000-000000000001 / btrfs subvol=@,x-systemd.growfs 0 0\n' \
    >"$mnt/@/etc/fstab"
  printf 'payload-one\n' >"$mnt/@/root/one"
  dd if=/dev/urandom of="$mnt/@/root/blob" bs=1M count=4 status=none
  cat >"$mnt/@/usr/bin/update-grub" <<'STUB'
#!/bin/bash
echo "update-grub $*" >>/var/lib/omarchy/mac-first-boot/boot.log
# asahi-scripts update-grub copies core.efi to /boot/efi/EFI/BOOT/BOOTAA64.EFI
: >/boot/efi/EFI/BOOT/update-grub.probe
STUB
  cat >"$mnt/@/usr/bin/mkinitcpio" <<'STUB'
#!/bin/bash
echo "mkinitcpio $*" >>/var/lib/omarchy/mac-first-boot/boot.log
STUB
  # A Limine Mac: the gate, Limine's defaults and the Omarchy rebuild command.
  mkdir -p "$mnt/@/var/lib/omarchy" "$mnt/@/etc/default"
  : >"$mnt/@/var/lib/omarchy/limine.enabled"
  printf 'KERNEL_CMDLINE[default]=""\n' >"$mnt/@/etc/default/limine"
  cat >"$mnt/@/usr/bin/omarchy-mac-boot-update" <<'STUB'
#!/bin/bash
echo "omarchy-mac-boot-update grub=${OMARCHY_MAC_BOOT_UPDATE_GRUB:-} $*" >>/var/lib/omarchy/mac-first-boot/boot.log
# limine-update writes the UKI and limine.conf to the ESP
: >/boot/efi/EFI/BOOT/boot-update.probe
STUB
  chmod 755 "$mnt/@/usr/bin/update-grub" "$mnt/@/usr/bin/mkinitcpio" "$mnt/@/usr/bin/omarchy-mac-boot-update"
}

hash_tree() {
  local mnt=$1
  (cd "$mnt/root" && sha256sum one blob | sort)
}

REAL_CRYPTSETUP=$(command -v cryptsetup)
mkdir -p "$tmp/bin"
cat >"$tmp/bin/cryptsetup" <<EOF
#!/bin/bash
printf 'cryptsetup %s\\n' "\$*" >>"$tmp/cryptsetup.log"
if [[ \$1 == reencrypt ]]; then
  printf '%s\\n' "\$\$" >"$tmp/cryptsetup.reencrypt.pid"
fi
exec "$REAL_CRYPTSETUP" "\$@"
EOF
chmod +x "$tmp/bin/cryptsetup"
cat >"$tmp/bin/plymouth" <<EOF
#!/bin/bash
[[ \$1 != --ping ]] || exit 0
printf '%s\\n' "\$*" >>"$tmp/plymouth.log"
EOF
chmod +x "$tmp/bin/plymouth"
export PATH="$tmp/bin:$PATH"
export OMARCHY_MAC_ENCRYPT_PROGRESS_FILE="$tmp/progress"
: >"$tmp/cryptsetup.log"

export OMARCHY_MAC_ENCRYPT_CMDLINE="$tmp/cmdline"
set_cmdline "quiet rw"

run_script() {
  case_dir=$tmp/run
  mkdir -p "$case_dir" "$tmp/systemd"
  cryptsetup close root 2>/dev/null || true
  OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" \
    OMARCHY_MAC_ENCRYPT_BOOT="$boot_mnt" \
    OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
    bash "$SCRIPT" >"$case_dir/out" 2>&1
}

resolve_root_dev() {
  bash -c 'source "$1"; STATE_PARTITION=""; ROOT_DEV=""; omarchy_mac_encrypt_resolve_root; printf "%s\n" "$ROOT_DEV"' \
    bash "$SCRIPT" 2>/dev/null
}

make_esp
make_boot
esp_mnt=$ESP_MNT
boot_mnt=$BOOT_MNT
[[ $(blkid -c /dev/null -o value -s TYPE "$BOOT_LOOP") == ext4 ]] || fail "Boot fixture is ext4"
[[ $(blkid -c /dev/null -o value -s UUID "$BOOT_LOOP") == "$BOOT_UUID" ]] || fail "Boot fixture UUID"
echo 'ok - Boot ext4 fixture'

# malformed install.conf stops before any mutation
printf 'format=2\nencrypt=1\n' >"$esp_mnt/omarchy/install.conf"
if run_script; then
  fail "format≠1 must stop the boot"
fi
grep -Fq "format must be 1" "$case_dir/out" || fail "format≠1 names the refusal"
[[ ! -e $boot_mnt/omarchy/encrypt.state ]] || fail "malformed conf must not write state"
echo 'ok - format≠1 stops the boot'

printf 'format=1\nencrypt=maybe\n' >"$esp_mnt/omarchy/install.conf"
if run_script; then
  fail "unknown encrypt must stop the boot"
fi
grep -Fq "encrypt must be 0 or 1" "$case_dir/out" || fail "unknown encrypt names the refusal"
echo 'ok - unknown encrypt value stops the boot'

printf 'format=1\nencrypt=0\n' >"$esp_mnt/omarchy/install.conf"
dd if=/dev/zero of="$tmp/plain0.img" bs=1M count=128 status=none
mkfs.btrfs -q "$tmp/plain0.img"
attach_loop "$tmp/plain0.img"
plain0=$ATTACHED_LOOP
run_script || fail "encrypt=0 should succeed as a no-op"
[[ $(blkid -o value -s TYPE "$plain0") == btrfs ]] || fail "encrypt=0 left the filesystem as btrfs"
grep -Fq 'encrypt=0' "$case_dir/out" || fail "encrypt=0 named the skip"
[[ $(cat "$boot_mnt/omarchy/encrypt.state") == $'format=1\nphase=declined\npartition=unknown\nluks_uuid=' ]] ||
  fail "encrypt=0 records phase=declined on the Boot partition"
[[ ! -e $boot_mnt/omarchy/luks-key ]] || fail "encrypt=0 never writes the throwaway key"
echo 'ok - encrypt=0 never encrypts and records the decline'
detach_loop "$plain0"

# a factory reset scrubs install.conf and re-arms the first-boot marker: the
# recorded decline must still win, whatever the ESP and the root say
rm -f "$esp_mnt/omarchy/install.conf"
make_root_disk "$tmp/declined.img" 256
mkdir -p "$tmp/mnt-declined"
mount "$ROOT_PART" "$tmp/mnt-declined"
populate_root "$tmp/mnt-declined"
umount "$tmp/mnt-declined"
run_script || fail "a declined Mac stays a no-op"
grep -Fq 'declined at install time' "$case_dir/out" || fail "the recorded decline is named"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "a declined Mac is never encrypted after a reset"
[[ ! -e $boot_mnt/omarchy/luks-key ]] || fail "a declined Mac gets no throwaway key"
grep -Fq 'phase=declined' "$boot_mnt/omarchy/encrypt.state" || fail "the decline record is kept"
echo 'ok - phase=declined outlives install.conf and a factory reset'
drop_root_disk
rm -f "$boot_mnt/omarchy/encrypt.state"

# no Boot partition: an installed Mac with its own layout is left alone, a
# fresh image with a missing Boot is an error (no journal to encrypt with)
case_dir=$tmp/run
mkdir -p "$case_dir"
OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
  bash "$SCRIPT" >"$case_dir/out" 2>&1 || fail "an absent Boot partition on a non-fresh Mac must not halt the boot"
grep -Fq 'Boot partition node' "$case_dir/out" || fail "the absent Boot node is named"
grep -Fq 'leaving the root alone' "$case_dir/out" || fail "an absent Boot partition on a non-fresh Mac is a no-op"
echo 'ok - absent Boot partition node leaves a non-fresh Mac alone'
make_root_disk "$tmp/noboot-installed.img" 256
mkdir -p "$tmp/mnt-noboot"
mount "$ROOT_PART" "$tmp/mnt-noboot"
populate_root "$tmp/mnt-noboot"
rm -f "$tmp/mnt-noboot/@/var/lib/omarchy/mac-first-boot/pending" "$tmp/mnt-noboot/@/var/lib/omarchy/mac-first-boot/deferred-steps"
umount "$tmp/mnt-noboot"
OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
  bash "$SCRIPT" >"$case_dir/out" 2>&1 || fail "an installed Mac's plaintext root with no Boot partition must not halt the boot"
grep -Fq 'leaving the root alone' "$case_dir/out" || fail "the installed Mac without Boot is left alone"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "the installed Mac without Boot is never encrypted"
findmnt /run/omarchy-mac-encrypt/probe >/dev/null 2>&1 && fail "the probe mount is released when Boot is absent"
echo 'ok - an installed plaintext root without a Boot partition is left alone'
drop_root_disk
make_root_disk "$tmp/noboot-luks.img" 128
dd if=/dev/urandom of="$tmp/noboot.key" bs=64 count=1 status=none
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$tmp/noboot.key" "$ROOT_PART"
set_cmdline "rd.luks.name=$(cryptsetup luksUUID "$ROOT_PART")=root root=UUID=4f4d5801-524f-4f54-8000-000000000001 rw"
if OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
     bash "$SCRIPT" >"$case_dir/out" 2>&1; then
  fail "a LUKS root whose Boot partition is missing must say so, not die later at sysroot.mount"
fi
grep -Fq 'journal and key are unreachable' "$case_dir/out" || fail "the unreachable journal is named"
echo 'ok - a LUKS root without its Boot partition stops with a clear message'
drop_root_disk

# A legacy Mac the quattro guided installer encrypted, migrated to sd-encrypt:
# it has neither the image's ESP nor its Boot partition, and its passphrase
# unlocks the root. The unit leaves it alone and never touches the header.
umount "$esp_mnt" "$boot_mnt"
detach_loop "$ESP_LOOP"
detach_loop "$BOOT_LOOP"
make_root_disk "$tmp/legacy-luks.img" 128
printf 'legacy-passphrase' >"$tmp/legacy.pass"
cryptsetup luksFormat --type luks2 --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$tmp/legacy.pass" "$ROOT_PART"
legacy_header=$(dd if="$ROOT_PART" bs=1M count=16 status=none | sha256sum)
set_cmdline "root=UUID=0a1b2c3d-4e5f-4061-8a9b-c0d1e2f3a4b5 rw rootflags=subvol=@ rd.luks.name=$(cryptsetup luksUUID "$ROOT_PART")=root loglevel=3 quiet splash"
: >"$tmp/cryptsetup.log"
OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" bash "$SCRIPT" >"$case_dir/out" 2>&1 ||
  fail "a migrated legacy Mac's LUKS root without the image's partitions must boot on to its passphrase prompt"
grep -Fq "neither the image's ESP nor its Boot partition; leaving unlock to sd-encrypt" "$case_dir/out" || fail "the migrated legacy Mac is left to sd-encrypt"
! grep -v '^cryptsetup isLuks ' "$tmp/cryptsetup.log" && [[ $(dd if="$ROOT_PART" bs=1M count=16 status=none | sha256sum) == "$legacy_header" ]] ||
  fail "the migrated legacy Mac's LUKS header is never touched"
cryptsetup open --test-passphrase --key-file "$tmp/legacy.pass" "$ROOT_PART" || fail "its passphrase still opens it"
echo 'ok - a migrated legacy LUKS root without the image ESP and Boot is left to sd-encrypt'
drop_root_disk
attach_loop "$tmp/esp.img"
ESP_LOOP=$ATTACHED_LOOP
mount "$ESP_LOOP" "$esp_mnt"
attach_loop "$tmp/boot.img"
BOOT_LOOP=$ATTACHED_LOOP
mount "$BOOT_LOOP" "$boot_mnt"
make_root_disk "$tmp/noboot.img" 256
mkdir -p "$tmp/mnt-noboot"
mount "$ROOT_PART" "$tmp/mnt-noboot"
populate_root "$tmp/mnt-noboot"
umount "$tmp/mnt-noboot"
if OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
     bash "$SCRIPT" >"$case_dir/out" 2>&1; then
  fail "a fresh image without its Boot partition must fail"
fi
grep -Fq 'unusable on a fresh image' "$case_dir/out" || fail "the fresh image's missing Boot is named"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "nothing is encrypted without the journal"
echo 'ok - a fresh image without its Boot partition stops with a clear message'
drop_root_disk

if ROOT_MNT=$tmp/mnt-chroot-missing ESP_MNT=$esp_mnt BOOT_MNT= \
     bash -c 'source "$1"; mkdir -p "$ROOT_MNT"; omarchy_mac_encrypt_bind_chroot' bash "$SCRIPT" \
     >"$tmp/chroot-out" 2>&1; then
  fail "chroot without Boot mounted must fail"
fi
grep -Fq 'Boot partition is not mounted' "$tmp/chroot-out" ||
  fail "chroot names the missing Boot mount"
echo 'ok - chroot fails when Boot is not mounted'

# no state + crypto_LUKS is inconsistent (decisions by state, not crypto_LUKS alone)
printf 'format=1\nencrypt=1\n' >"$esp_mnt/omarchy/install.conf"
make_root_disk "$tmp/luks.img" 128
dd if=/dev/urandom of="$tmp/luks.key" bs=64 count=1 status=none
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$tmp/luks.key" "$ROOT_PART"
rm -f "$boot_mnt/omarchy/encrypt.state" "$boot_mnt/omarchy/luks-key"
# A long-encrypted Mac whose Boot partition was rebuilt: its cmdline names the
# container, root=UUID= names a btrfs UUID that is now inside LUKS. The unit
# must not halt it.
set_cmdline "rd.luks.name=$(cryptsetup luksUUID "$ROOT_PART")=root root=UUID=4f4d5801-524f-4f54-8000-000000000001 rw"
[[ $(resolve_root_dev) == "$(readlink -f "$ROOT_PART")" ]] ||
  fail "rd.luks.name= resolves the LUKS container when root=UUID= no longer exists"
run_script || fail "LUKS with no encrypt.state must defer to sd-encrypt, not stop"
grep -Fq 'leaving unlock to sd-encrypt' "$case_dir/out" || fail "no-state LUKS defers to sd-encrypt"
[[ ! -e /dev/mapper/root ]] || fail "no-state LUKS opens nothing itself"
echo 'ok - no state + crypto_LUKS defers to sd-encrypt'
drop_root_disk

# an installed Mac that gained the unit through an update: no state, no
# first-boot marker, no install.conf; it must be left exactly as it is
make_root_disk "$tmp/installed.img" 256
mkdir -p "$tmp/mnt-installed"
mount "$ROOT_PART" "$tmp/mnt-installed"
populate_root "$tmp/mnt-installed"
rm -f "$tmp/mnt-installed/@/var/lib/omarchy/mac-first-boot/pending"
installed_before=$(hash_tree "$tmp/mnt-installed/@")
umount "$tmp/mnt-installed"
rm -f "$esp_mnt/omarchy/install.conf" "$boot_mnt/omarchy/encrypt.state" "$boot_mnt/omarchy/luks-key"
run_script || fail "an installed Mac without the first-boot marker is a no-op"
grep -Fq 'no first-boot marker' "$case_dir/out" || fail "the missing marker is named"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "an installed Mac is never encrypted by an update"
[[ ! -e $boot_mnt/omarchy/encrypt.state ]] || fail "an installed Mac gets no encrypt.state"
[[ ! -e $boot_mnt/omarchy/luks-key ]] || fail "an installed Mac gets no throwaway key"
mount "$ROOT_PART" "$tmp/mnt-installed"
[[ $(hash_tree "$tmp/mnt-installed/@") == "$installed_before" ]] || fail "an installed Mac's files are untouched"
umount "$tmp/mnt-installed"
findmnt /run/omarchy-mac-encrypt/probe >/dev/null 2>&1 && fail "the marker probe mount is released"
echo 'ok - an installed Mac without the first-boot marker is left alone'
drop_root_disk

# a legacy first-boot marker migrated by the package scriptlet has no
# deferred-steps file: still not a fresh image
make_root_disk "$tmp/legacy.img" 256
mkdir -p "$tmp/mnt-legacy"
mount "$ROOT_PART" "$tmp/mnt-legacy"
populate_root "$tmp/mnt-legacy"
rm -f "$tmp/mnt-legacy/@/var/lib/omarchy/mac-first-boot/deferred-steps"
umount "$tmp/mnt-legacy"
run_script || fail "a migrated legacy marker without deferred steps is a no-op"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "a legacy Mac with only the marker is never encrypted"
[[ ! -e $boot_mnt/omarchy/encrypt.state ]] || fail "a legacy Mac gets no encrypt.state"
echo 'ok - a first-boot marker without the deferred steps file is not a fresh image'
drop_root_disk

# a factory reset re-arms the first-boot marker and @factory restores the
# image's hardware queue and its armed service, but not the conversion token:
# still not a fresh image
make_root_disk "$tmp/reset-queue.img" 256
mkdir -p "$tmp/mnt-reset-queue"
mount "$ROOT_PART" "$tmp/mnt-reset-queue"
populate_root "$tmp/mnt-reset-queue"
reset_root=$tmp/mnt-reset-queue/@
rm -f "$reset_root/var/lib/omarchy/mac-first-boot/deferred-steps"
mkdir -p "$reset_root/var/lib/omarchy/image" "$reset_root/etc/systemd/system/multi-user.target.wants"
printf 'format=1\nplatform=apple-silicon\n' >"$reset_root/var/lib/omarchy/image/target"
printf 'install/hardware/apple/limine-boot.sh\n' >"$reset_root/var/lib/omarchy/image/deferred-steps"
: >"$reset_root/etc/systemd/system/omarchy-provision-hardware.service"
ln -s /etc/systemd/system/omarchy-provision-hardware.service \
  "$reset_root/etc/systemd/system/multi-user.target.wants/omarchy-provision-hardware.service"
umount "$tmp/mnt-reset-queue"
run_script || fail "a reset root with a restored hardware queue is a no-op"
grep -Fq 'no encrypt.state and no first-boot marker with deferred steps: not a fresh image' "$case_dir/out" ||
  fail "a restored hardware queue is not taken for a fresh image"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "a reset root with a restored hardware queue is never encrypted"
[[ ! -e $boot_mnt/omarchy/encrypt.state ]] || fail "a reset root with a restored hardware queue gets no encrypt.state"
echo 'ok - a restored image hardware queue with a re-armed marker is not a fresh image'
drop_root_disk

# a root the probe cannot mount (no @ subvolume) is left alone, never halted
make_root_disk "$tmp/noat.img" 128
run_script || fail "an unprobeable root must not halt the boot"
grep -Fq 'could not mount the plaintext root read-only' "$case_dir/out" || fail "the failed probe is named"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] || fail "an unprobeable root is never encrypted"
[[ ! -e $boot_mnt/omarchy/encrypt.state ]] || fail "an unprobeable root gets no encrypt.state"
findmnt /run/omarchy-mac-encrypt/probe >/dev/null 2>&1 && fail "a failed probe leaves no mount behind"
echo 'ok - a root without an @ subvolume is left alone'
drop_root_disk

# the root must sit on the disk whose ESP was read, and never be a mapper node
mkdir -p "$tmp/stub-disk"
cat >"$tmp/stub-disk/lsblk" <<'STUB'
#!/bin/bash
dev=${@: -1}
case "$*" in
  *TYPE*) case $dev in /dev/mapper/*) echo crypt ;; /dev/nvme0n1) echo disk ;; *) echo part ;; esac ;;
  *PKNAME*) case $dev in /dev/sda*) echo sda ;; /dev/sdb*) echo sdb ;; esac ;;
esac
STUB
cat >"$tmp/stub-disk/findmnt" <<'STUB'
#!/bin/bash
echo /dev/sda1
STUB
chmod +x "$tmp/stub-disk"/*
check_disk() {
  PATH="$tmp/stub-disk:$PATH" bash -c 'source "$1"; ESP_MOUNTED=1; ESP_MNT=/esp; ROOT_DEV=$2; omarchy_mac_encrypt_check_root_device' \
    bash "$SCRIPT" "$1" 2>&1
}
check_disk /dev/sda2 >/dev/null || fail "a root on the ESP's disk passes the device check"
check_disk /dev/sdb2 >"$tmp/disk-out" && fail "a root on another disk than the ESP must be refused"
grep -Fq 'refusing to touch another disk' "$tmp/disk-out" || fail "the other disk is named"
check_disk /dev/mapper/root >"$tmp/disk-out" && fail "a mapper node must never be taken for the root partition"
grep -Fq 'crypt device, not a partition' "$tmp/disk-out" || fail "the mapper refusal is named"
check_disk /dev/nvme0n1 >"$tmp/disk-out" && fail "a whole disk must never be taken for the root partition"
grep -Fq 'disk device, not a partition' "$tmp/disk-out" || fail "the whole-disk refusal is named"
echo 'ok - the root must be a partition on the disk that holds the ESP'

# root resolution: the image cmdline (root=UUID=), then the btrfs label, never a GPT label
make_root_disk "$tmp/resolve.img" 128
[[ $(resolve_root_dev) == "$(readlink -f "$ROOT_PART")" ]] || fail "root=UUID=<btrfs uuid> resolves the plaintext root"
set_cmdline "quiet rw"
if resolve_root_dev >/dev/null; then
  fail "an unlabelled root without root= must not be guessed"
fi
btrfs filesystem label "$ROOT_PART" OMARCHY_ROOT
[[ $(resolve_root_dev) == "$(readlink -f "$ROOT_PART")" ]] || fail "the btrfs label OMARCHY_ROOT resolves the root when root= is unusable"
set_cmdline "root=/dev/mapper/root rw"
[[ $(resolve_root_dev) == "$(readlink -f "$ROOT_PART")" ]] || fail "root=/dev/mapper/root is skipped, not fatal, when a label resolves"
set_cmdline "root=PARTUUID=$ROOT_PARTUUID rw"
[[ $(resolve_root_dev) == "$(readlink -f "$ROOT_PART")" ]] || fail "root=PARTUUID= resolves the root"
echo 'ok - root resolves from root=UUID=, PARTUUID=, rd.luks.name= or the btrfs label'
drop_root_disk

# the ESP and Boot the unit mounts itself are released when it fails
mkdir -p /dev/disk/by-uuid
ln -sfn "$BOOT_LOOP" "/dev/disk/by-uuid/$BOOT_UUID"
gpt_links+=("/dev/disk/by-uuid/$BOOT_UUID")
mkdir -p "$boot_mnt/omarchy"
printf 'format=1\nphase=bogus\npartition=unknown\nluks_uuid=\n' >"$boot_mnt/omarchy/encrypt.state"
case_dir=$tmp/run
mkdir -p "$case_dir"
# The fixtures are mounted read-write here; the unit mounts the same devices
# itself (ESP read-only), which vfat refuses while another mount holds them.
umount "$esp_mnt"
umount "$boot_mnt"
rm -f "$tmp/failed"
if OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" OMARCHY_MAC_ENCRYPT_FAILED_FILE="$tmp/failed" \
  bash "$SCRIPT" >"$case_dir/out" 2>&1; then
  mount "$ESP_LOOP" "$esp_mnt"; mount "$BOOT_LOOP" "$boot_mnt"
  fail "an invalid phase must stop"
fi
grep -Fq 'inconsistent encryption state' "$tmp/failed" ||
  fail "a failure is recorded in the failed marker for the installed system to show"

mount "$ESP_LOOP" "$esp_mnt"
mount "$BOOT_LOOP" "$boot_mnt"
grep -Fq 'phase is invalid' "$case_dir/out" || fail "the invalid phase is named"
grep -Fq 'Repair: inspect' "$case_dir/out" || fail "without a key to resume with, the repair hint does not name --resume-only"
findmnt /run/omarchy-mac-encrypt/esp >/dev/null 2>&1 && fail "cleanup left the ESP mounted"
findmnt /run/omarchy-mac-encrypt/boot >/dev/null 2>&1 && fail "cleanup left the Boot partition mounted"
grep -Fq 'phase=bogus' "$boot_mnt/omarchy/encrypt.state" || fail "the ESP/Boot mounted by the unit were the fixtures"
rm -f "$boot_mnt/omarchy/encrypt.state"
echo 'ok - the unit mounts ESP and Boot itself and releases them on failure'

# mounted plaintext must abort (never reencrypt a still-mounted filesystem)
make_root_disk "$tmp/busy.img" 256
mkdir -p "$tmp/mnt-busy"
mount "$ROOT_PART" "$tmp/mnt-busy"
populate_root "$tmp/mnt-busy"
( cd "$tmp/mnt-busy" && exec sleep 120 ) &
busy_pid=$!
track_pid "$busy_pid"
sleep 0.2
rm -f "$boot_mnt/omarchy/encrypt.state" "$boot_mnt/omarchy/luks-key"
if run_script; then
  fail "a busy plaintext mount must abort"
fi
grep -Fq 'refusing to encrypt a mounted filesystem' "$case_dir/out" ||
  fail "busy unmount names the abort"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == btrfs ]] ||
  fail "busy abort must not have written a LUKS header"
kill -TERM "$busy_pid" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null || true
forget_pid "$busy_pid"
umount "$tmp/mnt-busy" 2>/dev/null || true
echo 'ok - mounted filesystem abort'
drop_root_disk

# spare partition space still shrinks (header needs filesystem space)
make_root_disk "$tmp/spare.img" 384 $((300 * 1024 * 1024))
mkdir -p "$tmp/mnt-spare"
mount "$ROOT_PART" "$tmp/mnt-spare"
populate_root "$tmp/mnt-spare"
part_bytes=$(blockdev --getsize64 "$ROOT_PART")
fs_spare=$(btrfs filesystem usage -b "$tmp/mnt-spare" | awk '/Device size:/ { print $3; exit }')
(( part_bytes - fs_spare >= REDUCE_BYTES )) || fail "spare fixture did not leave ≥32 MiB partition slack"
umount "$tmp/mnt-spare"
rm -f "$boot_mnt/omarchy/encrypt.state" "$boot_mnt/omarchy/luks-key"
run_script || fail "spare-space conversion"
grep -Fq "shrinking by 32M" "$case_dir/out" || fail "must shrink even when the partition has spare space"
grep -Fq "btrfs extent ${fs_spare} bytes" "$case_dir/out" || fail "PRE-shrink extent is measured with btrfs filesystem usage -b"
grep -Fq -- "--device-size $((fs_spare - REDUCE_BYTES))" "$tmp/cryptsetup.log" ||
  fail "cryptsetup --device-size is the measured extent minus the 32 MiB header"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == crypto_LUKS ]] || fail "spare-space path produced LUKS"
echo 'ok - shrink uses PRE-shrink extent and always reduces 32 MiB'
cryptsetup close root 2>/dev/null || true
drop_root_disk

: >"$tmp/cryptsetup.log"
rm -f "$tmp/cryptsetup.reencrypt.pid"
make_root_disk "$tmp/root.img" 384
mkdir -p "$tmp/mnt-root"
mount "$ROOT_PART" "$tmp/mnt-root"
populate_root "$tmp/mnt-root"
before=$(hash_tree "$tmp/mnt-root/@")
fs_before=$(btrfs filesystem usage -b "$tmp/mnt-root" | awk '/Device size:/ { print $3; exit }')
umount "$tmp/mnt-root"
rm -f "$esp_mnt/omarchy/install.conf" "$boot_mnt/omarchy/luks-key" "$boot_mnt/omarchy/encrypt.state"
# absent install.conf ⇒ encrypt=1
# The unit reads the ESP read-only; the Limine rebuild must still be able to write it.
rm -f "$esp_mnt/EFI/BOOT/boot-update.probe" "$tmp/plymouth.log" "$tmp/progress"
mount -o remount,ro "$esp_mnt"
start=$(date +%s)
run_script || fail "plain to LUKS conversion"
end=$(date +%s)
[[ -e $esp_mnt/EFI/BOOT/boot-update.probe ]] ||
  fail "the Limine rebuild could write the ESP the unit mounted read-only"
findmnt -no OPTIONS "$esp_mnt" | grep -Eq '(^|,)ro(,|$)' ||
  fail "the ESP is read-only again after the boot configuration"
mount -o remount,rw "$esp_mnt"
rm -f "$esp_mnt/EFI/BOOT/boot-update.probe"
[[ $(blkid -o value -s TYPE "$ROOT_PART") == crypto_LUKS ]] || fail "the partition is now crypto_LUKS"
elapsed=$((end - start))
[[ -e /dev/mapper/root ]] || fail "the mapping is left open as root"
mkdir -p "$tmp/mnt-mapped"
mount -o subvol=@ /dev/mapper/root "$tmp/mnt-mapped"
after=$(hash_tree "$tmp/mnt-mapped")
[[ $before == "$after" ]] || fail "sha256 of files before/after conversion must match"
[[ $(stat -c %a "$tmp/mnt-mapped/var/lib/omarchy/provisioning/luks-key") == 600 ]] ||
  fail "provisioning luks-key is 0600"
[[ $(stat -c %s "$boot_mnt/omarchy/luks-key") == 64 ]] || fail "the Boot key is 64 bytes"
[[ $(stat -c %a "$boot_mnt/omarchy/luks-key") == 600 ]] || fail "the Boot key is 0600"
[[ ! -e $esp_mnt/omarchy/luks-key ]] || fail "the throwaway key must not live on the ESP"
[[ $(sha256sum "$boot_mnt/omarchy/luks-key" | awk '{print $1}') == \
     $(sha256sum "$tmp/mnt-mapped/var/lib/omarchy/provisioning/luks-key" | awk '{print $1}') ]] ||
  fail "both copies of the throwaway key match"
luks_uuid=$(cryptsetup luksUUID "$ROOT_PART")
grep -Fxq "root UUID=$luks_uuid none luks" "$tmp/mnt-mapped/etc/crypttab" ||
  fail "crypttab names the LUKS UUID with a prompt entry"
grep -Fq "rd.luks.name=${luks_uuid}=root" "$tmp/mnt-mapped/etc/default/grub" &&
  ! grep -Fq 'root=/dev/mapper/root' "$tmp/mnt-mapped/etc/default/grub" &&
  grep -Fq "rd.luks.key=${luks_uuid}=/omarchy/luks-key:UUID=$BOOT_UUID" "$tmp/mnt-mapped/etc/default/grub" ||
  fail "GRUB_CMDLINE_LINUX names the LUKS mapping and the Boot key and leaves root= to grub-mkconfig"
[[ $(cat "$tmp/mnt-mapped/var/lib/omarchy/mac-first-boot/boot.log") == 'omarchy-mac-boot-update grub=0 ' ]] ||
  fail "a Limine Mac only rebuilds its UKI inside the opened root: no GRUB, no separate mkinitcpio -P ($(cat "$tmp/mnt-mapped/var/lib/omarchy/mac-first-boot/boot.log"))"
progress=$(sed -n 's/^system-update --progress=//p' "$tmp/plymouth.log" | tr '\n' ' ')
[[ $progress == "0 "* && $progress == *" 40 42 "* && $progress == *" 54 " ]] ||
  fail "the bar starts at 0, reaches 40 with the encryption, then 42 and 54 around the boot files: $progress"
[[ $progress == "$(tr ' ' '\n' <<<"$progress" | sed '/^$/d' | sort -n | tr '\n' ' ')" ]] ||
  fail "the bar never moves back: $progress"
messages=$(sed -n 's/^display-message --text=//p' "$tmp/plymouth.log")
[[ $messages == $'Encrypting your drive...\nPreparing your Mac for first boot...' ]] ||
  fail "the line names the encryption, then says the Mac is being prepared: $messages"
[[ $(<"$tmp/progress") == 54 ]] || fail "first boot carries the bar on from 54%"
! grep -Fq 'device_bytes' "$case_dir/out" || fail "cryptsetup's JSON progress stays out of the journal"
grep -Fq 'x-systemd.growfs' "$tmp/mnt-mapped/etc/fstab" || fail "x-systemd.growfs stays on the root fstab"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "state ends at phase=configured"
grep -Fq "luks_uuid=$luks_uuid" "$boot_mnt/omarchy/encrypt.state" || fail "state records the LUKS UUID"
grep -Fq "partition=$ROOT_PARTUUID" "$boot_mnt/omarchy/encrypt.state" || fail "state records the GPT PARTUUID"
grep -Fq 'format=1' "$boot_mnt/omarchy/encrypt.state" || fail "state format=1"
grep -Fq 'What=/dev/mapper/root' "$tmp/systemd/sysroot.mount.d/omarchy-mac-encrypt.conf" ||
  fail "sysroot.mount drop-in sets What=/dev/mapper/root"
grep -Fq -- "--device-size $((fs_before - REDUCE_BYTES))" "$tmp/cryptsetup.log" ||
  fail "conversion passed the measured extent minus 32 MiB to --device-size"
fs_after=$(findmnt -bno SIZE "$tmp/mnt-mapped")
(( fs_after <= fs_before - REDUCE_BYTES + 1048576 )) || fail "btrfs was shrunk by 32 MiB and not grown back"
cryptsetup status root >/dev/null || fail "the LUKS mapping is active"
map_bytes=$(cryptsetup status root | awk '/^ *size:/ { print $2 * 512; exit }')
(( map_bytes > fs_after )) || fail "cryptsetup resize grew LUKS past the shrunk btrfs (partition → LUKS → btrfs growfs)"
umount "$tmp/mnt-mapped"
throughput=$(awk -v b=384 -v t="$elapsed" 'BEGIN { if (t < 1) t = 1; printf "%.1f", b / t }')
hook_tp=$(sed -n 's/.*conversion finished in [0-9]*s (\([0-9]*\) MiB\/s).*/\1/p' "$case_dir/out" | tail -n 1)
echo "ok - plain → LUKS conversion keeps data (sha256) and growfs order; ${elapsed}s, ${throughput} MiB/s wall, hook ${hook_tp:-?} MiB/s"
printf 'throughput=%s MiB/s elapsed=%ss image=384MiB hook=%s\n' "$throughput" "$elapsed" "${hook_tp:-unknown}"

# Resolve the LUKS volume by PARTUUID recorded in state (plaintext btrfs UUID is gone).
# phase=configured only opens: no second update-grub, no second mkinitcpio.
cryptsetup close root 2>/dev/null || true
run_script || fail "phase=configured must open and continue via PARTUUID"
grep -Fq 'encrypting in place' "$case_dir/out" && fail "phase=configured must not re-encrypt"
grep -Fq 'regenerating GRUB' "$case_dir/out" && fail "phase=configured must not rewrite the boot configuration"
[[ -e /dev/mapper/root ]] || fail "phase=configured leaves the mapping open"
echo 'ok - phase=configured opens and continues without rewriting the boot configuration'

# phase=encrypted (interrupted before the boot configuration) finishes it once,
# here on a GRUB Mac: GRUB, then mkinitcpio -P, and no Limine rebuild.
mount -o subvol=@ /dev/mapper/root "$tmp/mnt-mapped"
rm "$tmp/mnt-mapped/var/lib/omarchy/limine.enabled"
: >"$tmp/mnt-mapped/var/lib/omarchy/mac-first-boot/boot.log"
umount "$tmp/mnt-mapped"
write_state "$boot_mnt" encrypted "$ROOT_PARTUUID" "$luks_uuid"
run_script || fail "phase=encrypted must finish the boot configuration"
grep -Fq 'encrypting in place' "$case_dir/out" && fail "phase=encrypted must not re-encrypt"
grep -Fq 'regenerating GRUB' "$case_dir/out" || fail "phase=encrypted rewrites the boot configuration once"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "phase=encrypted ends at configured"
mount -o subvol=@ /dev/mapper/root "$tmp/mnt-mapped"
[[ $(cat "$tmp/mnt-mapped/var/lib/omarchy/mac-first-boot/boot.log") == $'update-grub \nmkinitcpio -P' ]] ||
  fail "a GRUB Mac regenerates GRUB, then the initramfs: $(cat "$tmp/mnt-mapped/var/lib/omarchy/mac-first-boot/boot.log")"
: >"$tmp/mnt-mapped/var/lib/omarchy/limine.enabled"
umount "$tmp/mnt-mapped"
rm -f "$esp_mnt/EFI/BOOT/update-grub.probe"
echo 'ok - phase=encrypted completes the boot configuration and ends configured (GRUB Mac)'

# a revoked or missing throwaway key never halts the boot
write_state "$boot_mnt" rekeyed "$ROOT_PARTUUID" "$luks_uuid"
mv "$boot_mnt/omarchy/luks-key" "$tmp/luks-key.aside"
cryptsetup close root 2>/dev/null || true
run_script || fail "phase=rekeyed without a key must not fail the boot"
grep -Fq 'leaving unlock to sd-encrypt' "$case_dir/out" || fail "a missing key defers to sd-encrypt"
[[ ! -e /dev/mapper/root ]] || fail "nothing is opened without a key"
mv "$tmp/luks-key.aside" "$boot_mnt/omarchy/luks-key"
echo 'ok - a missing throwaway key defers the unlock to sd-encrypt instead of halting'

write_state "$boot_mnt" finished "$ROOT_PARTUUID" "$luks_uuid"
cryptsetup close root 2>/dev/null || true
run_script || fail "phase=finished must open and continue"
grep -Fq 'encrypting in place' "$case_dir/out" && fail "phase=finished must not re-encrypt"
grep -Fq 'phase=finished' "$boot_mnt/omarchy/encrypt.state" || fail "phase=finished is left for T4c"
echo 'ok - phase=finished opens and continues without re-encrypting'

state_uuid=$(sed -n 's/^luks_uuid=//p' "$boot_mnt/omarchy/encrypt.state")
printf 'owner_slot=1\nrecovery_slot=2\n' >>"$boot_mnt/omarchy/encrypt.state"
if ! bash -c 'source "$1"; BOOT_MNT=$2; omarchy_mac_encrypt_read_state; STATE_PARTITION=p; omarchy_mac_encrypt_write_state rekeyed' \
     bash "$SCRIPT" "$boot_mnt" 2>/dev/null; then
  fail "rewriting the state keeps working with foreign keys present"
fi
[[ $(cat "$boot_mnt/omarchy/encrypt.state") == "format=1"$'\n'"phase=rekeyed"$'\n'"partition=p"$'\n'"luks_uuid=$state_uuid"$'\n'"owner_slot=1"$'\n'"recovery_slot=2" ]] ||
  fail "write_state preserves owner_slot=/recovery_slot= written by the re-key"
echo 'ok - encrypt.state keeps the re-key slots across a rewrite'

# phase=reencrypting but the partition is still plaintext btrfs: the shrink
# already happened, so the restart measures the extent and never shrinks again
drop_root_disk
: >"$tmp/cryptsetup.log"
make_root_disk "$tmp/inconsistent.img" 384
mkdir -p "$tmp/mnt-inconsistent"
mount "$ROOT_PART" "$tmp/mnt-inconsistent"
populate_root "$tmp/mnt-inconsistent"
btrfs filesystem resize -32M "$tmp/mnt-inconsistent"
fs_shrunk=$(btrfs filesystem usage -b "$tmp/mnt-inconsistent" | awk '/Device size:/ { print $3; exit }')
umount "$tmp/mnt-inconsistent"
write_state "$boot_mnt" reencrypting "$ROOT_PARTUUID"
cp /dev/null "$boot_mnt/omarchy/luks-key" 2>/dev/null || true
dd if=/dev/urandom of="$boot_mnt/omarchy/luks-key" bs=64 count=1 status=none
chmod 0600 "$boot_mnt/omarchy/luks-key"
# The header was never written: this is a conversion that has not started.
run_script || fail "phase=reencrypting on a plaintext btrfs starts the conversion"
grep -Fq 'encrypting in place' "$case_dir/out" || fail "an unstarted reencrypt starts from the beginning"
! grep -Fq 'shrinking by' "$case_dir/out" || fail "a restart after the shrink must not shrink again"
grep -Fq -- "--device-size $fs_shrunk" "$tmp/cryptsetup.log" ||
  fail "the restart passes the already-shrunk extent as --device-size"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "the restarted conversion ends configured"
echo 'ok - phase=reencrypting without a LUKS header restarts the conversion from the shrunk extent'
cryptsetup close root 2>/dev/null || true
drop_root_disk

# resume from plaintext (state written, shrink not yet done)
cryptsetup close root 2>/dev/null || true
make_root_disk "$tmp/plain-phase.img" 384
mkdir -p "$tmp/mnt-plain-phase"
mount "$ROOT_PART" "$tmp/mnt-plain-phase"
populate_root "$tmp/mnt-plain-phase"
umount "$tmp/mnt-plain-phase"
rm -f "$boot_mnt/omarchy/luks-key"
write_state "$boot_mnt" plaintext "$ROOT_PARTUUID"
printf 'format=1\nencrypt=1\n' >"$esp_mnt/omarchy/install.conf"
run_script || fail "resume from phase=plaintext"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == crypto_LUKS ]] || fail "plaintext resume produced LUKS"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "plaintext resume ends configured"
echo 'ok - resume from phase=plaintext'
drop_root_disk

# resume from shrunk
make_root_disk "$tmp/shrunk.img" 384
mkdir -p "$tmp/mnt-shrunk"
mount "$ROOT_PART" "$tmp/mnt-shrunk"
populate_root "$tmp/mnt-shrunk"
btrfs filesystem resize -32M "$tmp/mnt-shrunk"
umount "$tmp/mnt-shrunk"
rm -f "$boot_mnt/omarchy/luks-key"
write_state "$boot_mnt" shrunk "$ROOT_PARTUUID"
run_script || fail "resume from phase=shrunk"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == crypto_LUKS ]] || fail "shrunk resume produced LUKS"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "shrunk resume ends configured"
echo 'ok - resume from phase=shrunk'
drop_root_disk

# Interrupted conversion MUST invoke --resume-only on the next run
cryptsetup close root 2>/dev/null || true
: >"$tmp/cryptsetup.log"
rm -f "$tmp/cryptsetup.reencrypt.pid" "$boot_mnt/omarchy/luks-key" "$boot_mnt/omarchy/encrypt.state"
make_root_disk "$tmp/resume.img" 512
mkdir -p "$tmp/mnt-resume"
mount "$ROOT_PART" "$tmp/mnt-resume"
populate_root "$tmp/mnt-resume"
resume_before=$(hash_tree "$tmp/mnt-resume/@")
umount "$tmp/mnt-resume"
mkdir -p "$tmp/run" "$tmp/systemd"
OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" \
  OMARCHY_MAC_ENCRYPT_BOOT="$boot_mnt" \
  OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
  bash "$SCRIPT" >"$tmp/run/out" 2>&1 &
hook_pid=$!
track_pid "$hook_pid"
interrupted=0
reencrypt_pid=""
for _ in $(seq 1 300); do
  if [[ -f $tmp/cryptsetup.reencrypt.pid ]] && cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
    reencrypt_pid=$(cat "$tmp/cryptsetup.reencrypt.pid")
    sleep 0.4
    if kill -TERM "$reencrypt_pid" 2>/dev/null; then
      interrupted=1
    fi
    break
  fi
  kill -0 "$hook_pid" 2>/dev/null || break
  sleep 0.1
done
wait "$hook_pid" || true
forget_pid "$hook_pid"
[[ $interrupted == 1 ]] || fail "conversion finished before SIGTERM; --resume-only was not proven"
grep -Fq 'phase=reencrypting' "$boot_mnt/omarchy/encrypt.state" ||
  fail "in-progress conversion journals phase=reencrypting"
grep -Fq -- '--encrypt' "$tmp/cryptsetup.log" || fail "interrupted run invoked cryptsetup reencrypt --encrypt"
if grep -Fq -- '--resume-only' "$tmp/cryptsetup.log"; then
  fail "first run must not have been --resume-only"
fi
echo "ok - conversion was interrupted with a LUKS2 header (resumable)"
case_dir=$tmp/run
cryptsetup close root 2>/dev/null || true
OMARCHY_MAC_ENCRYPT_ESP="$esp_mnt" \
  OMARCHY_MAC_ENCRYPT_BOOT="$boot_mnt" \
  OMARCHY_MAC_ENCRYPT_SYSTEMD_RUN="$tmp/systemd" \
  bash "$SCRIPT" >"$case_dir/out" 2>&1 || { cat "$case_dir/out" >&2; fail "resume after interruption"; }
grep -Fq -- '--resume-only' "$tmp/cryptsetup.log" ||
  fail "second run must invoke cryptsetup reencrypt --resume-only"
[[ $(blkid -c /dev/null -o value -s TYPE "$ROOT_PART") == crypto_LUKS ]] || fail "resumed device is LUKS"
[[ -e /dev/mapper/root ]] || cryptsetup open --batch-mode --key-file "$boot_mnt/omarchy/luks-key" --keyfile-size 64 "$ROOT_PART" root ||
  fail "could not open the resumed LUKS volume"
mkdir -p "$tmp/mnt-resume2"
mount -o subvol=@ /dev/mapper/root "$tmp/mnt-resume2"
[[ $(hash_tree "$tmp/mnt-resume2") == "$resume_before" ]] || fail "sha256 after resume matches the pre-encrypt files"
grep -Fq 'phase=configured' "$boot_mnt/omarchy/encrypt.state" || fail "resumed conversion ends configured"
umount "$tmp/mnt-resume2"
echo 'ok - rerun after an interruption resumes with --resume-only and keeps data intact'

# ── snapshot overlay unit ───────────────────────────────────────────────────
OVERLAY_UNIT=$FILES/usr/lib/omarchy/initcpio/omarchy-mac-snapshot-overlay.service
OVERLAY_SCRIPT=$FILES/usr/lib/omarchy/initcpio/omarchy-mac-snapshot-overlay
grep -Fxq 'After=sysroot.mount' "$OVERLAY_UNIT" && grep -Fxq 'Before=initrd-root-fs.target initrd-parse-etc.service' "$OVERLAY_UNIT" &&
  grep -Fxq 'ExecStart=/usr/lib/omarchy/initcpio/omarchy-mac-snapshot-overlay' "$OVERLAY_UNIT" ||
  fail "the snapshot overlay unit runs between sysroot.mount and initrd-root-fs.target"
grep -Fq 'add_module overlay' "$INSTALL" && grep -Fq 'omarchy-mac-snapshot-overlay.service' "$INSTALL" &&
  grep -Fq 'initrd-root-fs.target.wants/omarchy-mac-snapshot-overlay.service' "$INSTALL" ||
  fail "the install hook ships the overlay module, unit and wants link"
overlay_tmp=$(mktemp -d)
printf 'root=UUID=x rw rootflags=subvol=@ quiet\n' >"$overlay_tmp/plain"
printf 'root=UUID=x rw rootflags=relatime,subvol=@/.snapshots/3/snapshot quiet\n' >"$overlay_tmp/snapshot"
mkdir -p "$overlay_tmp/bin"
printf '#!/bin/bash\necho "mount $*" >>"$OVERLAY_LOG"\n' >"$overlay_tmp/bin/mount"
mkdir -p "$overlay_tmp/sysroot/etc"
printf '  UUID=root-uuid / btrfs rw,relatime,subvol=@ 0 0\nUUID=root-uuid /home btrfs rw,subvol=@home 0 0\nUUID=boot-uuid /boot ext4 rw 0 2\n' >"$overlay_tmp/sysroot/etc/fstab"
printf '#!/bin/bash\nexit 1\n' >"$overlay_tmp/bin/mountpoint"
chmod +x "$overlay_tmp/bin"/*
: >"$overlay_tmp/log"
OVERLAY_LOG=$overlay_tmp/log PATH="$overlay_tmp/bin:$PATH" OMARCHY_MAC_SNAPSHOT_CMDLINE=$overlay_tmp/plain \
  OMARCHY_MAC_SNAPSHOT_OVERLAY=$overlay_tmp/overlay OMARCHY_MAC_SNAPSHOT_MARKER=$overlay_tmp/marker \
  bash "$OVERLAY_SCRIPT" || fail "a plain @ boot passes through the overlay unit"
[[ ! -s $overlay_tmp/log && ! -e $overlay_tmp/marker ]] || fail "a plain @ boot mounts no overlay"
OVERLAY_LOG=$overlay_tmp/log PATH="$overlay_tmp/bin:$PATH" OMARCHY_MAC_SNAPSHOT_CMDLINE=$overlay_tmp/snapshot \
  OMARCHY_MAC_SNAPSHOT_SYSROOT=$overlay_tmp/sysroot OMARCHY_MAC_SNAPSHOT_OVERLAY=$overlay_tmp/overlay \
  OMARCHY_MAC_SNAPSHOT_MARKER=$overlay_tmp/marker bash "$OVERLAY_SCRIPT" || fail "a snapshot boot runs the overlay unit"
grep -Fq "mount -t tmpfs -o mode=0755 omarchy-snapshot-overlay $overlay_tmp/overlay" "$overlay_tmp/log" &&
  grep -Fq "mount -t overlay overlay -o lowerdir=$overlay_tmp/sysroot,upperdir=$overlay_tmp/overlay/upper,workdir=$overlay_tmp/overlay/work $overlay_tmp/sysroot" "$overlay_tmp/log" ||
  fail "a snapshot boot overlays /sysroot with a tmpfs upper: $(cat "$overlay_tmp/log")"
grep -Fxq '# omarchy-mac-snapshot-overlay:   UUID=root-uuid / btrfs rw,relatime,subvol=@ 0 0' "$overlay_tmp/sysroot/etc/fstab" &&
  grep -Fxq 'UUID=root-uuid /home btrfs rw,subvol=@home 0 0' "$overlay_tmp/sysroot/etc/fstab" &&
  grep -Fxq 'UUID=boot-uuid /boot ext4 rw 0 2' "$overlay_tmp/sysroot/etc/fstab" ||
  fail "the root fstab row is neutralised for the overlay, the other rows stay: $(cat "$overlay_tmp/sysroot/etc/fstab")"
grep -Fxq 'subvol=@/.snapshots/3/snapshot' "$overlay_tmp/marker" || fail "the booted snapshot is recorded for the running system"
rm -rf "$overlay_tmp"
echo 'ok - a GRUB snapshot entry boots read-only history under a tmpfs overlay'
