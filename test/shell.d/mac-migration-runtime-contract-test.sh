#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
boot=$ROOT/packages/omarchy-mac/boot

# Cross-package agreement belongs to the runtime suite. The standalone boot
# package uses a frozen settings input so its behavioral migration tests need
# no surrounding desktop checkout; this assertion makes drift explicit.
cmp -s "$ROOT/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf" \
  "$boot/test/fixtures/migrate/00-omarchy-hooks.conf" ||
  fail "the migration fixture tracks the shipped settings HOOKS baseline"
pass "standalone migration fixture matches the runtime HOOKS baseline"

first_run_units=$(sed -n '/systemctl --user enable --now/,/[^\\]$/p' "$ROOT/install/user/first-run/enable-user-units.sh" | grep -o '[a-z0-9-]*\.service' | xargs)
engine_units=$(sed -n 's/^fresh_user_units="\(.*\)"$/\1/p' "$boot/lib/migrate-engine.sh")
[[ -n $first_run_units && $first_run_units == "$engine_units" ]] ||
  fail "the migration enables the user units first run enables" "first run: $first_run_units; migration: $engine_units"
pass "the migration's user units are first run's"

# The small command fixture is an interface sample, not a second package list.
# Keep its membership and base-versus-Apple distinctions honest as runtime
# defaults evolve; the package fixtures exercise availability and retries.
fixture=$boot/test/fixtures/migrate/bin/omarchy-pkg-defaults
runtime_generic=$(OMARCHY_PATH=$ROOT "$ROOT/bin/omarchy-pkg-defaults" generic)
fixture_generic=$("$fixture" generic)
for platform in generic apple-silicon; do
  runtime_defaults=$(OMARCHY_PATH=$ROOT "$ROOT/bin/omarchy-pkg-defaults" "$platform")
  while read -r package; do
    grep -Fxq "$package" <<<"$runtime_defaults" || fail "fixture package $package belongs to $platform defaults"
    if [[ $platform == "apple-silicon" ]] && ! grep -Fxq "$package" <<<"$fixture_generic"; then
      ! grep -Fxq "$package" <<<"$runtime_generic" || fail "fixture addition $package is not a base application"
    fi
  done < <("$fixture" "$platform")
done
pass "representative migration defaults retain the runtime platform contract"
