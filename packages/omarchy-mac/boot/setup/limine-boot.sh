# Limine activation for an opted-in Apple image or installation. Build its
# menu and UKI, install the update hooks, then replace U-Boot's EFI loader.
# /etc/default/grub remains the common command-line source. An opted-in
# failure must fail the caller, including image finalization and first boot.
omarchy-hw-apple-silicon || return 0
[[ ${OMARCHY_MAC_IMAGE_BUILD:-} != "1" ]] || return 0
[[ -e ${OMARCHY_LIMINE_GATE:-/var/lib/omarchy/limine.enabled} ]] || return 0

# Scope traps and transaction variables to this leaf. Every required command
# is checked explicitly: sourced leaves can run inside an if/|| condition,
# where Bash suppresses errexit even when the caller requested it.
(
  set -uo pipefail
  esp=${OMARCHY_ESP:-/boot/efi}
  limine_efi=${OMARCHY_LIMINE_EFI:-/usr/share/limine/BOOTAA64.EFI}
  limine_conf_source=${OMARCHY_LIMINE_CONF_SOURCE:-${OMARCHY_PATH}/default/limine/limine.conf}
  grub_default=${OMARCHY_GRUB_DEFAULT:-/etc/default/grub}
  update_grub_default=${OMARCHY_UPDATE_GRUB_DEFAULT:-/etc/default/update-grub}
  limine_default=${OMARCHY_LIMINE_DEFAULT:-/etc/default/limine}
  boot_hooks_dir=${OMARCHY_LIMINE_BOOT_HOOKS_DIR:-/etc/boot/hooks/pre.d}
  pacman_hooks_dir=${OMARCHY_PACMAN_HOOKS_DIR:-/etc/pacman.d/hooks}
  systemd_dir=${OMARCHY_SYSTEMD_DIR:-/etc/systemd/system}
  grub_target=${OMARCHY_GRUB_TARGET:-/boot/grub/grub-aa64.efi}
  # update-grub rewrites all of GRUB_DIR (config, env, modules, fonts) too.
  grub_dir=${OMARCHY_GRUB_DIR:-/boot/grub}

  limine_boot_fail() {
    echo "limine-boot: $*; activation failed" >&2
    exit 1
  }

  kernel=$(omarchy-mac-kernel) || limine_boot_fail "cannot identify the installed kernel"
  [[ -f $limine_efi ]] || limine_boot_fail "$limine_efi is missing"
  [[ -f $grub_default ]] || limine_boot_fail "no $grub_default to derive the kernel command line"
  [[ -f $limine_conf_source ]] || limine_boot_fail "no $limine_conf_source menu template"
  findmnt -no TARGET "$esp" >/dev/null 2>&1 || limine_boot_fail "the ESP is not mounted at $esp"
  # This path is written to a configuration sourced by root.
  [[ $esp =~ ^/[a-zA-Z0-9_./-]+$ ]] || limine_boot_fail "invalid ESP path"

  limine_backup=$(mktemp -d) || exit 1
  limine_managed=("$limine_default" "$esp/limine.conf" "$esp/EFI/Linux"
    "$boot_hooks_dir/20-omarchy-mac-cmdline" "$update_grub_default"
    "$esp/EFI/BOOT/BOOTAA64.EFI" "$grub_dir" "$grub_target"
    "$pacman_hooks_dir/81-omarchy-mac-limine-deploy.hook")
  for index in "${!limine_managed[@]}"; do
    file=${limine_managed[index]}
    # tee/install would follow a linked destination outside this backup set.
    # The command-line hook is intentionally a symlink replaced by ln -sfn.
    if [[ $file != "$boot_hooks_dir/20-omarchy-mac-cmdline" ]] && sudo test -L "$file"; then
      sudo rm -rf "$limine_backup"
      limine_boot_fail "$file must not be a symlink"
    fi
    if sudo test -e "$file" || sudo test -L "$file"; then
      if ! sudo cp -a -- "$file" "$limine_backup/$index"; then
        sudo rm -rf "$limine_backup"
        limine_boot_fail "could not back up $file"
      fi
    fi
  done

  committed=0
  limine_boot_cleanup() {
    local status=$? index file rollback_failed=0
    trap - EXIT
    if (( ! committed )); then
      # Restore the exact prior loader and configuration, including a Mac
      # already booting Limine. Regenerating GRUB is not a rollback.
      for index in "${!limine_managed[@]}"; do
        file=${limine_managed[index]}
        if ! sudo rm -rf -- "$file"; then
          rollback_failed=1
          continue
        fi
        if sudo test -e "$limine_backup/$index" || sudo test -L "$limine_backup/$index"; then
          if ! sudo mkdir -p "$(dirname "$file")" || ! sudo cp -a -- "$limine_backup/$index" "$file"; then
            rollback_failed=1
          fi
        fi
      done
      if (( rollback_failed )); then
        echo "limine-boot: rollback incomplete; retained backup at $limine_backup" >&2
        exit 1
      fi
      echo "limine-boot: restored the previous boot files" >&2
    fi
    sudo rm -rf "$limine_backup" || status=1
    exit "$status"
  }
  trap limine_boot_cleanup EXIT

  # Asahi's update-grub stays for systems that still carry GRUB, but must
  # never overwrite Limine's ESP slot on a later kernel update.
  sudo mkdir -p "$esp/EFI/BOOT" || limine_boot_fail "cannot create the EFI loader directory"
  if command -v "${OMARCHY_GRUB_PROBE:-grub-probe}" >/dev/null 2>&1 &&
    command -v "${OMARCHY_GRUB_MKCONFIG:-grub-mkconfig}" >/dev/null 2>&1; then
    if ! grep -Fxq "TARGET=\"$grub_target\"" "$update_grub_default" 2>/dev/null; then
      printf '# Written by Omarchy: Limine owns BOOTAA64.EFI; update-grub writes its image here, unused.\nTARGET="%s"\n' "$grub_target" |
        sudo tee "$update_grub_default" >/dev/null || limine_boot_fail "cannot retarget update-grub"
    fi
    sudo "${OMARCHY_UPDATE_GRUB:-update-grub}" >/dev/null || limine_boot_fail "update-grub failed with its new target"
  fi

  sudo tee "$limine_default" >/dev/null <<'CONF' || limine_boot_fail "cannot write Limine defaults"
# Written by Omarchy (install/hardware/apple/limine-boot.sh). KERNEL_CMDLINE
# is derived from /etc/default/grub by omarchy-mac-limine-cmdline; edit GRUB's
# defaults, not this line.
TARGET_OS_NAME="Omarchy"
ENABLE_UKI=yes
CUSTOM_UKI_NAME="omarchy"
FIND_BOOTLOADERS=no
KERNEL_CMDLINE[default]=""
CONF
  printf 'ESP_PATH="%s"\nBOOT_ORDER="%s, *, *fallback, Snapshots"\n' "$esp" "$kernel" |
    sudo tee -a "$limine_default" >/dev/null || limine_boot_fail "cannot finish Limine defaults"
  sudo install -d "$boot_hooks_dir" || limine_boot_fail "cannot create the command-line hook directory"
  cmdline_command=$(command -v omarchy-mac-limine-cmdline) || limine_boot_fail "the command-line helper is missing"
  sudo ln -sfn "$cmdline_command" "$boot_hooks_dir/20-omarchy-mac-cmdline" || limine_boot_fail "cannot install the command-line hook"
  sudo omarchy-mac-limine-cmdline || limine_boot_fail "could not derive the kernel command line"
  sudo grep -q '^KERNEL_CMDLINE\[default\]="root=UUID=' "$limine_default" || limine_boot_fail "no root= in the derived command line"

  # The entry tool keys history by machine-id. Discard foreign history only
  # after a successful replacement; installer ESP:/omarchy staging survives.
  machine_id=$(cat "${OMARCHY_MACHINE_ID:-/etc/machine-id}" 2>/dev/null || true)
  stale_ids=$(sudo grep -o 'machine-id=[0-9a-f]\{32\}' "$esp/limine.conf" 2>/dev/null | cut -d= -f2 | sort -u || true)
  menu_is_ours=0
  if sudo grep -Fq 'interface_branding: Omarchy Bootloader' "$esp/limine.conf" 2>/dev/null; then
    menu_is_ours=1
    for stale_id in $stale_ids; do
      [[ $stale_id == "$machine_id" ]] || menu_is_ours=0
    done
  fi
  if (( ! menu_is_ours )); then
    sudo install -m600 "$limine_conf_source" "$esp/limine.conf" || limine_boot_fail "cannot install the Limine menu"
  fi
  sudo sed -i -E 's/^#?[[:space:]]*timeout:.*/timeout: 3/' "$esp/limine.conf" || limine_boot_fail "cannot set the menu timeout"
  if ! sudo grep -Eq '^timeout: ' "$esp/limine.conf"; then
    printf 'timeout: 3\n' | sudo tee -a "$esp/limine.conf" >/dev/null || limine_boot_fail "cannot append the menu timeout"
  fi

  echo "Building the Omarchy UKI and Limine entries"
  sudo limine-update || limine_boot_fail "limine-update failed"
  sudo test -s "$esp/EFI/Linux/omarchy_$kernel.efi" || limine_boot_fail "limine-update built no $kernel UKI"
  sudo grep -Fq "//$kernel" "$esp/limine.conf" || limine_boot_fail "limine.conf has no $kernel entry"
  sudo grep -Fq "boot():/EFI/Linux/omarchy_$kernel.efi" "$esp/limine.conf" || limine_boot_fail "limine.conf does not reference the $kernel UKI"

  if sudo grep -Fq '/GRUB (recovery)' "$esp/limine.conf"; then
    sudo awk '
      /^\/GRUB \(recovery\)$/ { skip = 1; next }
      skip && /^[[:space:]]/ { next }
      skip && /^[[:space:]]*$/ { next }
      { skip = 0; print }
    ' "$esp/limine.conf" >"$limine_backup/menu" || limine_boot_fail "cannot remove the old recovery entry"
    sudo install -m600 "$limine_backup/menu" "$esp/limine.conf" || limine_boot_fail "cannot write the cleaned menu"
  fi

  # Future package updates must keep the loader current. This hook belongs
  # in the transaction, before Limine takes the slot, including fresh images.
  sudo install -d "$pacman_hooks_dir" || limine_boot_fail "cannot create the pacman hook directory"
  sudo tee "$pacman_hooks_dir/81-omarchy-mac-limine-deploy.hook" >/dev/null <<'HOOK' || limine_boot_fail "cannot install the loader update hook"
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/share/limine/BOOTAA64.EFI

[Action]
Description = Deploying Limine to the ESP (Apple Silicon)
When = PostTransaction
Exec = /usr/bin/omarchy-mac-limine-deploy
HOOK
  sudo omarchy-mac-limine-deploy || limine_boot_fail "could not put Limine on the ESP"
  sudo cmp -s "$limine_efi" "$esp/EFI/BOOT/BOOTAA64.EFI" || limine_boot_fail "the ESP loader differs from packaged Limine"
  committed=1

  # Ancillary history and service cleanup can be retried after the boot
  # transaction. Enabling the watcher also works in a target chroot.
  for stale_id in $stale_ids; do
    if [[ $stale_id != "$machine_id" ]]; then
      sudo rm -rf "${esp:?}/$stale_id" || echo "limine-boot: could not remove stale history $stale_id" >&2
    fi
  done
  sudo limine-snapper-sync || echo "limine-snapper-sync did not finish; snapshot entries come with the next snapshot" >&2
  sudo systemctl enable --now limine-snapper-sync.service >/dev/null 2>&1 || true
  sudo rm -rf "$esp/limine" || true
  sudo rm -f "$esp/EFI/BOOT/grub-aa64.efi" || true
  if [[ -f $systemd_dir/omarchy-mac-boot-sync.service ]]; then
    sudo systemctl disable omarchy-mac-boot-sync.service >/dev/null 2>&1 || true
    sudo rm -f "$systemd_dir/omarchy-mac-boot-sync.service" || true
  fi
  exit 0
)
