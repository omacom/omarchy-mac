#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

# With ttfx missing the script must report once and exit instead of
# respawning a missing command in a loop.
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/omarchy-cmd-missing"
chmod +x "$stub_dir/omarchy-cmd-missing"

status=0
output=$(PATH="$stub_dir:$PATH" timeout 5 "$ROOT/bin/omarchy-screensaver" 2>&1) || status=$?
(( status == 1 )) || fail "screensaver does not exit 1 when ttfx is missing (got $status)"
grep -q "not installed" <<<"$output" || fail "screensaver gives no message when ttfx is missing"
(( $(grep -c "not installed" <<<"$output") == 1 )) ||
  fail "screensaver reports the missing engine more than once"
pass "screensaver reports a missing ttfx once and exits"

# With ttfx present the guard passes through to the draw loop. pgrep sees a
# running ttfx; the focused window is not the screensaver, so the loop takes
# its normal focus-loss exit.
printf '#!/bin/bash\nexit 1\n' >"$stub_dir/omarchy-cmd-missing"
printf '#!/bin/bash\ntouch "${TTFX_MARKER:?}"\nsleep 60\n' >"$stub_dir/ttfx"
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/pgrep"
printf '#!/bin/bash\n[[ ${1:-} == activewindow ]] && printf "{}"\nexit 0\n' >"$stub_dir/hyprctl"
chmod +x "$stub_dir"/{omarchy-cmd-missing,ttfx,pgrep,hyprctl}
status=0
TTFX_MARKER="$stub_dir/ttfx-ran" PATH="$stub_dir:$PATH" timeout 5 "$ROOT/bin/omarchy-screensaver" >/dev/null 2>&1 || status=$?
[[ -f $stub_dir/ttfx-ran ]] || fail "screensaver never launches ttfx when present"
(( status == 0 )) || fail "screensaver exits uncleanly on focus loss (got $status)"
pass "screensaver proceeds to the draw loop when ttfx is present"
