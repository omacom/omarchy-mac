# Configure pacman after package installation completes. Offline target package
# installs use the live ISO's offline pacman.conf until this final restore.
if omarchy-hw-aarch64; then
  pacman_dir="$OMARCHY_PATH/default/pacman/aarch64"
else
  pacman_dir="$OMARCHY_PATH/default/pacman"
fi
mirror="${OMARCHY_MIRROR:-stable}"
cp -f "$pacman_dir/pacman-${mirror}.conf" /etc/pacman.conf

mirrorlist_src="$pacman_dir/mirrorlist-${mirror}"
[[ -f $mirrorlist_src ]] || mirrorlist_src="$pacman_dir/mirrorlist"

# Overwriting the mirrorlist throws away the Asahi Alarm mirrors the machine
# was installed with, leaving one slow generic server. Keep what is there and
# append ours only where it is missing, as omarchy-refresh-pacman-mirrorlist does.
if omarchy-hw-aarch64 && [[ -s /etc/pacman.d/mirrorlist ]] && grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist; then
  while read -r mirror_line; do
    grep -qxF "$mirror_line" /etc/pacman.d/mirrorlist || printf '%s\n' "$mirror_line" >>/etc/pacman.d/mirrorlist
  done < <(grep -E '^[[:space:]]*Server[[:space:]]*=' "$mirrorlist_src")
else
  cp -f "$mirrorlist_src" /etc/pacman.d/mirrorlist
fi

# aarch64 pacman.conf Includes the asahi-alarm mirrorlist, so ship it with them.
# Without the file pacman refuses to parse its config at all.
if omarchy-hw-aarch64 && [[ -f $pacman_dir/mirrorlist.asahi-alarm ]]; then
  cp -f "$pacman_dir/mirrorlist.asahi-alarm" /etc/pacman.d/mirrorlist.asahi-alarm
fi

# Wait for CUPS to own the file, the way omarchy-settings does, so pacman does
# not turn the override into a .pacnew during ISO package installation.
if [[ -f $OMARCHY_PATH/etc-overrides/cups-cups-files.conf && -f /etc/cups/cups-files.conf ]]; then
  install -m 0640 -o root -g cups "$OMARCHY_PATH/etc-overrides/cups-cups-files.conf" /etc/cups/cups-files.conf
  rm -f /etc/cups/cups-files.conf.pacnew
fi

source "$OMARCHY_INSTALL/hardware/pacman.sh"
