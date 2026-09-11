#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/install/helpers/arm-package-sources.sh"

# Ubuntu's ordinary shell-test job has no pacman; the ARM install machine runs
# this test with real libalpm before attempting the network installation.
if ! command -v pacman >/dev/null; then
  pass 'pacman unavailable; package transaction regression runs in the ARM install machine'
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/db/local" "$test_tmp/db/sync"
printf '9\n' > "$test_tmp/db/local/ALPM_DB_VERSION"

write_desc() {
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\n%s\n\n' "$1" "$2" "$(uname -m)"
  printf '%%FILENAME%%\n%s-%s.pkg.tar.zst\n\n%%CSIZE%%\n1\n\n%%ISIZE%%\n1\n\n' "$1" "$2"
}
write_package() {
  local directory="$1/$2-$3"
  mkdir -p "$directory"
  write_desc "$2" "$3" > "$directory/desc"
}
for package in hyprland hyprtoolkit hyprland-guiutils normal; do
  write_package "$test_tmp/db/local" "$package" '2-1'
  : > "$test_tmp/db/local/$package-2-1/files"
  write_package "$test_tmp/extra" "$package" '4-1'
done
tar -czf "$test_tmp/db/sync/extra.db" -C "$test_tmp/extra" --transform='s|^\./||' .
cat > "$test_tmp/pacman.conf" <<CONF
[options]
Architecture = auto
DBPath = $test_tmp/db
LogFile = $test_tmp/pacman.log
SigLevel = Never
[extra]
Server = file:///nonexistent
[omarchy]
Usage = Sync
Server = file:///nonexistent
CONF

select_packages() {
  pacman --config "$test_tmp/pacman.conf" -Sup --needed --noconfirm \
    --print-format '%r/%n %v' "$@" 2> "$test_tmp/errors"
}
mapfile -t targets < <(omarchy_arm_package_upgrade_args)
for version in 2-1 3-1 1-1; do
  rm -rf "$test_tmp/omarchy"
  for package in hyprland hyprtoolkit hyprland-guiutils; do
    write_package "$test_tmp/omarchy" "$package" "$version"
  done
  tar -czf "$test_tmp/db/sync/omarchy.db" -C "$test_tmp/omarchy" --transform='s|^\./||' .
  selected=$(select_packages "${targets[@]}") || fail 'pacman resolves the protected transaction' "$(cat "$test_tmp/errors")"
  grep -qx 'extra/normal 4-1' <<< "$selected" || fail 'ordinary packages still upgrade'
  ! grep -q '^extra/hypr' <<< "$selected" || fail 'regular repository cannot replace the selected stack'
  if [[ $version == "2-1" ]]; then
    [[ $selected == 'extra/normal 4-1' ]] || fail 'unchanged compositor packages are not reinstalled'
    mapfile -t unprotected < <(omarchy_arm_package_targets)
    baseline=$(select_packages "${unprotected[@]}")
    grep -qx 'extra/hyprtoolkit 4-1' <<< "$baseline" || fail 'fixture reproduces the original --needed sysupgrade bug'
  else
    for package in hyprland hyprtoolkit hyprland-guiutils; do
      grep -qx "omarchy/$package $version" <<< "$selected" || fail 'changed packages use the explicit repository, including downgrades'
    done
  fi
  pass "real pacman preserves selected $version stack while upgrading ordinary packages"
done
