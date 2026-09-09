#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/preflight/locale.sh"
migration=$(/usr/bin/grep -rl 'Give the machine a UTF-8 locale' "$ROOT/migrations" | head -n 1 || true)

[[ -f $leaf ]] || fail "the locale step ships"
[[ -n $migration ]] || fail "existing installs get the locale repair"

# Asahi Alarm ships LANG=C, so the installer has to set the locale itself --
# there is no ISO step here to do it.
/usr/bin/grep -q '^  ensure_utf8_locale$' "$ROOT/install/aarch64/install.sh" ||
  fail "the installer sets a UTF-8 locale"
locale_call=$(/usr/bin/grep -n '^  ensure_utf8_locale$' "$ROOT/install/aarch64/install.sh" | cut -d: -f1)
packages_call=$(/usr/bin/grep -n '^  install_default_package_set$' "$ROOT/install/aarch64/install.sh" | cut -d: -f1)
(( locale_call < packages_call )) ||
  fail "the locale is set before the install starts printing package output"
pass "the installer sets a UTF-8 locale before the package pass"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
locale_conf="$test_tmp/etc/locale.conf"
locale_gen="$test_tmp/etc/locale.gen"
mkdir -p "$stub_bin" "$test_tmp/etc"

# GENERATED_LOCALES stands in for what the machine already has built.
cat >"$stub_bin/locale" <<'SH'
#!/bin/bash

[[ ${1:-} == "-a" ]] || exit 0
printf '%s\n' ${GENERATED_LOCALES:-C}
SH

cat >"$stub_bin/locale-gen" <<'SH'
#!/bin/bash

printf 'locale-gen\n' >>"$TEST_LOG"
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

"$@"
SH

chmod +x "$stub_bin"/*

run_leaf() {
  : >"$calls"
  GENERATED_LOCALES="${1:-C}" TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    OMARCHY_LOCALE_CONF="$locale_conf" OMARCHY_LOCALE_GEN="$locale_gen" \
    bash -euo pipefail -c 'source "$1"' bash "$leaf" >/dev/null
}

# A stock Asahi Alarm machine: LANG=C, nothing enabled in locale.gen.
printf 'LANG=C\n' >"$locale_conf"
printf '#en_US.UTF-8 UTF-8\n#de_DE.UTF-8 UTF-8\n' >"$locale_gen"
run_leaf C
/usr/bin/grep -qx 'LANG=en_US.UTF-8' "$locale_conf" || fail "a C locale is replaced with UTF-8" "$(cat "$locale_conf")"
/usr/bin/grep -qx 'en_US.UTF-8 UTF-8' "$locale_gen" || fail "en_US.UTF-8 is enabled in locale.gen" "$(cat "$locale_gen")"
/usr/bin/grep -qx '#de_DE.UTF-8 UTF-8' "$locale_gen" || fail "other locales are left commented" "$(cat "$locale_gen")"
/usr/bin/grep -qx 'locale-gen' "$calls" || fail "the locale is generated" "$(cat "$calls")"
pass "a stock LANG=C machine gets en_US.UTF-8"

# Only the stock state is repaired. Every named locale is somebody's choice --
# including C.UTF-8, and including one that is not UTF-8 at all.
for chosen in en_DK.UTF-8 C.UTF-8 en_US.ISO-8859-1; do
  printf 'LANG=%s\n' "$chosen" >"$locale_conf"
  run_leaf "C en_DK.utf8 C.utf8"
  /usr/bin/grep -qx "LANG=$chosen" "$locale_conf" || fail "a chosen locale is left alone" "$chosen -> $(cat "$locale_conf")"
  [[ ! -s $calls ]] || fail "a chosen locale is not regenerated" "$chosen: $(cat "$calls")"
done
pass "a machine with a chosen locale is left alone"

# POSIX is the same stock state under another name, and a missing file means
# the system never had one set.
printf 'LANG=POSIX\n' >"$locale_conf"
run_leaf C
/usr/bin/grep -qx 'LANG=en_US.UTF-8' "$locale_conf" || fail "a POSIX locale is repaired" "$(cat "$locale_conf")"

rm -f "$locale_conf"
run_leaf C
/usr/bin/grep -qx 'LANG=en_US.UTF-8' "$locale_conf" || fail "a machine with no locale.conf is repaired" "$(cat "$locale_conf" 2>&1)"
pass "POSIX and an absent locale.conf count as stock"

# Already generated, just not selected: set it without a rebuild.
printf 'LANG=C\n' >"$locale_conf"
run_leaf "C en_US.utf8"
/usr/bin/grep -qx 'LANG=en_US.UTF-8' "$locale_conf" || fail "an available locale is selected" "$(cat "$locale_conf")"
[[ ! -s $calls ]] || fail "a generated locale is not regenerated" "$(cat "$calls")"
pass "a generated locale is selected without rebuilding"

# Second pass over a repaired machine changes nothing.
run_leaf "C en_US.utf8"
(( $(/usr/bin/grep -c . "$locale_conf") == 1 )) || fail "the locale step is idempotent" "$(cat "$locale_conf")"
pass "the locale step is idempotent"

# Existing installs never ran the leaf, so the migration is their only route.
run_migration() {
  : >"$calls"
  mkdir -p "$test_tmp/omarchy/install/preflight"
  cp "$leaf" "$test_tmp/omarchy/install/preflight/locale.sh"

  GENERATED_LOCALES="${1:-C}" TEST_LOG="$calls" PATH="$stub_bin:$PATH" \
    OMARCHY_PATH="$test_tmp/omarchy" OMARCHY_LOCALE_CONF="$locale_conf" OMARCHY_LOCALE_GEN="$locale_gen" \
    bash -euo pipefail "$migration"
}

printf 'LANG=C\n' >"$locale_conf"
printf '#en_US.UTF-8 UTF-8\n' >"$locale_gen"
output=$(run_migration C)
/usr/bin/grep -qx 'LANG=en_US.UTF-8' "$locale_conf" || fail "the migration repairs a LANG=C install" "$(cat "$locale_conf")"
/usr/bin/grep -q 'Log out and back in' <<<"$output" || fail "the migration says the session needs a re-login" "$output"
pass "the migration repairs a LANG=C install"

output=$(run_migration "C en_US.utf8")
/usr/bin/grep -q 'Log out and back in' <<<"$output" &&
  fail "a repaired install is not told to log out again" "$output"
pass "the migration stays quiet once the locale is UTF-8"
