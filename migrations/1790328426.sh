echo "Give aarch64 machines the zram swap omarchy-settings now configures there"

# omarchy-settings used to leave its zram drop-in and reclaim tuning out on
# aarch64. It ships them on every platform now, and they expect swap on zram,
# so install the generator where this platform's default packages name it
# (x86_64 gets it from its installer) and start the device it configures.
if omarchy-pkg-defaults | grep -x zram-generator >/dev/null && omarchy-pkg-missing zram-generator; then
  omarchy-pkg-add zram-generator
  if ! systemctl is-active --quiet dev-zram0.swap; then
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service || true
  fi
fi

# Migration 1789154627 copied the drop-in into /etc on Macs under the same
# name. An identical copy would only hide the packaged one's updates; a copy
# that differs is the administrator's and stays.
vendor="${OMARCHY_ZRAM_DROPIN_USR:-/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf}"
copy="${OMARCHY_ZRAM_DROPIN_ETC:-/etc/systemd/zram-generator.conf.d/90-omarchy.conf}"

if [[ -f $vendor && -f $copy && ! -L $copy ]] && cmp -s -- "$vendor" "$copy"; then
  sudo rm -f -- "$copy"
  sudo rmdir --ignore-fail-on-non-empty -- "${copy%/*}"
fi
