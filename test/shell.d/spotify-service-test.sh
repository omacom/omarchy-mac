#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
installed_dir="$test_tmp/installed"
package_log="$test_tmp/package-log"
webapp_log="$test_tmp/webapp-log"
launch_log="$test_tmp/launch-log"
native_log="$test_tmp/native-log"
mkdir -p "$mock_bin" "$test_home" "$installed_dir"

cat >"$mock_bin/uname" <<'SH'
#!/bin/bash
printf '%s\n' "${OMARCHY_TEST_ARCH:-aarch64}"
SH

cat >"$mock_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_PACKAGE_LOG"
[[ ${OMARCHY_TEST_INSTALL_FAIL:-false} != "true" ]] || exit 1
[[ ${OMARCHY_TEST_INSTALL_FALSE_SUCCESS:-false} != "true" ]] || exit 0
touch "$OMARCHY_TEST_INSTALLED_DIR/spotify"
SH

cat >"$mock_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
[[ -e $OMARCHY_TEST_INSTALLED_DIR/$1 ]]
SH

cat >"$mock_bin/omarchy-webapp-install" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >>"$OMARCHY_TEST_WEBAPP_LOG"
[[ ${OMARCHY_TEST_WEBAPP_FAIL:-false} != "true" ]] || exit 1
[[ ${OMARCHY_TEST_WEBAPP_FALSE_SUCCESS:-false} != "true" ]] || exit 0
desktop_file="$HOME/.local/share/applications/Spotify.desktop"
mkdir -p "${desktop_file%/*}"
printf '%s\n' \
  '[Desktop Entry]' \
  'Name=Spotify' \
  'Exec=omarchy-launch-webapp https://open.spotify.com' \
  'Icon=Spotify.png' >"$desktop_file"
SH

cat >"$mock_bin/omarchy-launch-webapp" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >>"$OMARCHY_TEST_LAUNCH_LOG"
SH

cat >"$mock_bin/uwsm-app" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >>"$OMARCHY_TEST_NATIVE_LOG"
SH

cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
"$@"
SH

chmod +x "$mock_bin"/*

export HOME="$test_home"
export PATH="$mock_bin:$ROOT/bin:$PATH"
export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_INSTALLED_DIR="$installed_dir"
export OMARCHY_TEST_PACKAGE_LOG="$package_log"
export OMARCHY_TEST_WEBAPP_LOG="$webapp_log"
export OMARCHY_TEST_LAUNCH_LOG="$launch_log"
export OMARCHY_TEST_NATIVE_LOG="$native_log"

assert_empty_log() {
  local log_file="$1"
  [[ ! -s $log_file ]] || fail "no calls recorded in $log_file" "$(tr '\0' ' ' <"$log_file")"
}

assert_webapp_args() {
  local -a args
  mapfile -d '' -t args <"$webapp_log"
  ((${#args[@]} == 3)) || fail "webapp installer receives exactly three arguments"
  [[ ${args[0]} == "Spotify" ]] || fail "webapp installer receives the Spotify name"
  [[ ${args[1]} == "https://open.spotify.com" ]] || fail "webapp installer receives the Spotify URL"
  [[ ${args[2]} == "Spotify.png" ]] || fail "webapp installer receives the packaged Spotify icon"
}

wait_for_log() {
  local log_file="$1"
  local attempt=1
  while ((attempt <= 20)); do
    [[ -s $log_file ]] && return 0
    sleep 0.05
    ((attempt++))
  done
  fail "background launch writes its log" "$log_file"
}

OMARCHY_TEST_ARCH=aarch64 omarchy-install-service-spotify >"$test_tmp/arm-success" 2>&1
assert_empty_log "$package_log"
assert_empty_log "$native_log"
assert_webapp_args
grep -Fxq 'Spotify web player is ready.' "$test_tmp/arm-success" ||
  fail "ARM success uses truthful web-player wording"
wait_for_log "$launch_log"
grep -Fq 'https://open.spotify.com' "$launch_log" ||
  fail "ARM success opens the exact Spotify web-player URL"
[[ -f $test_home/.local/share/applications/Spotify.desktop ]] ||
  fail "ARM success creates the Spotify desktop launcher"
pass "ARM installs and opens Spotify as a web player"

rm -f "$test_home/.local/share/applications/Spotify.desktop"
: >"$package_log"
: >"$webapp_log"
: >"$launch_log"
: >"$native_log"
OMARCHY_TEST_ARCH=aarch64 OMARCHY_TEST_WEBAPP_FAIL=true \
  omarchy-install-service-spotify >"$test_tmp/arm-failure" 2>&1 &&
  fail "ARM webapp failure returns an error"
assert_empty_log "$package_log"
assert_empty_log "$launch_log"
assert_empty_log "$native_log"
grep -Fq 'web player is ready' "$test_tmp/arm-failure" &&
  fail "ARM webapp failure sends no success wording"
pass "ARM webapp failure is reported before launch"

rm -f "$test_home/.local/share/applications/Spotify.desktop"
: >"$package_log"
: >"$webapp_log"
: >"$launch_log"
: >"$native_log"
OMARCHY_TEST_ARCH=aarch64 OMARCHY_TEST_WEBAPP_FALSE_SUCCESS=true \
  omarchy-install-service-spotify >"$test_tmp/arm-false-success" 2>&1 &&
  fail "ARM webapp false-success returns an error"
assert_empty_log "$package_log"
assert_empty_log "$native_log"
[[ ! -s $launch_log ]] || fail "ARM webapp false-success does not launch"
grep -Fq 'web player is ready' "$test_tmp/arm-false-success" &&
  fail "ARM webapp false-success sends no success wording"
pass "ARM webapp false-success is rejected before launch"

: >"$webapp_log"
: >"$launch_log"
OMARCHY_TEST_ARCH=aarch64 omarchy-install-service-spotify >"$test_tmp/arm-repeat" 2>&1
assert_empty_log "$package_log"
assert_empty_log "$native_log"
assert_webapp_args
wait_for_log "$launch_log"
grep -Fq 'https://open.spotify.com' "$launch_log" ||
  fail "ARM repeat opens the exact Spotify web-player URL"
pass "ARM webapp installation is repeatable without native calls"

rm -f "$installed_dir/spotify"
: >"$package_log"
: >"$webapp_log"
: >"$launch_log"
: >"$native_log"
OMARCHY_TEST_ARCH=x86_64 omarchy-install-service-spotify >"$test_tmp/native-success" 2>&1
grep -Fxq spotify "$package_log" || fail "native flow installs the Spotify package"
assert_empty_log "$webapp_log"
wait_for_log "$native_log"
grep -Fq '/usr/bin/spotify' "$native_log" || fail "native flow launches Spotify"
grep -Fxq 'Spotify has been installed.' "$test_tmp/native-success" ||
  fail "native success keeps its existing message"
pass "non-ARM native installation succeeds after command validation"

rm -f "$installed_dir/spotify"
: >"$package_log"
: >"$webapp_log"
: >"$launch_log"
: >"$native_log"
if OMARCHY_TEST_ARCH=x86_64 OMARCHY_TEST_INSTALL_FAIL=true \
  omarchy-install-service-spotify >"$test_tmp/native-failure" 2>&1; then
  fail "native installer failure returns an error"
fi
assert_empty_log "$webapp_log"
assert_empty_log "$launch_log"
assert_empty_log "$native_log"
grep -Fq 'Spotify has been installed.' "$test_tmp/native-failure" &&
  fail "native installer failure sends no success wording"
pass "native installer failure is reported before launch"

: >"$package_log"
: >"$webapp_log"
: >"$launch_log"
: >"$native_log"
if OMARCHY_TEST_ARCH=x86_64 OMARCHY_TEST_INSTALL_FALSE_SUCCESS=true \
  omarchy-install-service-spotify >"$test_tmp/native-false-success" 2>&1; then
  fail "native false-success returns an error"
fi
assert_empty_log "$webapp_log"
assert_empty_log "$launch_log"
assert_empty_log "$native_log"
grep -Fq 'Spotify has been installed.' "$test_tmp/native-false-success" &&
  fail "native false-success sends no success wording"
pass "native false-success is rejected before launch"

grep -Fq 'action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-service-spotify' \
  "$ROOT/default/omarchy/omarchy-menu.jsonc" || fail "menu remains wired to the Spotify service"
grep -Fq 'omarchy-launch-floating-terminal-with-presentation omarchy-install-service-spotify' \
  "$ROOT/bin/omarchy-launch-spotify" || fail "launcher remains wired to the Spotify service fallback"
pass "menu and launcher retain their existing Spotify wiring"
