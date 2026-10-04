echo "Repair zram swap on Macs whose zram migrations were pre-marked"

# Early aarch64 installs ran omarchy-provision-user --first-install, which
# marks every shipped migration complete without running it. Their zram setup
# and repair migrations (1773113401, 1784961000, 1785013000, 1787669934) are
# therefore marked done with the effect never applied, and since the runner
# keys on the marker filename, the in-place repair of 1787669934 never
# re-runs on exactly the machines that need it. This new filename re-applies
# the same idempotent repair. On already-healthy machines every step below is
# a no-op.

if omarchy-pkg-missing zram-generator; then
  omarchy-pkg-add zram-generator
  # The ARM package helper can skip unavailable packages successfully, but
  # this repair requires the generator before it can be marked complete.
  if omarchy-pkg-missing zram-generator; then
    echo "zram-generator is still missing; the zram repair will be retried." >&2
    exit 1
  fi
fi

# Supply a fallback main config only on unconfigured machines; even an empty
# file or a /dev/null mask can be an administrator's decision to disable zram.
# Keep /usr/lib package-owned so a corrected settings package can install its
# vendor drop-in without a file conflict; that drop-in takes precedence later.
zram_root="${OMARCHY_ZRAM_ROOT:-}"
source "$OMARCHY_PATH/install/helpers/zram.sh"

if ! omarchy_zram_has_config; then
  sudo install -D -m 0644 "$OMARCHY_PATH/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
    "$zram_root/etc/systemd/zram-generator.conf"
fi

# An active device still needs persistent configuration for the next boot.
if systemctl is-active --quiet dev-zram0.swap; then
  exit 0
fi

# Installing the package after boot does not run the generated unit until the
# manager reloads. Start the swap unit, not just the device setup service, so
# swap is actually enabled. The generator may deliberately omit zram0 because
# of local configuration or the systemd.zram kernel command-line switch.
sudo systemctl daemon-reload
zram_load_state=$(systemctl show --property=LoadState --value dev-zram0.swap)
case "$zram_load_state" in
  not-found | masked)
    echo "No loadable zram0 swap unit; keeping the current configuration"
    ;;
  *)
    sudo systemctl start dev-zram0.swap
    ;;
esac
