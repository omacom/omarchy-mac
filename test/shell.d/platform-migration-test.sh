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

marker=$tmp/state/1790347292

run_migration() {
  rm -f "$tmp/ran"
  FIXTURE=$tmp PATH="$tmp/bin:$PATH" OMARCHY_PATH=$ROOT OMARCHY_PLATFORM_MIGRATION_MARKER=$marker bash -euo pipefail "$migration"
}

[[ $(stat -c %a "$migration") == 644 ]] || fail "the migration is mode 644"
head -n 1 "$migration" | grep -q '^echo ' || fail "the migration starts with an echo"

: >"$tmp/resolves"
run_migration >/dev/null || fail "no entrypoint: the migration completes"
[[ ! -e $tmp/ran && ! -e $marker ]] || fail "no entrypoint: nothing runs and no marker is written" "$(cat "$tmp/ran")"
pass "a platform without a migrate entrypoint completes the migration and runs nothing"

echo /usr/lib/omarchy/mac-boot/migrate >"$tmp/resolves"
echo 2 >"$tmp/status"
if run_migration >/dev/null 2>&1; then fail "a refused platform migration leaves the migration pending"; fi
[[ ! -e $marker ]] || fail "a refused platform migration writes no marker"
echo 0 >"$tmp/status"
run_migration >/dev/null || fail "an entrypoint: the migration completes"
[[ $(sed -n 1,2p "$tmp/ran") == $'sudo omarchy-lifecycle-dispatch migrate\ndispatch migrate' && -e $marker ]] ||
  fail "an entrypoint: dispatched as root, then the marker" "$(cat "$tmp/ran")"
run_migration >/dev/null || fail "another account: the migration completes"
[[ ! -e $tmp/ran ]] || fail "another account: nothing runs once the machine migrated" "$(cat "$tmp/ran")"
rm "$marker"
pass "a platform migration runs through the dispatcher as root, its refusal keeps the migration pending, and other accounts skip it once it ran"

: >"$tmp/undetermined"
if run_migration >/dev/null 2>&1; then fail "an undetermined platform leaves the migration pending"; fi
[[ ! -e $tmp/ran ]] || fail "an undetermined platform runs nothing"
pass "an undetermined platform fails the migration instead of skipping it"

# Through the real dispatcher on every platform fixture: x86, generic aarch64
# and Qualcomm run nothing even with a migrate entrypoint on disk, and neither
# does a Mac without its boot package. A Mac with one runs it as root whenever
# the migration runs without the marker, so a rerun is the entrypoint's own
# idempotent resume.
require_platform_fixtures "the platform migration through lifecycle dispatch"
for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$tmp/$platform" "$platform"
done
mkdir -p "$tmp/sudo-bin" "$tmp/lifecycle/usr/lib/omarchy/mac-boot" "$tmp/none"
cp "$tmp/bin/sudo" "$tmp/sudo-bin/sudo"
printf '#!/bin/bash\necho migrate >>%q\n' "$tmp/ran" >"$tmp/lifecycle/usr/lib/omarchy/mac-boot/migrate"
chmod 755 "$tmp/lifecycle/usr/lib/omarchy/mac-boot/migrate"
chmod -R go-w "$tmp/lifecycle"

migrate_on() {
  local platform=$1 lifecycle=$2
  rm -f "$tmp/ran" "$marker"
  FIXTURE=$tmp OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_LIFECYCLE_ROOT="$lifecycle" OMARCHY_PLATFORM_MIGRATION_MARKER=$marker \
    PATH="$tmp/$platform/bin:$tmp/sudo-bin:$ROOT/bin:$PATH" OMARCHY_PATH=$ROOT bash -euo pipefail "$migration"
}

for platform in generic generic-aarch64 qualcomm; do
  migrate_on "$platform" "$tmp/lifecycle" >/dev/null || fail "$platform: the migration completes"
  [[ ! -e $tmp/ran && ! -e $marker ]] || fail "$platform: nothing runs" "$(cat "$tmp/ran")"
done
migrate_on apple-silicon "$tmp/none" >/dev/null || fail "apple without the boot package: the migration completes"
[[ ! -e $tmp/ran ]] || fail "apple without the boot package: nothing runs" "$(cat "$tmp/ran")"
pass "x86, generic aarch64, Qualcomm and a Mac without its boot package complete the migration and run nothing"

for run in first second; do
  migrate_on apple-silicon "$tmp/lifecycle" >/dev/null || fail "apple: the $run run completes"
  [[ $(sed -n 1,2p "$tmp/ran") == "sudo omarchy-lifecycle-dispatch migrate"$'\n'"migrate" && -e $marker ]] ||
    fail "apple: the $run run hands the machine to the boot package as root" "$(cat "$tmp/ran")"
done
pass "a Mac with its boot package runs the migrate entrypoint as root, again on a rerun without the marker"
