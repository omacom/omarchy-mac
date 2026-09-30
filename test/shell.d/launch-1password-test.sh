#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ ${OMARCHY_TEST_INSTALLED:-false} == "true" ]]
SH

# One argument per line, so dropped or merged arguments show up.
cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
shift
printf '%s\n' launch "$@" >"$OMARCHY_TEST_LOG"
SH

cat >"$mock_bin/omarchy-launch-floating-terminal-with-presentation" <<'SH'
#!/bin/bash
printf 'install:%s\n' "$*" >"$OMARCHY_TEST_LOG"
SH

# The unfocused monitor comes first, so a launcher that ignores focus picks the
# wrong scale.
cat >"$mock_bin/hyprctl" <<'SH'
#!/bin/bash
[[ ${OMARCHY_TEST_HYPRCTL:-up} == "up" ]] || exit 1
case "$1" in
  getoption)
    printf '{"option": "%s", "bool": %s, "set": true}\n' "$2" "$OMARCHY_TEST_ZERO_SCALING"
    ;;
  monitors)
    printf '[{"name":"DP-1","focused":false,"scale":1.5},{"name":"eDP-1","focused":true,"scale":%s}]\n' "$OMARCHY_TEST_SCALE"
    ;;
esac
SH

chmod +x "$mock_bin"/*

launch_log="$test_tmp/launch-log"
url="onepassword://open/item with spaces"

launch() {
  rm -f "$launch_log"
  env PATH="$mock_bin:$PATH" OMARCHY_TEST_LOG="$launch_log" OMARCHY_TEST_INSTALLED=true \
    OMARCHY_TEST_ZERO_SCALING=true OMARCHY_TEST_SCALE=2 DISPLAY=:0 "$@" \
    bash "$ROOT/bin/omarchy-launch-1password" "$url"
}

expect_launch() {
  local description="$1"
  shift
  local expected

  expected=$(printf '%s\n' launch -- 1password "$@" "$url")
  [[ $(<"$launch_log") == "$expected" ]] || fail "$description" "$(<"$launch_log")"
  pass "$description"
}

launch
expect_launch "zero-scaled XWayland gets the focused monitor's scale and the URL" \
  --ozone-platform=x11 --force-device-scale-factor=2

launch OMARCHY_TEST_SCALE=1.666667
expect_launch "a fractional monitor scale is passed through unrounded" \
  --ozone-platform=x11 --force-device-scale-factor=1.666667

launch OMARCHY_TEST_ZERO_SCALING=false
expect_launch "XWayland scaled by Hyprland keeps 1Password at factor 1" \
  --ozone-platform=x11 --force-device-scale-factor=1

launch OMARCHY_TEST_HYPRCTL=down
expect_launch "an unreachable Hyprland falls back to factor 1" \
  --ozone-platform=x11 --force-device-scale-factor=1

launch OMARCHY_TEST_SCALE=null
expect_launch "a missing monitor scale falls back to factor 1" \
  --ozone-platform=x11 --force-device-scale-factor=1

launch DISPLAY=
expect_launch "without XWayland 1Password starts natively"

rm -f "$launch_log"
PATH="$mock_bin:$PATH" OMARCHY_TEST_INSTALLED=false OMARCHY_TEST_LOG="$launch_log" \
  bash "$ROOT/bin/omarchy-launch-1password"
grep -Fxq 'install:omarchy-install-service-1password' "$launch_log" ||
  fail "1Password launcher starts the installer when missing"
pass "1Password launcher starts the installer when missing"

grep -Fq '{ omarchy = "1password" }' "$ROOT/default/hypr/bindings/applications.lua" ||
  fail "1Password keybinding uses the conditional launcher"
pass "1Password keybinding uses the conditional launcher"
