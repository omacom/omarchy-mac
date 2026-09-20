echo "Repair nested Snapper history after an earlier Mac root restore"

# The earlier missing-root marker may already be complete. The shared setup
# leaf verifies ancestry before reattaching a retained backend and keeps all
# history/custom retention when the repair cannot be proven safe.
if (( EUID == 0 )); then
  bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh"
else
  sudo env OMARCHY_PATH="$OMARCHY_PATH" bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh"
fi
