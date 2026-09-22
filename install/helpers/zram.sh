# An empty file or symlink may deliberately disable the generator. Check every
# main-file and drop-in location before supplying any new default.
omarchy_zram_has_config() {
  local root="${OMARCHY_ZRAM_ROOT:-}" directory config
  for directory in /etc /run /usr/local/lib /usr/lib; do
    for config in "$root$directory/systemd/zram-generator.conf" \
      "$root$directory/systemd/zram-generator.conf.d/"*.conf; do
      [[ ! -e $config && ! -L $config ]] || return 0
    done
  done
  return 1
}

# System setup runs as root. Publish only a complete configuration, and never
# replace a file an administrator created while the default was being staged.
# A failed copy leaves no partial main file that a retry could mistake for an
# administrator's deliberate empty configuration.
omarchy_zram_write_default() (
  local directory="${OMARCHY_ZRAM_ROOT:-}/etc/systemd" staging
  mkdir -p "$directory" || return 1
  staging=$(mktemp "$directory/.omarchy-zram-XXXXXXXX") || return 1
  trap 'rm -f "$staging"' EXIT
  install -m 0644 "$OMARCHY_PATH/default/systemd/zram-generator.conf.d/90-omarchy.conf" "$staging" || return 1
  if ! omarchy_zram_has_config; then
    ln -T -- "$staging" "$directory/zram-generator.conf" || return 1
  fi
)
