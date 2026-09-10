echo "Repair missing Snapper root setup after the required dependency update"

repair_missing_snapper_root() {
  local filesystem
  filesystem=$(stat -f -c %T /) || return $?
  if [[ $filesystem != "btrfs" ]]; then
    echo "Skipping Snapper setup: / is $filesystem, not btrfs."
    return 0
  fi

  # The older migration could complete while Snapper was absent. This new
  # marker retries those released installs after the package dependency update.
  # Missing required dependencies must leave the repair pending on btrfs.
  if ! command -v snapper >/dev/null 2>&1; then
    echo "Error: Snapper is required on btrfs. Complete the package update, then rerun omarchy-migrate." >&2
    return 127
  fi

  if (( EUID == 0 )); then
    bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh"
  else
    sudo env OMARCHY_PATH="$OMARCHY_PATH" bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh"
  fi
}

repair_missing_snapper_root
