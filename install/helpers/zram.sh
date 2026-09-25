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

# The aarch64 omarchy-settings package rewrites 99-omarchy-sysctl.conf down to
# tcp_mtu_probing, on the assumption that ARM has no zram. Migrations and
# fresh ARM setup do configure zram, so the vm.* reclaim tunings belong in a
# separate drop-in the settings package does not own.
omarchy_zram_sysctl_path() {
  printf '%s\n' "${OMARCHY_ZRAM_SYSCTL:-${OMARCHY_ZRAM_ROOT:-}/etc/sysctl.d/99-omarchy-zram.conf}"
}

omarchy_zram_sysctl_applied() {
  local dest
  dest=$(omarchy_zram_sysctl_path)
  [[ -f $dest ]] || return 1
  grep -qx 'vm.swappiness=150' "$dest" || return 1
  grep -qx 'vm.page-cluster=0' "$dest" || return 1
}

omarchy_zram_sysctl_contents() {
  cat <<'EOF'
# Tune reclaim for swap on zram, which is orders of magnitude faster than the
# disk swapfile these defaults assume.

# Anything above 100 tells the kernel that evicting an anonymous page is
# cheaper than dropping a page-cache page it would have to re-read from disk.
# With a compressed RAM device that is true, so the disk-era default of 60
# leaves the page cache starved. Stop at 150: every page swapped still costs
# a compression now and a decompression on fault-back.
vm.swappiness=150

# Halve the eagerness to drop dentry/inode cache, which is costly to rebuild
# and can't spill to zram. Not lower: 0 can OOM.
vm.vfs_cache_pressure=50

# Read one page per swap-in fault. The default of 8 pays for a seek that zram
# doesn't have, and every extra page costs a separate decompression.
vm.page-cluster=0

# Don't let external fragmentation raise the watermarks, which produces
# reclaim bursts while memory is still free.
vm.watermark_boost_factor=0

# Keep ~1.25% of memory free instead of 0.1%, so kswapd reclaims in the
# background rather than letting allocations stall in direct reclaim.
vm.watermark_scale_factor=125

# Cap dirty pages at 64M/256M instead of the default 10%/20% of RAM, which
# lets gigabytes of writeback pile up and flush in stalling bursts.
vm.dirty_background_bytes=67108864
vm.dirty_bytes=268435456

# With bursts bounded above, the flusher can wake every 15s instead of 5s.
vm.dirty_writeback_centisecs=1500
EOF
}

omarchy_zram_write_sysctl() (
  local dest directory staging
  dest=$(omarchy_zram_sysctl_path)
  omarchy_zram_sysctl_applied && return 0
  [[ -e $dest || -L $dest ]] && return 0
  directory=$(dirname "$dest")
  mkdir -p "$directory" || return 1
  staging=$(mktemp "$directory/.omarchy-zram-sysctl-XXXXXXXX") || return 1
  trap 'rm -f "$staging"' EXIT
  omarchy_zram_sysctl_contents >"$staging" || return 1
  chmod 644 "$staging" || return 1
  ln -T -- "$staging" "$dest"
)
