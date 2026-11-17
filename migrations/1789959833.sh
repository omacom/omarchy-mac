echo "Restore zram reclaim tunings stripped from the aarch64 settings package"

[[ $(uname -m) == "aarch64" ]] || exit 0

source "$OMARCHY_PATH/install/helpers/zram.sh"

omarchy_zram_has_config || exit 0
omarchy_zram_sysctl_applied && exit 0

dest=$(omarchy_zram_sysctl_path)
if [[ -e $dest || -L $dest ]]; then
  echo "Keeping $dest; it already exists."
  exit 0
fi

sudo env OMARCHY_PATH="$OMARCHY_PATH" \
  OMARCHY_ZRAM_ROOT="${OMARCHY_ZRAM_ROOT:-}" \
  OMARCHY_ZRAM_SYSCTL="${OMARCHY_ZRAM_SYSCTL:-}" \
  bash -c 'source "$OMARCHY_PATH/install/helpers/zram.sh" && omarchy_zram_write_sysctl'

# Boot applies the file regardless. Loading it now is best-effort, matching
# 1784961000: a live sysctl error is not worth holding the migration chain.
sudo sysctl -p "$dest" >/dev/null || true
