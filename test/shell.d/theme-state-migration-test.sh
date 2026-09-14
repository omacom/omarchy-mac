#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1781043107.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

home="$test_dir/home"
mkdir -p "$home/.config/omarchy/current/theme" "$home/.config/hypr"

# A legacy hyprlock.conf referencing the pre-migration state directory, and the
# assets it points at.
printf 'accent = mauve\n' >"$home/.config/omarchy/current/theme/hyprlock.conf"
printf 'png\n' >"$home/.config/omarchy/current/background"
cat >"$home/.config/hypr/hyprlock.conf" <<'EOF'
source = ~/.config/omarchy/current/theme/hyprlock.conf

background {
    path = ~/.config/omarchy/current/background
}
EOF

HOME="$home" bash -euo pipefail "$migration" >/dev/null

[[ -d $home/.local/state/omarchy/current ]] ||
  fail "migration does not move the current state directory"
[[ ! -e $home/.config/omarchy/current ]] ||
  fail "migration leaves the legacy current directory behind"
[[ -f $home/.local/state/omarchy/current/theme/hyprlock.conf ]] ||
  fail "migration loses the hyprlock theme asset"
grep -q 'source = ~/.local/state/omarchy/current/theme/hyprlock.conf' "$home/.config/hypr/hyprlock.conf" ||
  fail "migration leaves hyprlock.conf pointing at the removed directory"
grep -q 'path = ~/.local/state/omarchy/current/background' "$home/.config/hypr/hyprlock.conf" ||
  fail "migration leaves hyprlock.conf background pointing at the removed directory"
pass "migration rewrites hyprlock.conf to the new theme-state location"

# A hyprlock.conf already on the new paths is left alone.
run2_home="$test_dir/home2"
mkdir -p "$run2_home/.config/hypr"
printf 'source = ~/.local/state/omarchy/current/theme/hyprlock.conf\n' >"$run2_home/.config/hypr/hyprlock.conf"
HOME="$run2_home" bash -euo pipefail "$migration" >/dev/null
grep -q 'source = ~/.local/state/omarchy/current/theme/hyprlock.conf' "$run2_home/.config/hypr/hyprlock.conf" ||
  fail "migration mangles an already-migrated hyprlock.conf"
pass "migration is idempotent for an already-migrated hyprlock.conf"
