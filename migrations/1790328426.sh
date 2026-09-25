echo "Let the packaged zram drop-in configure swap on Apple Silicon"

# omarchy-settings used to leave the zram vendor drop-in out on aarch64, so
# migration 1789154627 copied it into /etc under the same name. The package
# ships it on every platform now, and an identical copy in /etc would only hide
# its later updates. A copy that differs is the administrator's and stays.
vendor="${OMARCHY_ZRAM_DROPIN_USR:-/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf}"
copy="${OMARCHY_ZRAM_DROPIN_ETC:-/etc/systemd/zram-generator.conf.d/90-omarchy.conf}"

[[ -f $vendor && -f $copy && ! -L $copy ]] || exit 0
cmp -s -- "$vendor" "$copy" || exit 0

sudo rm -f -- "$copy"
sudo rmdir --ignore-fail-on-non-empty -- "${copy%/*}"
