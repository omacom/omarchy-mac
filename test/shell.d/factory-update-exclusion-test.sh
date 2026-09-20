#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir "$test_tmp/bin" "$test_tmp/runtime"
maintenance="$test_tmp/maintenance.lock"
: >"$maintenance"
# Only redirect the absolute system lock into this isolated fixture. flock
# and descriptor inheritance are real; no root/system path is writable here.
sed "s|/var/lib/omarchy/factory-reset.lock|$maintenance|g" "$ROOT/bin/omarchy-update-lock" >"$test_tmp/update-lock"
cat >"$test_tmp/bin/stat" <<'STUB'
#!/bin/bash
if [[ $1 == -c && $2 == %u ]]; then echo 0; else /usr/bin/stat "$@"; fi
STUB
chmod +x "$test_tmp/bin/stat" "$test_tmp/update-lock"
export PATH="$test_tmp/bin:$PATH" XDG_RUNTIME_DIR="$test_tmp/runtime"
exec {exclusive}<>"$maintenance"
flock -xn "$exclusive"
if bash "$test_tmp/update-lock" run true; then fail 'reset exclusive lock must block update'; fi
flock -u "$exclusive"
exec {exclusive}>&-
pass 'factory exclusive maintenance lock blocks actual update wrapper'
printf 'pending fixture-root fixture-next\n' >"$maintenance"
if bash "$test_tmp/update-lock" run true; then fail 'pending reset must block update after process exit'; fi
: >"$maintenance"
pass 'staged reset remains blocked until reboot wipe clears marker'
cat >"$test_tmp/inside-update" <<'SCRIPT'
#!/bin/bash
set -e
# The update's inherited shared maintenance lock excludes a factory reset.
if flock -xn "$1" true; then exit 91; fi
# Its own migration can still take the separate recovery-layout lock.
flock -xn "$2" true
SCRIPT
bash "$test_tmp/update-lock" run bash "$test_tmp/inside-update" "$maintenance" "$test_tmp/recovery.lock"
pass 'running update excludes reset but permits its own recovery migration lock'
rm "$maintenance"
bash "$test_tmp/update-lock" run true
pass 'first update before stable maintenance lock creation retains existing behavior'
