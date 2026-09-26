#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The platform migration is one dispatch line: it hands the machine to the
# boot package's migrate entrypoint where there is one, does nothing elsewhere,
# and stays pending when the platform cannot be told.
migration=$ROOT/migrations/1790347292.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/omarchy-lifecycle-dispatch" <<'SH'
#!/bin/bash
if [[ $1 == "--resolve" ]]; then
  [[ ! -e $FIXTURE/undetermined ]] || { echo "Error: cannot determine the hardware platform for migrate" >&2; exit 1; }
  cat "$FIXTURE/resolves"
  exit 0
fi
echo "dispatch $*" >>"$FIXTURE/ran"
exit "$(cat "$FIXTURE/status")"
SH
cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$FIXTURE/ran"
exec "$@"
SH
chmod 755 "$tmp/bin"/*
echo 0 >"$tmp/status"

run_migration() {
  rm -f "$tmp/ran"
  FIXTURE=$tmp PATH="$tmp/bin:$PATH" OMARCHY_PATH=$ROOT bash -euo pipefail "$migration"
}

[[ $(stat -c %a "$migration") == 644 ]] || fail "the migration is mode 644"
head -n 1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo"

: >"$tmp/resolves"
run_migration >/dev/null || fail "no entrypoint: the migration completes"
[[ ! -e $tmp/ran ]] || fail "no entrypoint: nothing runs" "$(cat "$tmp/ran")"
pass "a platform without a migrate entrypoint completes the migration and runs nothing"

echo /usr/lib/omarchy/mac-boot/migrate >"$tmp/resolves"
run_migration >/dev/null || fail "an entrypoint: the migration completes"
[[ $(cat "$tmp/ran") == $'sudo omarchy-lifecycle-dispatch migrate\ndispatch migrate' ]] || fail "an entrypoint: dispatched as root" "$(cat "$tmp/ran")"
echo 2 >"$tmp/status"
if run_migration >/dev/null 2>&1; then fail "a refused platform migration leaves the migration pending"; fi
echo 0 >"$tmp/status"
pass "a platform migration runs through the dispatcher as root, and its refusal keeps the migration pending"

: >"$tmp/undetermined"
if run_migration >/dev/null 2>&1; then fail "an undetermined platform leaves the migration pending"; fi
[[ ! -e $tmp/ran ]] || fail "an undetermined platform runs nothing"
pass "an undetermined platform fails the migration instead of skipping it"
