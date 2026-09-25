# Limine machines get "quiet splash" from the limine-entry-tool drop-in and the
# plymouth hook from the mkinitcpio drop-in, both shipped by omarchy-settings.
# Apple Silicon boots m1n1 -> U-Boot -> GRUB, and omarchy-settings applies
# neither drop-in there, so both have to land in the files GRUB and mkinitcpio
# read directly. The menu title comes from GRUB_DISTRIBUTOR,
# which defaults to the os-release name, so those machines otherwise offer to
# boot "Arch Linux". Nothing here runs where Limine is installed or GRUB is not.
omarchy-cmd-missing limine || return 0

grub_default="${OMARCHY_GRUB_DEFAULT:-/etc/default/grub}"
grub_cfg="${OMARCHY_GRUB_CFG:-/boot/grub/grub.cfg}"
mkinitcpio_conf="${OMARCHY_MKINITCPIO_CONF:-/etc/mkinitcpio.conf}"
mkinitcpio_conf_dir="${OMARCHY_MKINITCPIO_CONF_DIR:-/etc/mkinitcpio.conf.d}"
# Config may already list plymouth/quiet splash while a previous mkinitcpio or
# grub-mkconfig failed. Retry those rebuilds instead of treating the files as done.
pending="${OMARCHY_GRUB_SPLASH_PENDING:-/var/lib/omarchy/migrations/grub-splash-rebuild-pending}"

[[ -f $grub_default ]] || return 0

# HOOKS is whatever mkinitcpio.conf and then the conf.d drop-ins leave behind.
# A drop-in that already names plymouth (Omarchy's 00-omarchy-hooks.conf) means the
# main file is left alone.
effective_hooks=$(
  # Drop-ins (including omarchy_hooks.conf) expand XKBLAYOUT from vconsole.conf,
  # which often only sets KEYMAP. Migrations run with nounset.
  set +u
  shopt -s nullglob
  HOOKS=()
  source "$mkinitcpio_conf"
  for conf in "$mkinitcpio_conf_dir"/*.conf; do
    source "$conf"
  done
  printf '%s\n' "${HOOKS[*]}"
)

initramfs_owed=0
[[ -f $pending ]] && initramfs_owed=1

if [[ " $effective_hooks " != *" plymouth "* ]]; then
  # Asahi Alarm's HOOKS start with "base udev"; place plymouth right after, the
  # same position the x86 drop-in uses, so it is up before encrypt asks.
  if grep -Eq '^HOOKS=\([^)]*\bbase (udev|systemd)\b' "$mkinitcpio_conf"; then
    sed -i -E 's/^(HOOKS=\([^)]*\bbase (udev|systemd))\b/\1 plymouth/' "$mkinitcpio_conf"
    echo "Adding the plymouth hook to $mkinitcpio_conf"
    initramfs_owed=1
  else
    echo "Warning: could not place the plymouth hook in $mkinitcpio_conf; the boot splash stays plain." >&2
  fi
fi

grub_changed=0

if grep -q '^GRUB_DISTRIBUTOR=' "$grub_default"; then
  if ! grep -qx 'GRUB_DISTRIBUTOR="Omarchy"' "$grub_default"; then
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Omarchy"/' "$grub_default"
    grub_changed=1
  fi
else
  echo 'GRUB_DISTRIBUTOR="Omarchy"' >>"$grub_default"
  grub_changed=1
fi

cmdline_line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" | tail -n 1 || true)
cmdline_quote='"'
cmdline=""
if [[ -n $cmdline_line ]]; then
  cmdline=${cmdline_line#GRUB_CMDLINE_LINUX_DEFAULT=}
  if [[ $cmdline == \"*\" ]]; then
    cmdline_quote='"'
    cmdline=${cmdline#\"}
    cmdline=${cmdline%\"}
  elif [[ $cmdline == \'*\' ]]; then
    cmdline_quote="'"
    cmdline=${cmdline#\'}
    cmdline=${cmdline%\'}
  else
    cmdline_quote=""
  fi
fi
new_cmdline=$cmdline
for param in quiet splash; do
  [[ " $new_cmdline " == *" $param "* ]] || new_cmdline="${new_cmdline:+$new_cmdline }$param"
done
if [[ $new_cmdline != "$cmdline" ]]; then
  write_quote=$cmdline_quote
  [[ -n $write_quote ]] || write_quote='"'
  new_line="GRUB_CMDLINE_LINUX_DEFAULT=${write_quote}${new_cmdline}${write_quote}"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$new_line|" "$grub_default"
  else
    printf '%s\n' "$new_line" >>"$grub_default"
  fi
  grub_changed=1
fi

rebuild_failed=0
if (( initramfs_owed )); then
  echo "Rebuilding the initramfs so the plymouth hook is in the image"
  if ! mkinitcpio -P; then
    echo "mkinitcpio failed; the GRUB splash leaf will retry the rebuild on the next run." >&2
    rebuild_failed=1
  fi
fi

if (( grub_changed )) || [[ -f $pending ]]; then
  if omarchy-cmd-present grub-mkconfig; then
    echo "Regenerating $grub_cfg"
    if ! grub-mkconfig -o "$grub_cfg"; then
      echo "grub-mkconfig failed; the GRUB splash leaf will retry on the next run." >&2
      rebuild_failed=1
    fi
  else
    echo "Warning: grub-mkconfig is missing; regenerate $grub_cfg by hand for the new boot options." >&2
    rebuild_failed=1
  fi
fi

if (( rebuild_failed )); then
  mkdir -p "$(dirname "$pending")"
  : >"$pending"
  return 1
fi
rm -f -- "$pending"
