echo "Repair missing zram configuration on previously migrated installs"

# 1787669934 shipped before the missing-configuration repair. Users with its
# completion marker need a new migration, but must not have configured swap
# reactivated merely because this repair is new. Empty files and links also
# count as deliberate configuration, including administrator masks.
state_dir="${OMARCHY_MIGRATION_STATE:-$HOME/.local/state/omarchy/migrations}"
repair_pending="$state_dir/1789246530.zram-repair-pending"
if [[ ! -f $repair_pending ]]; then
  source "$OMARCHY_PATH/install/helpers/zram.sh"
  if omarchy_zram_has_config; then
    exit 0
  fi
  # A failed activation may already have installed the fallback. Remember that
  # this user started the repair so a retry cannot mistake it for a local choice.
  mkdir -p "$state_dir"
  touch "$repair_pending"
fi

# Only the unconfigured population needs the existing repair. It verifies the
# required package, preserves active swap, and honours masked or absent units.
bash -euo pipefail "$OMARCHY_PATH/migrations/1787669934.sh"
rm -f "$repair_pending"
