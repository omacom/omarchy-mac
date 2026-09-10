#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
calls="$test_tmp/calls.log"
mkdir -p "$mock_bin" "$test_home"

cat >"$mock_bin/uname" <<'SCRIPT'
#!/bin/bash
if [[ ${1:-} == "-m" ]]; then
  printf '%s\n' "${OMARCHY_TEST_ARCH:-x86_64}"
else
  exec /usr/bin/uname "$@"
fi
SCRIPT

cat >"$mock_bin/omarchy-pkg-add" <<'SCRIPT'
#!/bin/bash
printf 'pkg-add\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
[[ ${OMARCHY_TEST_HELPER_STATUS:-0} == 0 ]] || exit "$OMARCHY_TEST_HELPER_STATUS"
if [[ ${OMARCHY_TEST_CREATE_CODE:-0} == 1 ]]; then
  : >"$OMARCHY_TEST_CODE_PATH"
  chmod +x "$OMARCHY_TEST_CODE_PATH"
fi
SCRIPT

cat >"$mock_bin/omarchy-pkg-aur-add" <<'SCRIPT'
#!/bin/bash
printf 'aur-add\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
[[ ${OMARCHY_TEST_HELPER_STATUS:-0} == 0 ]] || exit "$OMARCHY_TEST_HELPER_STATUS"
if [[ ${OMARCHY_TEST_CREATE_CODE:-0} == 1 ]]; then
  : >"$OMARCHY_TEST_CODE_PATH"
  chmod +x "$OMARCHY_TEST_CODE_PATH"
fi
SCRIPT

cat >"$mock_bin/omarchy-cmd-present" <<'SCRIPT'
#!/bin/bash
printf 'cmd-present\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
command -v "$1" >/dev/null 2>&1
SCRIPT

cat >"$mock_bin/omarchy-theme-set-vscode" <<'SCRIPT'
#!/bin/bash
printf 'theme\n' >>"$OMARCHY_TEST_CALLS"
SCRIPT

cat >"$mock_bin/setsid" <<'SCRIPT'
#!/bin/bash
printf 'launch\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
if [[ ${OMARCHY_TEST_WRAPPER_EXEC:-0} == 1 ]]; then
  exec "$@"
fi
SCRIPT

cat >"$mock_bin/uwsm-app" <<'SCRIPT'
#!/bin/bash
printf 'uwsm\t%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
[[ ${1:-} == "--" ]] && shift
if [[ ${1:-} == "xdg-terminal-exec" ]]; then
  exec "$@"
fi
exit 0
SCRIPT

cat >"$mock_bin/xdg-terminal-exec" <<'SCRIPT'
#!/bin/bash
while (($#)); do
  if [[ $1 == "-e" ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 1
SCRIPT

cat >"$mock_bin/omarchy-restart-gum" <<'SCRIPT'
#!/bin/bash
:
SCRIPT

cat >"$mock_bin/omarchy-show-logo" <<'SCRIPT'
#!/bin/bash
printf 'logo\n' >>"$OMARCHY_TEST_CALLS"
SCRIPT

cat >"$mock_bin/omarchy-show-done" <<'SCRIPT'
#!/bin/bash
printf 'done\n' >>"$OMARCHY_TEST_CALLS"
SCRIPT

ln -s "$ROOT/bin/omarchy-install-editor-vscode" "$mock_bin/omarchy-install-editor-vscode"
chmod +x "$mock_bin"/*

export HOME="$test_home"
export PATH="$mock_bin:$PATH"
export OMARCHY_TEST_CALLS="$calls"
export OMARCHY_TEST_CODE_PATH="$mock_bin/code"

reset_case() {
  rm -f "$mock_bin/code" "$HOME/.vscode/argv.json" "$HOME/.config/Code/User/settings.json"
  mkdir -p "$HOME"
  : >"$calls"
  unset OMARCHY_TEST_WRAPPER_EXEC OMARCHY_TEST_CREATE_CODE OMARCHY_TEST_HELPER_STATUS
}

run_installer() {
  OMARCHY_TEST_ARCH="$1" \
    OMARCHY_TEST_CREATE_CODE="$2" \
    OMARCHY_TEST_HELPER_STATUS="$3" \
    bash "$ROOT/bin/omarchy-install-editor-vscode"
}

assert_no_side_effects() {
  [[ ! -e $HOME/.vscode/argv.json ]] || fail "failed install does not write argv.json"
  [[ ! -e $HOME/.config/Code/User/settings.json ]] || fail "failed install does not write settings.json"
  ! grep -Fxq 'theme' "$calls" || fail "failed install does not apply the theme" "$(cat "$calls")"
  ! grep -Fxq $'launch\tuwsm-app -- gtk-launch code' "$calls" ||
    fail "failed install does not launch VS Code" "$(cat "$calls")"
}

wait_for_call() {
  local expected="$1"

  for ((attempt = 0; attempt < 100; attempt++)); do
    grep -Fxq "$expected" "$calls" && return 0
    sleep 0.01
  done
  return 1
}

reset_case
run_installer aarch64 1 0
grep -Fxq $'aur-add\tvisual-studio-code-bin' "$calls" || fail "ARM uses the AUR package helper" "$(cat "$calls")"
! grep -Fq $'pkg-add\t' "$calls" || fail "ARM does not use the repository package helper" "$(cat "$calls")"
grep -Fxq $'cmd-present\tcode' "$calls" || fail "installer checks for the code command" "$(cat "$calls")"
grep -Fxq 'theme' "$calls" || fail "successful install applies the VS Code theme"
wait_for_call $'launch\tuwsm-app -- gtk-launch code' || fail "successful install queues a VS Code launch request" "$(cat "$calls")"
[[ -f $HOME/.vscode/argv.json && -f $HOME/.config/Code/User/settings.json ]] || fail "successful install writes VS Code configuration"
pass "ARM success uses AUR helper, postcondition, config, theme, and detached launch request"

reset_case
run_installer x86_64 1 0
grep -Fxq $'pkg-add\tvisual-studio-code-bin' "$calls" || fail "non-ARM retains the repository package helper" "$(cat "$calls")"
! grep -Fq $'aur-add\t' "$calls" || fail "non-ARM does not use the AUR helper" "$(cat "$calls")"
pass "non-ARM success retains repository helper"

reset_case
mkdir -p "$HOME/.vscode" "$HOME/.config/Code/User"
printf 'old argv\n' >"$HOME/.vscode/argv.json"
printf 'old settings\n' >"$HOME/.config/Code/User/settings.json"
: >"$mock_bin/code"
chmod +x "$mock_bin/code"
set +e
run_installer aarch64 0 1
status=$?
set -e
[[ $status != 0 ]] || fail "helper failure returns nonzero"
grep -Fxq 'old argv' "$HOME/.vscode/argv.json" || fail "helper failure preserves argv.json"
grep -Fxq 'old settings' "$HOME/.config/Code/User/settings.json" || fail "helper failure preserves settings.json"
! grep -Eq '^(theme|launch)' "$calls" || fail "helper failure stops before theme and launch" "$(cat "$calls")"
pass "helper failure propagates and preserves configuration"

reset_case
set +e
run_installer aarch64 0 0
status=$?
set -e
[[ $status != 0 ]] || fail "false-success helper fails without code"
assert_no_side_effects
pass "helper false-success fails before configuration, theme, and launch"

reset_case
mv "$HOME" "$test_tmp/valid-home"
: >"$HOME"
: >"$mock_bin/code"
chmod +x "$mock_bin/code"
set +e
run_installer aarch64 1 0
status=$?
set -e
[[ $status != 0 ]] || fail "an invalid HOME path returns nonzero"
assert_no_side_effects
mv "$HOME" "$test_tmp/invalid-home"
mv "$test_tmp/valid-home" "$HOME"
pass "an invalid HOME path fails before theme or launch"

reset_case
run_installer aarch64 1 0
run_installer aarch64 0 0
grep -Fq $'cmd-present\tcode' "$calls" || fail "repeat checks the installed code command"
pass "repeat with installed code remains successful"

grep -Fq '"install.editor.vscode"' "$ROOT/default/omarchy/omarchy-menu.jsonc" || fail "VS Code menu action exists"
grep -Fq '"action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-editor-vscode"' \
  "$ROOT/default/omarchy/omarchy-menu.jsonc" || fail "VS Code menu action uses the presentation wrapper"

reset_case
set +e
OMARCHY_TEST_ARCH=aarch64 OMARCHY_TEST_HELPER_STATUS=1 OMARCHY_TEST_WRAPPER_EXEC=1 \
  "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" omarchy-install-editor-vscode
status=$?
set -e
[[ $status != 0 ]] || fail "menu presentation path returns helper failure"
! grep -Fxq 'done' "$calls" || fail "menu presentation path does not show Done after helper failure" "$(cat "$calls")"
assert_no_side_effects
pass "menu presentation path preserves helper failure without Done or mutation"

reset_case
set +e
OMARCHY_TEST_ARCH=aarch64 OMARCHY_TEST_HELPER_STATUS=0 OMARCHY_TEST_CREATE_CODE=0 OMARCHY_TEST_WRAPPER_EXEC=1 \
  "$ROOT/bin/omarchy-launch-floating-terminal-with-presentation" omarchy-install-editor-vscode
status=$?
set -e
[[ $status != 0 ]] || fail "menu presentation path returns false-success failure"
! grep -Fxq 'done' "$calls" || fail "menu presentation path does not show Done after false success" "$(cat "$calls")"
assert_no_side_effects
pass "menu presentation path preserves false success without Done or mutation"
