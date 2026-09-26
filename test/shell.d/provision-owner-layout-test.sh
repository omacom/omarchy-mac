#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# First-boot setup draws its form under the logo that clear_logo paints. The
# ISO draws it one row from the top of a ~48-row installer console; a HiDPI
# console (an Apple Silicon Mac lands on ~60-70 rows) must centre it instead
# of leaving it at the top. gum records the padding it is asked for, and stty
# reports the console size under test.

tmp=$(cd -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

omarchy=$tmp/omarchy
stub_bin=$tmp/bin
calls=$tmp/calls
mkdir -p "$omarchy/bin" "$omarchy/install/provisioning" "$stub_bin"
cp "$ROOT/logo.txt" "$omarchy/logo.txt"
cp "$ROOT/install/provisioning/luks-rekey.sh" "$ROOT/install/provisioning/luks-recovery.sh" "$omarchy/install/provisioning/"

cat >"$stub_bin/stty" <<'SH'
#!/bin/bash
printf '%s %s\n' "$LINES" "$COLUMNS"
SH
cat >"$stub_bin/gum" <<SH
#!/bin/bash
printf '%s\n' "\$*" | head -n 1 >>"$calls"
SH
chmod +x "$stub_bin"/*

export PATH="$stub_bin:$PATH"
export OMARCHY_PATH=$omarchy OMARCHY_PROVISION_OWNER_SOURCE=1
export OMARCHY_PROVISIONING_DIR=$tmp/provisioning OMARCHY_PROVISION_OWNER_LOG=$tmp/provision.log

# shellcheck disable=SC1091
source "$ROOT/bin/omarchy-provision-owner"

logo_padding() {
  export LINES=$1 COLUMNS=$2
  : >"$calls"
  clear_logo >/dev/null
  sed -n 's/^style --foreground 2 --padding \([0-9]*\) 0 0 [0-9]* .*/\1/p' "$calls"
}

[[ $(logo_padding 69 216) == 20 ]] || fail "a 16-inch Mac console centres the form" "$(cat "$calls")"
pass "a HiDPI Mac console centres the logo and form vertically"

[[ $(logo_padding 61 189) == 16 ]] || fail "a 14-inch Mac console centres the form" "$(cat "$calls")"
pass "a smaller Mac console centres the form too"

[[ $(logo_padding 30 100) == 1 ]] || fail "a console with no room to spare keeps the top row free" "$(cat "$calls")"
pass "a console the form fills keeps the ISO's one-row top margin"

[[ $(logo_padding 24 80) == 1 ]] || fail "a console shorter than the form never gets negative padding" "$(cat "$calls")"
pass "a console shorter than the form draws from the top as before"
