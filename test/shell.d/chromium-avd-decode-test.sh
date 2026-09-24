#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1789045438.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

home="$test_dir/home"
mkdir -p "$home/.config"

run_migration() {
  HOME="$home" bash -euo pipefail "$migration" >/dev/null
}

conf="$home/.config/brave-flags.conf"
flag="--disable-features=AcceleratedVideoDecoder"

# A plain flags file gets the workaround appended.
printf -- '--ozone-platform=wayland\n' >"$conf"
run_migration
grep -qxF -- "$flag" "$conf" || fail "migration does not append the decode workaround"
pass "migration appends the decode workaround to a plain flags file"

# An existing --disable-features list is extended, not shadowed by a second
# argument Chromium would read instead of it.
printf -- '--disable-features=SomeOtherThing\n' >"$conf"
run_migration
grep -qxF -- '--disable-features=SomeOtherThing,AcceleratedVideoDecoder' "$conf" ||
  fail "migration does not merge into an existing disable-features list"
pass "migration merges into an existing disable-features list"

# Already disabled means untouched, and a rerun stays a no-op.
printf '%s\n' "$flag" >"$conf"
before=$(sha256sum "$conf" | cut -d' ' -f1)
run_migration
run_migration
[[ $(sha256sum "$conf" | cut -d' ' -f1) == "$before" ]] ||
  fail "migration is not idempotent over an already-disabled file"
pass "migration is idempotent over an already-disabled file"

# Every browser flags file in the config dir is covered.
for extra in brave-origin-flags.conf chrome-flags.conf chromium-flags.conf; do
  printf -- '--ozone-platform=wayland\n' >"$home/.config/$extra"
done
run_migration
for extra in brave-origin-flags.conf chrome-flags.conf chromium-flags.conf; do
  grep -qxF -- "$flag" "$home/.config/$extra" || fail "migration misses $extra"
done
pass "migration covers every installed browser flags file"

# A config directory with no flags files is a clean no-op.
rm -f "$home"/.config/*-flags.conf
run_migration || fail "migration fails with no flags files present"
pass "migration no-ops when no browser flags files exist"
