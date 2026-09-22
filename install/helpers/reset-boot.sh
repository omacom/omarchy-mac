# Shared reset/owner boot preparation. Generators run only in a private mount
# namespace; publishing is a separate, explicitly verified operation.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/factory-reset.sh"
RESET_BOOT_HELPER=$(readlink -f "${BASH_SOURCE[0]}")

reset_boot_probe() {
  local root=${1%/} row source filesystem options dump _pass version tool preset lines
  [[ -n $root ]] || root=/
  RESET_BOOT_BACKEND="" RESET_BOOT_ASAHI=0
  if [[ -x $root/usr/bin/limine-update && -f $root/etc/default/limine ]]; then
    RESET_BOOT_BACKEND=limine
    return 0
  fi
  [[ -x $root/usr/bin/grub-mkconfig && -f $root/etc/default/grub && ! -L $root/etc/default/grub ]] || {
    reset_error 'No supported installed Limine or GRUB backend'; return 1;
  }
  # Initial GRUB contract is the canonical Asahi /boot topology. A separate
  # /boot/efi, custom boot filesystem or multiple kernel layout is preserved
  # and refused before staging rather than guessed from the first FAT row.
  row=$(awk '$1 !~ /^#/ && ($2=="/boot" || $2=="/boot/efi" || $2=="/efi") {print}' "$root/etc/fstab") || return $?
  [[ $(wc -l <<<"$row") == 1 ]] || { reset_error 'GRUB reset requires one distinct VFAT /boot mount'; return 1; }
  read -r source RESET_BOOT_MOUNT filesystem options dump _pass <<<"$row"
  [[ $source == UUID=* && $RESET_BOOT_MOUNT == /boot && $filesystem == vfat && ,$options, != *,noauto,* && ,$options, != *,ro,* ]] || return 1
  RESET_BOOT_UUID=${source#UUID=}
  [[ $RESET_BOOT_UUID =~ ^[a-fA-F0-9]{4}-[a-fA-F0-9]{4}$ ]] || return 1
  RESET_BOOT_DEVICE="/dev/disk/by-uuid/$RESET_BOOT_UUID"
  [[ -b $RESET_BOOT_DEVICE && $(findmnt -rn -M /boot -o UUID) == "$RESET_BOOT_UUID" && $(findmnt -rn -M /boot -o FSTYPE) == vfat ]] || {
    reset_error 'Factory boot identity does not match the mounted VFAT /boot'; return 1;
  }
  RESET_BOOT_ROOT_UUID=$(findmnt -rn -T "$root" -o UUID) || return $?
  [[ $RESET_BOOT_ROOT_UUID =~ ^[a-fA-F0-9-]{36}$ && $(findmnt -rn -T "$root" -o FSTYPE) == btrfs ]] || return 1
  row=$(awk '$1 !~ /^#/ && $2=="/" {print}' "$root/etc/fstab") || return $?
  [[ $(wc -l <<<"$row") == 1 ]] || return 1
  # Read all columns explicitly: source, mountpoint, type, options.
  read -r source filesystem dump options _pass <<<"$row"
  [[ $source == "UUID=$RESET_BOOT_ROOT_UUID" && $filesystem == / && $dump == btrfs && (,$options, == *,subvol=@,* || ,$options, == *,subvol=/@,*) && ,$options, != *,subvolid=* ]] || {
    reset_error 'Factory fstab must select this filesystem and canonical @ root'; return 1;
  }
  local -a kernels=()
  for version in "$root"/usr/lib/modules/*; do
    [[ -f $version/modules.builtin ]] && kernels+=("$version")
  done
  (( ${#kernels[@]} == 1 )) || { reset_error 'Factory kernel selection is ambiguous or lacks its packaged image'; return 1; }
  RESET_BOOT_KERNEL=${kernels[0]##*/}
  if [[ -f ${kernels[0]}/pkgbase && ! -L ${kernels[0]}/pkgbase ]]; then
    RESET_BOOT_PKGBASE=$(cat "${kernels[0]}/pkgbase") || return $?
  elif [[ -f $root/etc/mkinitcpio.d/linux-aarch64.preset && -x $root/usr/bin/pacman ]]; then
    RESET_BOOT_PKGBASE=$(chroot "$root" /usr/bin/pacman -Qqo "/usr/lib/modules/$RESET_BOOT_KERNEL/modules.builtin") || return $?
    [[ $RESET_BOOT_PKGBASE == linux-aarch64 ]] || return 1
  else
    reset_error 'Kernel package identity is unavailable'
    return 1
  fi
  [[ $RESET_BOOT_KERNEL =~ ^[a-zA-Z0-9._+-]+$ && $RESET_BOOT_PKGBASE =~ ^[a-zA-Z0-9._+-]+$ ]] || return 1
  for tool in mkinitcpio lsinitcpio grub-mkconfig grub-script-check grub-probe unshare sha256sum mount umount; do
    [[ -x $root/usr/bin/$tool ]] || { reset_error "Factory root lacks boot tool: $tool"; return 1; }
  done
  preset="$root/etc/mkinitcpio.d/$RESET_BOOT_PKGBASE.preset"
  [[ -f $preset && ! -L $preset ]] || return 1
  reset_boot_read_preset "$preset" || return $?
  [[ -f $root/etc/mkinitcpio.conf && -d $root/etc/grub.d ]] || return 1
  if [[ -f ${kernels[0]}/vmlinuz && ! -L ${kernels[0]}/vmlinuz ]]; then
    RESET_BOOT_KERNEL_SOURCE="${kernels[0]}/vmlinuz"
    RESET_BOOT_KERNEL_FILE="vmlinuz-$RESET_BOOT_PKGBASE"
    [[ $RESET_BOOT_PRESET_KVER == "/boot/$RESET_BOOT_KERNEL_FILE" || $RESET_BOOT_PRESET_KVER == "$RESET_BOOT_KERNEL" ]] || return 1
  elif [[ $RESET_BOOT_PKGBASE == linux-aarch64 && $RESET_BOOT_PRESET_KVER == "$RESET_BOOT_KERNEL" ]]; then
    if [[ $root == / ]]; then RESET_BOOT_KERNEL_SOURCE=/boot/vmlinuz-linux;
    else RESET_BOOT_KERNEL_SOURCE="$root/boot/Image"; fi
    [[ -f $RESET_BOOT_KERNEL_SOURCE && ! -L $RESET_BOOT_KERNEL_SOURCE ]] || return 1
    RESET_BOOT_KERNEL_FILE=vmlinuz-linux
    grep -aF "Linux version $RESET_BOOT_KERNEL " "$RESET_BOOT_KERNEL_SOURCE" >/dev/null || {
      reset_error 'Retained generic Image does not match the selected modules'; return 1;
    }
  else
    reset_error 'Selected factory has no retained matching kernel payload'
    return 1
  fi
  [[ -f /boot/$RESET_BOOT_KERNEL_FILE && -f /boot/$RESET_BOOT_IMAGE && -d /boot/grub ]] || return 1
  for version in /boot/vmlinuz-* /boot/vmlinux-* /boot/kernel-* /boot/Image; do
    [[ -f $version ]] || continue
    [[ $version == "/boot/$RESET_BOOT_KERNEL_FILE" ]] || { reset_error 'Multiple boot kernels require explicit selection'; return 1; }
  done
  # 10_linux discovers fallback/initrd files independently of PRESETS. They
  # must not enter the next root with old modules or embedded key material.
  for version in /boot/initramfs-* /boot/initrd*; do
    [[ -f $version ]] || continue
    [[ $version == "/boot/$RESET_BOOT_IMAGE" ]] || { reset_error "Additional initramfs needs explicit rebuilding: $version"; return 1; }
  done
  if [[ $RESET_BOOT_PKGBASE == linux-asahi* || -e /boot/m1n1/boot.bin ]]; then
    RESET_BOOT_ASAHI=1
    [[ -x $root/usr/bin/update-m1n1 && -f $root/usr/lib/asahi-boot/m1n1.bin && -f $root/usr/lib/asahi-boot/u-boot-nodtb.bin && -d $root/usr/lib/modules/$RESET_BOOT_KERNEL/dtbs ]] || return 1
    if [[ -f $root/etc/default/update-m1n1 ]]; then
      [[ -z $(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$root/etc/default/update-m1n1") ]] || {
        reset_error 'Custom update-m1n1 overrides require explicit input review'; return 1;
      }
    fi
  fi
  RESET_BOOT_LUKS_UUID=""
  local backing root_device
  root_device=$(findmnt -rn -T "$root" -o SOURCE) || return $?
  root_device=${root_device%%\[*}
  backing=$(lsblk -nspo NAME,FSTYPE "$root_device" | awk '$2=="crypto_LUKS" {print $1}') || return $?
  if [[ -n $backing ]]; then
    [[ $(wc -l <<<"$backing") == 1 && -b $backing ]] || return 1
    RESET_BOOT_LUKS_UUID=$(cryptsetup luksUUID "$backing") || return $?
    [[ $RESET_BOOT_LUKS_UUID =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
  fi
  RESET_BOOT_BACKEND=grub
}

reset_boot_read_preset() {
  local preset=$1 line key value presets=0
  RESET_BOOT_PRESET_KVER="" RESET_BOOT_IMAGE=""
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line//[[:space:]]/}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || return 1
    key=${line%%=*} value=${line#*=}
    [[ ! ${seen[$key]+yes} ]] || return 1
    seen[$key]=1
    case $key in
      PRESETS) [[ $value == "('default')" || $value == '("default")' ]] || return 1; presets=1 ;;
      ALL_kver|default_image)
        [[ $value == \"*\" || $value == \'*\' ]] || return 1
        value=${value:1:${#value}-2}
        [[ $value =~ ^[a-zA-Z0-9/._+-]+$ ]] || return 1
        if [[ $key == ALL_kver ]]; then RESET_BOOT_PRESET_KVER=$value;
        else [[ $value == /boot/initramfs-*.img && ${value#/boot/} != */* ]] || return 1; RESET_BOOT_IMAGE=${value#/boot/}; fi ;;
      ALL_config|default_config) [[ $value == '"/etc/mkinitcpio.conf"' || $value == "'/etc/mkinitcpio.conf'" ]] || return 1 ;;
      default_options) [[ $value == '""' || $value == "''" ]] || return 1 ;;
      # These package assignments are inactive with PRESETS=('default').
      fallback_image|fallback_options|fallback_config) [[ $value != *'`'* && $value != *'$'* && $value != *';'* ]] || return 1 ;;
      *) reset_error "Unsupported active preset setting: $key"; return 1 ;;
    esac
  done <"$preset"
  [[ $presets == 1 && -n $RESET_BOOT_PRESET_KVER && -n $RESET_BOOT_IMAGE ]]
}

reset_boot_stage_path_valid() {
  local root_uuid=$1 stage=$2
  [[ $stage == /* && $stage != *'/../'* && ! -e $stage && ! -L $stage && -d ${stage%/*} ]] || return 1
  # /run can contain a mounted Btrfs top level. Check its actual backing,
  # not its spelling; a real tmpfs staging directory is never acceptable.
  [[ $(findmnt -rn -T "${stage%/*}" -o FSTYPE) == btrfs && $(findmnt -rn -T "${stage%/*}" -o UUID) == "$root_uuid" ]]
}

reset_boot_bind_staged_root() {
  local root=${1%/}
  [[ -n $root ]] || root=/
  # grub-probe resolves devices through mountinfo. A Btrfs subvolume reached
  # only as a directory below the top-level mount is invisible there after
  # chroot, so expose the staged subvolume as its own private mount.
  [[ $root == / ]] || mount --bind "$root" "$root"
}

reset_boot_bind_boot_readonly() {
  local root=${1%/}
  [[ -n $root ]] || root=/
  # The supported GRUB topology already has this VFAT mounted at /boot.
  # A second device mount with different read-only state is rejected by the
  # kernel. Give the private namespace a read-only bind view instead; this
  # does not change the live /boot mount or the underlying superblock state.
  mount --bind /boot "$root/boot" || return $?
  mount -o remount,bind,ro "$root/boot"
}

reset_boot_prepare() {
  local root=$1 stage=$2 key_mode=$3
  [[ $key_mode == provision || $key_mode == owner ]] || return 1
  reset_boot_probe "$root" || return $?
  [[ $RESET_BOOT_BACKEND == grub ]] || { reset_error 'Use the existing Limine generator for this backend'; return 1; }
  reset_boot_stage_path_valid "$RESET_BOOT_ROOT_UUID" "$stage" || return $?
  install -d -m 700 "$stage" || return $?
  unshare --mount --propagation private /bin/bash -euo pipefail -c \
    'source "$1"; shift; reset_boot_generate_private "$@"' reset-boot "$RESET_BOOT_HELPER" "$root" "$stage" "$key_mode"
}

reset_boot_generate_private() {
  local root=${1%/} stage=$2 key_mode=$3 directory kernel image original_root
  [[ -n $root ]] || root=/
  reset_boot_probe "$root" || return $?
  install -d -m 700 "$stage/runtime" "$stage/runtime/tmp" "$stage/tmp" "$stage/files/grub" "$stage/files/m1n1" || return $?
  # /run and /tmp are backed by the caller's disk staging directory. These
  # mounts are private and disappear on exit, including generator failures.
  reset_boot_bind_staged_root "$root" || return $?
  for directory in proc sys dev; do
    mount --rbind "/$directory" "$root/$directory" || return $?
    mount --make-rslave "$root/$directory" || return $?
  done
  mount --bind "$stage/runtime" "$root/run" || return $?
  mount --bind "$stage/tmp" "$root/tmp" || return $?
  kernel=$RESET_BOOT_KERNEL_FILE image=$RESET_BOOT_IMAGE
  cp -- "$RESET_BOOT_KERNEL_SOURCE" "$stage/files/$kernel" || return $?
  sha256sum "$RESET_BOOT_KERNEL_SOURCE" >"$stage/kernel-input" || return $?
  reset_boot_bind_boot_readonly "$root" || return $?
  chroot "$root" /usr/bin/env TMPDIR=/run/tmp TMP=/run/tmp TEMP=/run/tmp /usr/bin/mkinitcpio \
    --nopost -k "$RESET_BOOT_KERNEL" -g /run/initramfs.img || return $?
  mv "$stage/runtime/initramfs.img" "$stage/files/$image" || return $?
  mount --bind "$stage/files/$kernel" "$root/boot/$kernel" || return $?
  mount --bind "$stage/files/$image" "$root/boot/$image" || return $?
  chroot "$root" /usr/bin/grub-mkconfig -o /run/grub.cfg.raw || return $?
  original_root=$(btrfs subvolume show "$root" | awk '$1=="Name:" {print $2; exit}') || return $?
  [[ $original_root == @ || $original_root == @omarchy-reset-next ]] || return 1
  sed "s|rootflags=subvol=$original_root\([[:space:]]\)|rootflags=subvol=@\\1|g" "$stage/runtime/grub.cfg.raw" >"$stage/files/grub/grub.cfg" || return $?
  if (( RESET_BOOT_ASAHI )); then
    local input logical
    local -a inputs=(usr/bin/update-m1n1 usr/share/asahi-scripts/functions.sh usr/lib/asahi-boot/m1n1.bin usr/lib/asahi-boot/u-boot-nodtb.bin)
    [[ ! -f $root/etc/m1n1.conf ]] || inputs+=(etc/m1n1.conf)
    [[ ! -f $root/etc/default/update-m1n1 ]] || inputs+=(etc/default/update-m1n1)
    for input in "$root/usr/lib/modules/$RESET_BOOT_KERNEL"/dtbs/*.dtb; do
      [[ -f $input && ! -L $input ]] || return 1
      inputs+=("${input#"${root%/}/"}")
    done
    : >"$stage/asahi-inputs"
    for logical in "${inputs[@]}"; do
      [[ -f $root/$logical && ! -L $root/$logical ]] || return 1
      input=$(sha256sum "$root/$logical") || return $?
      printf '%s  /%s\n' "${input%% *}" "$logical" >>"$stage/asahi-inputs" || return $?
    done
    chroot "$root" /usr/bin/env LC_ALL=C "DTBS=/usr/lib/modules/$RESET_BOOT_KERNEL/dtbs/*.dtb" \
      /usr/bin/update-m1n1 /run/boot.bin || return $?
    [[ -s $stage/runtime/boot.bin ]] || return 1
    mv "$stage/runtime/boot.bin" "$stage/files/m1n1/boot.bin" || return $?
  fi
  printf '%s\n' "$RESET_BOOT_ROOT_UUID $RESET_BOOT_UUID $RESET_BOOT_KERNEL $RESET_BOOT_PKGBASE $key_mode $RESET_BOOT_ASAHI $kernel $image" >"$stage/identity" || return $?
  cp "$stage/files/grub/grub.cfg" "$stage/runtime/grub.cfg.final" || return $?
  reset_boot_verify "$root" "$stage" "$key_mode" || return $?
  (cd "$stage/files" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$stage/manifest" || return $?
  sync -f "$stage"
}

reset_boot_verify() {
  local root=$1 stage=$2 key_mode=$3 cfg="$2/files/grub/grub.cfg" listing lines kernel image
  kernel=$RESET_BOOT_KERNEL_FILE image=$RESET_BOOT_IMAGE
  [[ $(sha256sum "$stage/files/$kernel") == "$(cut -d' ' -f1 "$stage/kernel-input")  "* ]] || return 1
  chroot "$root" /usr/bin/grub-script-check /run/grub.cfg.final || return $?
  lines=$(awk '$1=="linux" || $1=="linuxefi" {print}' "$cfg") || return $?
  [[ -n $lines && $lines != *'@omarchy-reset-next'* ]] || return 1
  local line word roots flags kernels cryptkeys cryptdevices linux_count initrd_count search_uuid=""
  linux_count=$(wc -l <<<"$lines")
  local -a words
  while IFS= read -r line; do
    roots=0 flags=0 kernels=0 cryptkeys=0 cryptdevices=0
    read -ra words <<<"$line"
    for word in "${words[@]}"; do
      case $word in
        /vmlinuz-*|/Image) [[ $word == "/$kernel" ]] || return 1; kernels=$((kernels + 1));;
        root=*) [[ $word == "root=UUID=$RESET_BOOT_ROOT_UUID" || $word == root=/dev/mapper/root ]] || return 1; roots=$((roots + 1));;
        rootflags=*) [[ $word == rootflags=subvol=@ ]] || return 1; flags=$((flags + 1));;
        cryptdevice=*)
          [[ -n $RESET_BOOT_LUKS_UUID && ($word == "cryptdevice=UUID=$RESET_BOOT_LUKS_UUID:root" || $word == "cryptdevice=UUID=$RESET_BOOT_LUKS_UUID:root:allow-discards") ]] || return 1
          cryptdevices=$((cryptdevices + 1)) ;;
        rd.luks.*|cryptopts=*) reset_error 'Unsupported encrypted-root command line'; return 1 ;;
        cryptkey=*) [[ $word == cryptkey=rootfs:/etc/omarchy/provisioning.key && $key_mode == provision ]] || return 1; cryptkeys=$((cryptkeys + 1));;
      esac
    done
    (( roots == 1 && flags == 1 && kernels == 1 && cryptkeys <= 1 )) || return 1
    if [[ -n $RESET_BOOT_LUKS_UUID ]]; then (( cryptdevices == 1 )) || return 1;
    else (( cryptdevices == 0 && cryptkeys == 0 )) || return 1; fi
    if [[ -f $root/etc/omarchy/provisioning.key ]]; then (( cryptkeys == 1 )) || return 1; fi
  done <<<"$lines"
  # Every initrd line must name exactly the image we rebuilt. No stale
  # fallback, external keyfile or unvalidated microcode image is accepted.
  lines=$(awk '$1=="initrd" || $1=="initrdefi" {print}' "$cfg") || return $?
  [[ -n $lines ]] || return 1
  initrd_count=$(wc -l <<<"$lines")
  [[ $initrd_count == "$linux_count" ]] || return 1
  while IFS= read -r line; do
    read -ra words <<<"$line"
    [[ ${#words[@]} == 2 && ${words[1]} == "/$image" ]] || return 1
  done <<<"$lines"
  # Header/font probes may select the root filesystem; each actual boot
  # payload must be read with root set to the verified separate boot UUID.
  while IFS= read -r line; do
    read -ra words <<<"$line"
    case ${words[0]:-} in
      set) [[ ${words[1]:-} != root=* ]] || search_uuid="" ;;
      search)
        if [[ $line == *--fs-uuid* && $line == *--set=root* ]]; then
          search_uuid=${words[${#words[@]}-1]}; search_uuid=${search_uuid//\'/}
        fi ;;
      linux|linuxefi|initrd|initrdefi) [[ $search_uuid == "$RESET_BOOT_UUID" ]] || return 1 ;;
    esac
  done <"$cfg"
  listing=$(chroot "$root" /usr/bin/lsinitcpio "/boot/$image") || return $?
  grep -q "usr/lib/modules/$RESET_BOOT_KERNEL/" <<<"$listing" || return 1
  if [[ -n $RESET_BOOT_LUKS_UUID ]]; then
    grep -qx 'hooks/encrypt' <<<"$listing" && grep -qx 'usr/bin/cryptsetup' <<<"$listing" || return 1
    if ! grep -q 'drivers/md/dm-crypt\.ko' "$root/usr/lib/modules/$RESET_BOOT_KERNEL/modules.builtin"; then
      grep -q "usr/lib/modules/$RESET_BOOT_KERNEL/.*dm-crypt\.ko" <<<"$listing" || return 1
    fi
  fi
  if ! grep -q 'fs/btrfs/btrfs\.ko' "$root/usr/lib/modules/$RESET_BOOT_KERNEL/modules.builtin"; then
    grep -q "usr/lib/modules/$RESET_BOOT_KERNEL/.*btrfs\.ko" <<<"$listing" || return 1
  fi
  if [[ $key_mode == owner ]]; then
    [[ $listing != *etc/omarchy/provisioning.key* && ! -e $root/etc/omarchy/provisioning.key ]] || return 1
  elif [[ -f $root/etc/omarchy/provisioning.key ]]; then
    grep -qx 'etc/omarchy/provisioning.key' <<<"$listing" || return 1
  fi
}

reset_boot_bundle_check() {
  local stage=$1 key_mode=$2 root_uuid boot_uuid kernel pkgbase mode asahi kernel_file image_file extra file digest count=0
  [[ -d $stage && ! -L $stage && $(stat -c %u "$stage") == 0 && $(stat -c %a "$stage") == 700 ]] || return 1
  [[ -f $stage/identity && ! -L $stage/identity && -f $stage/manifest && ! -L $stage/manifest ]] || return 1
  read -r root_uuid boot_uuid kernel pkgbase mode asahi kernel_file image_file extra <"$stage/identity"
  [[ -z $extra && $root_uuid =~ ^[a-fA-F0-9-]{36}$ && $boot_uuid =~ ^[a-fA-F0-9]{4}-[a-fA-F0-9]{4}$ && $kernel =~ ^[a-zA-Z0-9._+-]+$ && $pkgbase =~ ^[a-zA-Z0-9._+-]+$ && $mode == "$key_mode" && ($asahi == 0 || $asahi == 1) ]] || return 1
  [[ $(findmnt -rn -M /boot -o UUID) == "$boot_uuid" && $(findmnt -rn -M /boot -o FSTYPE) == vfat && $(findmnt -rn -T / -o UUID) == "$root_uuid" ]] || return 1
  [[ $kernel_file == "vmlinuz-$pkgbase" || ($pkgbase == linux-aarch64 && $kernel_file == vmlinuz-linux) ]] || return 1
  [[ $image_file =~ ^initramfs-[a-zA-Z0-9._+-]+\.img$ ]] || return 1
  [[ -z $(find "$stage/files" -type l -print -quit) ]] || return 1
  local -A seen=()
  while read -r digest file extra; do
    [[ $digest =~ ^[a-f0-9]{64}$ && -z $extra && ! ${seen[$file]+yes} ]] || return 1
    case $file in
      "./$kernel_file"|"./$image_file"|./grub/grub.cfg) ;;
      ./m1n1/boot.bin) (( asahi == 1 )) || return 1 ;;
      *) return 1 ;;
    esac
    [[ -f $stage/files/$file && $(sha256sum "$stage/files/$file") == "$digest  "* ]] || return 1
    seen[$file]=1; count=$((count + 1))
  done <"$stage/manifest"
  (( count == 3 + asahi )) || return 1
  [[ $(find "$stage/files" -type f | wc -l) == "$count" ]] || return 1
}

reset_boot_copy_atomic() {
  local source=$1 destination=$2 temporary
  [[ ! -L $destination && (! -e $destination || -f $destination) && -d ${destination%/*} && ! -L ${destination%/*} ]] || return 1
  temporary=$(mktemp "${destination%/*}/.omarchy-reset.XXXXXXXX") || return $?
  if ! { cp -- "$source" "$temporary" && sync -f "$temporary" && cmp "$source" "$temporary" && mv -T "$temporary" "$destination" && sync -f "${destination%/*}"; }; then
    rm -f -- "$temporary"
    return 1
  fi
}

reset_boot_backup() {
  local stage=$1 key_mode=$2 digest relative extra old_digest
  reset_boot_bundle_check "$stage" "$key_mode" || return $?
  [[ ! -e $stage/backup && ! -L $stage/backup ]] || return 1
  install -d -m 700 "$stage/backup/files" || return $?
  while read -r digest relative extra; do
    relative=${relative#./}
    [[ ! -L /boot/$relative && (! -e /boot/$relative || -f /boot/$relative) && ! -L /boot/${relative%/*} ]] || return 1
    if [[ -f /boot/$relative ]]; then
      install -Dm600 "/boot/$relative" "$stage/backup/files/$relative" || return $?
      old_digest=$(sha256sum "$stage/backup/files/$relative") || return $?
      printf '%s  %s\n' "${old_digest%% *}" "$relative" >>"$stage/backup/manifest" || return $?
    else
      printf 'absent  %s\n' "$relative" >>"$stage/backup/manifest" || return $?
    fi
  done <"$stage/manifest"
  reset_state_write "$stage/backup/binding" "$(sha256sum "$stage/manifest" | cut -d' ' -f1) $(sha256sum "$stage/backup/manifest" | cut -d' ' -f1)" || return $?
  sync -f "$stage/backup"
}

reset_boot_backup_check() {
  local stage=$1 expected digest relative extra count=0 candidate
  reset_private_file "$stage/backup/binding" || return 1
  [[ -f $stage/backup/manifest && ! -L $stage/backup/manifest ]] || return 1
  expected="$(sha256sum "$stage/manifest" | cut -d' ' -f1) $(sha256sum "$stage/backup/manifest" | cut -d' ' -f1)"
  [[ $(cat "$stage/backup/binding") == "$expected" ]] || return 1
  local -A destinations=()
  while read -r digest relative extra; do
    [[ -z $extra && ($digest == absent || $digest =~ ^[a-f0-9]{64}$) && ! ${destinations[$relative]+yes} ]] || return 1
    candidate=$(awk -v path="./$relative" '$2==path {print $1}' "$stage/manifest") || return $?
    [[ $candidate =~ ^[a-f0-9]{64}$ ]] || return 1
    if [[ $digest != absent ]]; then
      [[ -f $stage/backup/files/$relative && ! -L $stage/backup/files/$relative && $(sha256sum "$stage/backup/files/$relative") == "$digest  "* ]] || return 1
    fi
    destinations[$relative]=1; count=$((count + 1))
  done <"$stage/backup/manifest"
  (( count > 0 )) && [[ $count == "$(wc -l <"$stage/manifest")" ]]
}

reset_boot_readback() {
  local stage=$1 key_mode=$2 digest relative extra
  reset_boot_bundle_check "$stage" "$key_mode" || return $?
  while read -r digest relative extra; do
    relative=${relative#./}
    [[ -f /boot/$relative && ! -L /boot/$relative && $(sha256sum "/boot/$relative") == "$digest  "* ]] || return 1
  done <"$stage/manifest"
}

reset_boot_publish() {
  local stage=$1 key_mode=$2 digest relative extra
  reset_boot_bundle_check "$stage" "$key_mode" || return $?
  reset_boot_backup_check "$stage" || return $?
  # The caller owns the whole root/baseline/boot transaction. Mark intent
  # before its first boot write, so a later root exchange failure restores
  # these same scoped bytes, not a newly generated approximation.
  reset_state_write "$stage/publication" publishing || return $?
  while read -r digest relative extra; do
    relative=${relative#./}
    reset_boot_copy_atomic "$stage/files/$relative" "/boot/$relative" || return $?
  done <"$stage/manifest"
  reset_boot_readback "$stage" "$key_mode" || return $?
  reset_state_write "$stage/publication" published
}

reset_boot_rollback() {
  local stage=$1 key_mode=$2 old_digest relative extra candidate current
  reset_boot_bundle_check "$stage" "$key_mode" || return $?
  reset_boot_backup_check "$stage" || return $?
  # Inspect every current path before restoring any. Unknown concurrent bytes
  # are preserved for inspection; only this transaction's old/new bytes fit.
  while read -r old_digest relative extra; do
    [[ -z $extra && ! -L /boot/$relative ]] || return 1
    candidate=$(awk -v path="./$relative" '$2==path {print $1}' "$stage/manifest") || return $?
    [[ $candidate =~ ^[a-f0-9]{64}$ ]] || return 1
    if [[ -f /boot/$relative ]]; then
      current=$(sha256sum "/boot/$relative") || return $?
      [[ ${current%% *} == "$candidate" || ${current%% *} == "$old_digest" ]] || { reset_error "Boot path changed outside reset: $relative"; return 1; }
    else
      [[ $old_digest == absent ]] || return 1
    fi
    if [[ $old_digest != absent ]]; then
      [[ $old_digest =~ ^[a-f0-9]{64}$ && -f $stage/backup/files/$relative && ! -L $stage/backup/files/$relative && $(sha256sum "$stage/backup/files/$relative") == "$old_digest  "* ]] || return 1
    fi
  done <"$stage/backup/manifest"
  while read -r old_digest relative extra; do
    if [[ $old_digest == absent ]]; then rm -f -- "/boot/$relative" || return $?;
    else reset_boot_copy_atomic "$stage/backup/files/$relative" "/boot/$relative" || return $?; fi
  done <"$stage/backup/manifest"
  sync -f /boot || return $?
  reset_state_write "$stage/publication" rolled-back
}
