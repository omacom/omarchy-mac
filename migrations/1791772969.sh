echo "Re-enable zswap in front of zram swap"

# The boot-time zswap disable shipped on the assumption that zswap in front
# of swap-on-zram only double-compresses. Measured on Apple Silicon (kernel
# 7.1.12, 16K pages, zram zstd): a 12GB workload capped at 3GB of RAM swaps
# out ~9GB and then churns ~6GB of random faults; with zswap enabled the run
# is consistently ~20% faster (alloc 2.4-2.5s vs 3.0-3.1s, churn 3.2s vs
# 3.7-3.8s) AND uses ~14% less in-task CPU (5.87-5.90s vs 6.83s), because
# the zswap pool (lzo/lz4) absorbs the hot working set and batches the zstd
# writeback to zram. The disable also never shipped a way back on for
# machines that had it applied.

# Hardware detection: zswap in front of zram is a measured WIN on Apple
# Silicon (M2 Pro: ~20% faster swap churn, ~14% less CPU) but a measured
# LOSS on older x86 CPUs (2015 Intel i5-5257U: ~35% slower alloc, up to
# +55% task CPU — double compression burns CPU those machines cannot
# spare). omarchy-mac ships only for aarch64 Apple machines, so the guard
# is exact; it also keeps the migration harmless if it ever runs anywhere
# else.
[[ ${OMARCHY_ZSWAP_ARCH:-$(uname -m)} == "aarch64" ]] || exit 0

conf="${OMARCHY_ZSWAP_CONF:-/etc/tmpfiles.d/omarchy-zswap.conf}"
node="${OMARCHY_ZSWAP_ENABLED_NODE:-/sys/module/zswap/parameters/enabled}"

removed=0
# Remove only the file as we shipped it; an edited copy is an admin choice.
if [[ -f $conf ]] && grep -q 'zswap/parameters/enabled - - - - N' "$conf"; then
  sudo rm -f "$conf"
  removed=1
fi

# Live re-enable only when OUR disable was actually present: a machine where
# an admin turned zswap off by hand keeps it off, and the kernel default
# (Arch ships zswap=y) covers the next boot either way. The write goes
# through sudo — a plain-user writability probe on the sysfs node would
# always fail and silently skip the fix.
if (( removed )) && [[ -e $node ]]; then
  echo Y | sudo tee "$node" >/dev/null 2>&1 || true
fi
