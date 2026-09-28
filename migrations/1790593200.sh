echo "Restore oomd and zswap drop-ins the aarch64 settings package removes"

# omarchy-mac enables systemd-oomd (install/config/enable-services.sh and
# migration 1785424256) and configures zram (1787669934 / 1789246530). The
# aarch64 omarchy-settings package still treats that memory stack as x86-only
# when the source has no default/settings-runtime-profile, and an upgrade
# deletes the drop-ins. oomd then runs with nothing safe to kill, and zswap
# turns back on in front of zram.
#
# Limine, asdcontrol, and the USB autosuspend blacklist are not restored.
# Macs do not boot with Limine, asdcontrol's sudoers file is not in this tree,
# and the settings package leaves Apple Silicon on the kernel's USB autosuspend.
#
# The repair files use different names from the ones the settings package
# owns, in the same directory, so a later package that ships the canonical
# drop-ins again does not hit a pacman file conflict. systemd loads a
# directory in byte order. A 00- prefix sorts before 10-omarchy.conf,
# 10-oomd.conf, and omarchy-zswap.conf, so those package copies override
# this repair once they are installed again.

as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

restore_root="${OMARCHY_SETTINGS_RESTORE_ROOT:-}"

path_present() {
  local path
  for path in "$@"; do
    if [[ -e $path || -L $path ]]; then
      return 0
    fi
  done
  return 1
}

installed_path=""

install_repair() {
  local source=$1
  local repair=$2
  shift 2

  installed_path=""
  [[ -f $source ]] || return 0
  if path_present "$@" "$repair"; then
    return 0
  fi
  as_root install -D -m 0644 "$source" "$repair"
  installed_path=$repair
}

install_repair \
  "$OMARCHY_PATH/etc/systemd/oomd.conf.d/10-omarchy.conf" \
  "$restore_root/etc/systemd/oomd.conf.d/00-omarchy-mac-restore.conf" \
  "$restore_root/etc/systemd/oomd.conf.d/10-omarchy.conf"
oomd_system=$installed_path

install_repair \
  "$OMARCHY_PATH/default/systemd/user/app.slice.d/10-oomd.conf" \
  "$restore_root/usr/lib/systemd/user/app.slice.d/00-omarchy-mac-restore.conf" \
  "$restore_root/usr/lib/systemd/user/app.slice.d/10-oomd.conf" \
  "$restore_root/etc/systemd/user/app.slice.d/10-oomd.conf" \
  "$restore_root/etc/systemd/user/app.slice.d/00-omarchy-mac-restore.conf"
oomd_user=$installed_path

zswap_repair=""
if [[ -f $OMARCHY_PATH/install/helpers/zram.sh ]]; then
  source "$OMARCHY_PATH/install/helpers/zram.sh"
  if omarchy_zram_has_config; then
    install_repair \
      "$OMARCHY_PATH/etc/tmpfiles.d/omarchy-zswap.conf" \
      "$restore_root/etc/tmpfiles.d/00-omarchy-mac-zswap.conf" \
      "$restore_root/etc/tmpfiles.d/omarchy-zswap.conf"
    zswap_repair=$installed_path
  fi
fi

if [[ -n $oomd_system ]]; then
  # oomd reads its thresholds only at start. A unit that is not installed yet
  # has nothing to restart; the next boot picks up the drop-in.
  as_root systemctl try-restart systemd-oomd.service >/dev/null 2>&1 || true
fi

if [[ -n $oomd_user ]]; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if [[ -n $zswap_repair ]]; then
  as_root systemd-tmpfiles --create "$zswap_repair" >/dev/null 2>&1 || true
fi
