# Hardware setup installs platform packages from here on, so it starts only once
# omarchy-settings' pacman platform guard is resident: a hook that arrives in
# the same transaction as a package does not check it. On a fresh install the
# installer placed packages before this step, so they are checked here too.
# See docs/platform-guard.md.

hook=00-omarchy-platform-guard.hook
alpm_root=""
# Tests only: this runs as root during setup, where the environment decides nothing.
if (( EUID != 0 )); then
  alpm_root=${OMARCHY_ALPM_ROOT:-}
fi
guard="$alpm_root/usr/share/libalpm/scripts/omarchy-platform-guard"

if [[ ! -f $alpm_root/usr/share/libalpm/hooks/$hook || ! -x $guard ]]; then
  echo "Error: the pacman platform guard from omarchy-settings is not installed; install omarchy-settings in a transaction before hardware setup" >&2
  return 1
fi

# An administrator's override in the higher-priority hook directory, such as a
# /dev/null mask on a VM test system, turns the whole guard off.
if [[ -e $alpm_root/etc/pacman.d/hooks/$hook || -L $alpm_root/etc/pacman.d/hooks/$hook ]]; then
  echo "Warning: /etc/pacman.d/hooks/$hook overrides the pacman platform guard; installed packages are not checked"
else
  "$guard" --installed
fi
