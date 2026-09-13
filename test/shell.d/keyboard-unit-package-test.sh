#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"
source "$ROOT/build-packages.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
recipe="$test_tmp/PKGBUILD"
cat >"$recipe" <<'SH'
package() {
  install -Dm644 default/systemd/user/bt-agent.service "$pkgdir/usr/lib/systemd/user/bt-agent.service"
}
SH
ensure_keyboard_backlight_unit "$recipe"
cp "$recipe" "$test_tmp/once"
ensure_keyboard_backlight_unit "$recipe"
cmp "$recipe" "$test_tmp/once" || fail "keyboard-unit adaptation is idempotent"
pass "keyboard-unit adaptation accepts an already corrected recipe"

(
  cd "$ROOT"
  pkgdir="$test_tmp/package"
  source "$recipe"
  package
)
unit=omarchy-brightness-keyboard-auto.service
cmp "$ROOT/default/systemd/user/$unit" "$test_tmp/package/usr/lib/systemd/user/$unit" ||
  fail "settings package delivers the source keyboard unit at the native systemd path"
[[ $(stat -c %a "$test_tmp/package/usr/lib/systemd/user/$unit") == 644 ]] ||
  fail "keyboard unit has package permissions 0644"
pass "adapted package stages the required unit bytes and permissions"

for mismatch in missing-anchor unfamiliar-install duplicate-anchor; do
  case "$mismatch" in
    missing-anchor) printf 'package() { :; }\n' >"$recipe" ;;
    unfamiliar-install)
      sed "/$unit/d" "$test_tmp/once" >"$recipe"
      printf '# %s\n' "$unit" >>"$recipe"
      ;;
    duplicate-anchor)
      sed "/$unit/d" "$test_tmp/once" >"$recipe"
      sed -n '/install -Dm644/p' "$recipe" >>"$recipe.extra"
      cat "$recipe.extra" >>"$recipe"
      ;;
  esac
  if (ensure_keyboard_backlight_unit "$recipe") >"$test_tmp/output" 2>&1; then
    fail "keyboard-unit adaptation rejects $mismatch"
  fi
done
pass "keyboard-unit adaptation fails closed when the recipe no longer matches"
