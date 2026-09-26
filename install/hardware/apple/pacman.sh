# Legacy only: sourced by migration 1788200000 on Apple Silicon installs made
# before the signed [omarchy] repository carried Omarchy's aarch64 packages.
# Their pacman.conf had no Omarchy repository (the post-install restore skips
# the x86 pacman.conf and mirrorlist), so it adds the unsigned [omarchy-aarch64]
# that omarchy-pkgs-aarch64 publishes, with the SigLevel that repository
# documents. Fresh installs and images never run it: install/hardware/all.sh
# does not list it, and an image-built Mac takes every package signed from
# [omarchy], asahi-alarm and Arch Linux ARM, so it returns before touching
# anything there, including a queue an older image deferred. Runs as a user
# from the migration, hence the sudo fallback.
#
# Adding the stanza is not enough: pacman refuses to install from a repository
# whose database it has never fetched. The pending marker records a sync still
# owed, so a fetch that failed (no network yet) is retried on the next run
# instead of leaving a configured repository nothing can install from.
omarchy-hw-apple-silicon || return 0

image_dir=/var/lib/omarchy/image
if (( ${EUID:-$(id -u)} != 0 )); then
  image_dir=${OMARCHY_IMAGE_ROOT:-}$image_dir
fi
if [[ -e $image_dir/target || -e $image_dir/target.booted ]]; then
  return 0
fi

pacman_conf="${OMARCHY_PACMAN_CONF:-/etc/pacman.conf}"
sync_pending="${OMARCHY_AARCH64_REPO_PENDING:-/var/lib/omarchy/migrations/omarchy-aarch64-sync-pending}"
OMARCHY_AARCH64_REPO_ADDED=0

if (( ${EUID:-$(id -u)} == 0 )); then
  as_root=()
else
  as_root=(sudo)
fi

if ! grep -q '^\[omarchy-aarch64\]' "$pacman_conf"; then
  echo "Adding the [omarchy-aarch64] repository to $pacman_conf"
  "${as_root[@]}" install -Dm644 /dev/null "$sync_pending"
  "${as_root[@]}" tee -a "$pacman_conf" >/dev/null <<'REPO'

[omarchy-aarch64]
SigLevel = Optional TrustAll
Server = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/edge
REPO
  OMARCHY_AARCH64_REPO_ADDED=1
fi

if [[ -f $sync_pending ]]; then
  echo "Fetching the [omarchy-aarch64] package database"
  if ! "${as_root[@]}" pacman -Sy; then
    echo "Could not fetch the [omarchy-aarch64] database; it will be retried on the next run." >&2
    return 1
  fi
  "${as_root[@]}" rm -f -- "$sync_pending"
fi
