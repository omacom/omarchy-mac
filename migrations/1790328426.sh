echo "Give aarch64 machines the zram swap omarchy-settings configures"

# omarchy-settings configures swap on zram and tunes reclaim for it. x86_64 gets
# zram-generator from its installer; aarch64 platforms now list it in their
# default packages, so install it where the platform's defaults name it and
# start the swap it configures. Where the platform can't be told, it waits,
# changing nothing (75 leaves it pending without stopping later migrations).
defaults=$(omarchy-pkg-defaults) || exit 75
if grep -qx zram-generator <<<"$defaults"; then
  if omarchy-pkg-missing zram-generator; then
    omarchy-pkg-add zram-generator
  fi
  # Start the swap the generator configures, unless it is up already. With no
  # device configured there is no swap unit, and a masked one is the
  # administrator's choice: nothing to start. Anything else that stops the
  # start fails the migration, so it runs again.
  if ! systemctl is-active --quiet dev-zram0.swap; then
    sudo systemctl daemon-reload
    state=$(systemctl show -P LoadState dev-zram0.swap)
    case $state in
      loaded) sudo systemctl start dev-zram0.swap ;;
      not-found | masked) ;;
      *)
        echo "The zram swap unit is $state; fix it and run the migration again." >&2
        exit 1
        ;;
    esac
  fi
fi

# Earlier Mac setups copied the drop-in into /etc under the same name. An
# identical copy would only hide the packaged one's updates; a copy that
# differs is the administrator's and stays.
vendor="${OMARCHY_ZRAM_DROPIN_USR:-/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf}"
copy="${OMARCHY_ZRAM_DROPIN_ETC:-/etc/systemd/zram-generator.conf.d/90-omarchy.conf}"

if [[ -f $vendor && -f $copy && ! -L $copy ]] && cmp -s -- "$vendor" "$copy"; then
  sudo rm -f -- "$copy"
  sudo rmdir --ignore-fail-on-non-empty -- "${copy%/*}"
fi
