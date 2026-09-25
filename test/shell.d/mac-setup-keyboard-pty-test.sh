#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Run the guided question flow in a real pseudo-terminal. The documented piped
# invocation reopens /dev/tty, whose name is not the controlling terminal name.
cat >"$work/driver" <<'DRIVER'
set -euo pipefail
source "$ROOT/bin/omarchy-mac-setup"
[[ $(tty </dev/tty) == /dev/tty ]] || exit 1
[[ $(ps -o tty= -p "$$" | tr -d '[:space:]') == pts/* ]] || exit 1
username=owner hostname=mac encrypt_flag=0 want_encrypt=0 repo=example/repo ref=branch
if [[ $1 == prompted ]]; then
  keymap=""
else
  keymap=de
fi
current_keymap() { printf 'us\n'; }
keymaps_listable() { return 1; }
valid_keymap() { return 0; }
loadkeys() { printf 'loadkeys|%s\n' "$*" >>"$GUIDED_TRACE"; }
ask_questions </dev/tty
printf 'questions-complete|%s\n' "$keymap" >>"$GUIDED_TRACE"
DRIVER

export ROOT GUIDED_TRACE="$work/trace"

run_guided() {
  local mode=$1 answers=$2 output=$3
  : >"$GUIDED_TRACE"
  printf '%b' "$answers" | script -e -q -c "bash '$work/driver' '$mode'" /dev/null >"$output"
}

run_guided prompted 'de\n\nY\n' "$work/prompted-output" || fail "guided prompt failed in a real PTY"
grep -qF 'Keyboard layout [us]' "$work/prompted-output" || fail "guided keymap prompt was skipped"
grep -qF 'Set this desktop' "$work/prompted-output" || fail "guided prompt omitted desktop guidance"
grep -qF 'Press Enter when your keyboard layout is ready' "$work/prompted-output" || fail "guided prompt omitted keyboard acknowledgement"
[[ $(<"$GUIDED_TRACE") == 'questions-complete|de' ]] || fail "guided prompt changed the local console or failed to finish"
pass "guided keymap prompt discovers a PTY and avoids loadkeys"

run_guided explicit '\nY\n' "$work/explicit-output" || fail "guided explicit keymap failed in a real PTY"
! grep -qF 'Keyboard layout [us]' "$work/explicit-output" || fail "explicit keymap prompted again"
grep -qF 'Set this desktop' "$work/explicit-output" || fail "explicit keymap omitted desktop guidance"
grep -qF 'Press Enter when your keyboard layout is ready' "$work/explicit-output" || fail "explicit keymap omitted keyboard acknowledgement"
[[ $(<"$GUIDED_TRACE") == 'questions-complete|de' ]] || fail "explicit keymap changed the local console or failed to finish"
pass "guided explicit or saved keymap discovers a PTY and avoids loadkeys"

: >"$GUIDED_TRACE"
printf '\nY\n' | SSH_CONNECTION=client script -e -q -c "bash '$work/driver' explicit" /dev/null >"$work/ssh-output" ||
  fail "guided SSH questions failed in a real PTY"
grep -qF "Set your client's keyboard" "$work/ssh-output" || fail "guided SSH guidance missing"
[[ $(<"$GUIDED_TRACE") == 'questions-complete|de' ]] || fail "guided SSH changed the local console"
pass "guided SSH session avoids loadkeys"
