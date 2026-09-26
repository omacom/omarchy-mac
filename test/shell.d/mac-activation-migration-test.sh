#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The runtime's Mac activation migration runs omarchy-mac-migrate-bootstrap as
# root on Apple Silicon, passes its deferral (75) or failure on, and writes the
# machine-wide marker only once it succeeded.
migration=$ROOT/migrations/1790461245.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/bash\ncat "$FIXTURE/platform"\n' >"$tmp/bin/omarchy-hw-platform"
printf '#!/bin/bash\necho "bootstrap $*" >>"$FIXTURE/ran"\nexit "$(cat "$FIXTURE/status")"\n' >"$tmp/bin/omarchy-mac-migrate-bootstrap"
cat >"$tmp/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$FIXTURE/ran"
exec "$@"
SH
chmod 755 "$tmp/bin"/*
marker=$tmp/state/1790461245

run_migration() {
  rm -f "$tmp/ran"
  FIXTURE=$tmp PATH="$tmp/bin:$PATH" OMARCHY_PATH=$ROOT OMARCHY_MAC_ACTIVATION_MARKER=$marker bash -euo pipefail "$migration"
}

[[ $(stat -c %a "$migration") == 644 ]] || fail "the migration is mode 644"
head -n 1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo"

echo generic >"$tmp/platform"
echo 0 >"$tmp/status"
run_migration >/dev/null || fail "another platform: the migration completes"
[[ ! -e $tmp/ran && ! -e $marker ]] || fail "another platform: nothing runs" "$(cat "$tmp/ran" 2>/dev/null)"
pass "anything but an Apple Silicon Mac completes the migration and runs nothing"

echo apple-silicon >"$tmp/platform"
for status in 75 1; do
  echo "$status" >"$tmp/status"
  result=0
  run_migration >/dev/null 2>&1 || result=$?
  (( result == status )) && [[ ! -e $marker ]] || fail "a bootstrap exiting $status leaves the migration pending with that status" "status $result"
done
echo 0 >"$tmp/status"
run_migration >/dev/null || fail "a Mac: the migration completes once the bootstrap did"
[[ $(sed -n 1,2p "$tmp/ran") == $'sudo omarchy-mac-migrate-bootstrap\nbootstrap ' && -e $marker ]] ||
  fail "a Mac: the bootstrap runs as root, then the marker is written" "$(cat "$tmp/ran")"
run_migration >/dev/null || fail "another account: the migration completes"
[[ ! -e $tmp/ran ]] || fail "another account: nothing runs once the Mac migrated" "$(cat "$tmp/ran")"
pass "a Mac runs the bootstrap as root, stays pending while it defers or fails, and other accounts skip it once it ran"
