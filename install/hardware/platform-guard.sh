# Hardware setup installs platform packages from here on, so on a machine that
# has any (Apple Silicon, Qualcomm) it starts only once omarchy-settings' pacman
# platform guard is resident: a hook that arrives in the same transaction as a
# package does not check it. Packages an installer placed before this step are
# checked here too. See docs/platform-guard.md.

hook=00-omarchy-platform-guard.hook
alpm_root=""
# Tests only: this runs as root during setup, where the environment decides nothing.
if (( EUID != 0 )); then
  alpm_root=${OMARCHY_ALPM_ROOT:-}
fi
guard="$alpm_root/usr/share/libalpm/scripts/omarchy-platform-guard"

if [[ ! -f $alpm_root/usr/share/libalpm/hooks/$hook || ! -x $guard ]]; then
  # A settings package from before the guard (the dev pair is not version
  # locked to the runtime) leaves nothing platform-specific unguarded on
  # machines without platform packages.
  if ! platform=$(omarchy-hw-platform); then
    echo "Error: the pacman platform guard is not installed and this machine's platform cannot be told" >&2
    return 1
  fi
  if [[ $platform == "apple-silicon" || $platform == "qualcomm" ]]; then
    echo "Error: the pacman platform guard from omarchy-settings is not installed; install omarchy-settings in a transaction before hardware setup" >&2
    return 1
  fi
  echo "Warning: the pacman platform guard from omarchy-settings is not installed; continuing on $platform, which has no platform packages"
  return 0
fi

# An administrator's override in the higher-priority hook directory, such as a
# /dev/null mask on a VM test system, turns the whole guard off.
if [[ -e $alpm_root/etc/pacman.d/hooks/$hook || -L $alpm_root/etc/pacman.d/hooks/$hook ]]; then
  echo "Warning: /etc/pacman.d/hooks/$hook overrides the pacman platform guard; installed packages are not checked"
else
  "$guard" --installed
fi
