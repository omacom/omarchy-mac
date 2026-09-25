#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trace="$work/trace"
checkout=$ROOT

# Exercise the installer's real terminal-mode logic without changing the
# machine's keyboard or requiring a compositor in the test environment.
source <(sed -n '/^activate_install_keyboard() {/,/^}/p; /^confirm_install_keyboard() {/,/^}/p' "$ROOT/install.sh")
sudo() { printf 'sudo|%s\n' "$*" >>"$trace"; }
hyprctl() {
  printf 'hyprctl|%s\n' "$*" >>"$trace"
  if [[ $1 == "eval" ]]; then
    [[ ${HYPR_FAIL:-0} != 1 ]] || return 1
    if [[ ${HYPR_STALE:-0} != 1 ]]; then
      HYPR_LAYOUT=$(sed -n 's/.*kb_layout = "\([^"]*\)".*/\1/p' <<<"$2")
      HYPR_VARIANT=$(sed -n 's/.*kb_variant = "\([^"]*\)".*/\1/p' <<<"$2")
      HYPR_OPTIONS=$(sed -n 's/.*kb_options = "\([^"]*\)".*/\1/p' <<<"$2")
    fi
  elif [[ $1 == "getoption" ]]; then
    case "$2" in
      input:kb_layout) printf 'str: %s\n' "${HYPR_LAYOUT:-}" ;;
      input:kb_variant) printf 'str: %s\n' "${HYPR_VARIANT:-}" ;;
      input:kb_options) printf 'str: %s\n' "${HYPR_OPTIONS:-}" ;;
    esac
  fi
}
confirm_install_keyboard() { printf 'confirm|%s\n' "$1" >>"$trace"; }
warn() { printf 'warn|%s\n' "$*" >>"$trace"; }
log() { printf 'log|%s\n' "$*" >>"$trace"; }
fail() { printf 'error|%s\n' "$*" >>"$trace"; exit 1; }
unset SSH_CONNECTION SSH_TTY HYPRLAND_INSTANCE_SIGNATURE

python3 - "$ROOT/default/hypr/input.lua" "$ROOT/install.sh" <<'PY' || fail "installer and desktop disagree on non-Latin layouts"
import re
import sys

desktop = re.search(r'local non_latin_layouts\s*=\s*"([^"]+)"', open(sys.argv[1]).read()).group(1)
installer = re.search(r'local non_latin_layouts="([^"]+)"', open(sys.argv[2]).read()).group(1)
assert desktop.split() == installer.split()
PY
pass "installer and desktop use the same non-Latin layout list"

: >"$trace"
activate_install_keyboard de tty2
[[ $(cat "$trace") == 'sudo|-n loadkeys de' ]] || fail "VT activation uses noninteractive sudo loadkeys"
pass "VT activation changes the live console without another password prompt"

: >"$trace"
SSH_CONNECTION=client HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard uk /dev/pts/1
grep -qF "warn|This is an SSH session" "$trace" || fail "SSH session guidance is missing"
grep -qF 'confirm|Press Enter when ready' "$trace" || fail "SSH session does not wait for acknowledgement"
! grep -qE '^(sudo|hyprctl)\|' "$trace" || fail "SSH session attempts to change the remote keyboard"
pass "SSH sessions explain that client typing stays under client control"

: >"$trace"
HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard dvorak /dev/pts/2
grep -qF 'hyprctl|eval hl.config({ input = { kb_layout = "us", kb_variant = "dvorak", kb_options = "compose:caps,shift:both_capslock_cancel" } })' "$trace" ||
  fail "Hyprland does not activate the selected XKB layout and variant"
grep -qF 'hyprctl|getoption input:kb_options' "$trace" || fail "Hyprland activation is not verified"
! grep -q '^confirm|' "$trace" || fail "successful Hyprland activation asks for manual setup"
pass "Hyprland terminals activate the mapped XKB layout live"

: >"$trace"
HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard ru /dev/pts/2
grep -qF 'hyprctl|eval hl.config({ input = { kb_layout = "us,ru", kb_variant = ",", kb_options = "compose:caps,shift:both_capslock_cancel,grp:alts_toggle" } })' "$trace" ||
  fail "non-Latin Hyprland layout loses the US keymap or toggle"
grep -qF 'log|US is active first; press Left Alt + Right Alt to switch to ru.' "$trace" ||
  fail "non-Latin Hyprland toggle is not explained"
pass "non-Latin Hyprland layouts retain US and the Alt toggle"

: >"$trace"
activate_install_keyboard uk /dev/pts/3
grep -qF 'warn|Change this desktop' "$trace" || fail "other desktop guidance is missing"
grep -qF 'layout to gb before answering' "$trace" || fail "other desktop guidance uses the wrong XKB layout"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "other desktop does not wait for layout change"
pass "other desktop terminals wait for an acknowledged layout change"

: >"$trace"
activate_install_keyboard ru /dev/pts/3
grep -qF 'warn|Enable both US and ru on this desktop' "$trace" ||
  fail "manual non-Latin layout guidance omits US"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "manual non-Latin setup is not acknowledged"
pass "other desktops keep a Latin layout available for non-Latin choices"

: >"$trace"
HYPR_FAIL=1 HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard uk /dev/pts/4
grep -qF 'warn|Could not activate keyboard layout uk in Hyprland.' "$trace" || fail "Hyprland failure is silent"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "Hyprland failure does not offer a manual handoff"
pass "failed Hyprland activation requires a manual layout change"

: >"$trace"
HYPR_STALE=1 HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard uk /dev/pts/4
grep -qF 'warn|Could not activate keyboard layout uk in Hyprland.' "$trace" || fail "Hyprland stale layout is reported as active"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "Hyprland stale layout does not require manual correction"
pass "Hyprland success requires the compositor to report the requested layout"

: >"$trace"
HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard custom-map /dev/pts/5
grep -qF "warn|Choose this desktop's equivalent of console layout custom-map" "$trace" ||
  fail "unmapped console keymap is presented as an XKB layout"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "unmapped keymap does not wait for acknowledgement"
! grep -q '^hyprctl|' "$trace" || fail "unmapped console keymap is applied to Hyprland"
pass "unmapped console layouts require a manual desktop equivalent"

# `tty </dev/tty` reports the alias rather than the controlling device. Run
# the real selection function in a PTY so discovery cannot be faked by passing
# a preclassified terminal to activate_install_keyboard.
cat >"$work/pty-driver" <<'DRIVER'
set -euo pipefail
source <(sed -n '/^prompt_install_keyboard() {/,/^}/p' "$ROOT/install.sh")
sudo() { :; }
localectl() { [[ $* == *list-keymaps* ]] && printf 'us\n'; }
activate_install_keyboard() { printf '%s\n' "$2" >"$PTY_RESULT"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { :; }
prompt_install_keyboard
DRIVER
export ROOT PTY_RESULT="$work/pty-result"
printf '\n' | script -q -c "bash '$work/pty-driver'" /dev/null >"$work/pty-output" || fail "keyboard selection fails in a real PTY"
[[ $(<"$PTY_RESULT") == pts/* ]] || fail "installer did not discover its real PTY"
pass "installer discovers the controlling PTY instead of the /dev/tty alias"

cat >"$work/bootstrap-pty-driver" <<'DRIVER'
set -euo pipefail
source <(sed -n '/^prompt_keyboard() {/,/^}/p' "$ROOT/bootstrap.sh")
TTY_IN=/dev/tty
localectl() { [[ $* == *list-keymaps* ]] && printf 'us\n' || true; }
loadkeys() { printf 'loadkeys|%s\n' "$*" >>"$BOOTSTRAP_RESULT"; }
ps() {
  if [[ ${MOCK_VT:-0} == 1 ]]; then printf 'tty2\n'; else command ps "$@"; fi
}
print_error() { printf 'error: %s\n' "$*" >&2; }
print_warning() { :; }
prompt_keyboard
DRIVER
export BOOTSTRAP_RESULT="$work/bootstrap-result"
: >"$BOOTSTRAP_RESULT"
printf '\n' | script -q -c "bash '$work/bootstrap-pty-driver'" /dev/null >"$work/bootstrap-pty-output" ||
  fail "bootstrap keyboard selection fails in a real PTY"
[[ ! -s $BOOTSTRAP_RESULT ]] || fail "bootstrap changed console keymap from a PTY"
printf '\n' | script -q -c "MOCK_VT=1 bash '$work/bootstrap-pty-driver'" /dev/null >"$work/bootstrap-vt-output" ||
  fail "bootstrap keyboard selection fails with a VT classification"
[[ $(<"$BOOTSTRAP_RESULT") == 'loadkeys|us' ]] || fail "bootstrap did not activate the VT keymap"
pass "bootstrap distinguishes a real PTY from a virtual console"

source "$ROOT/test/shell.d/helpers/install-orchestration.sh"
: >"$CALLS"
env -u OMARCHY_KEYBOARD_CONFIRMED bash "$work/driver" --keymap us >"$work/unattended-output" 2>&1 ||
  fail "explicit keymap did not allow installation without a controlling terminal"
grep -q '^keyboard$' "$CALLS" || fail "unattended keymap was not persisted"
! grep -qE '^(auth|activate )' "$CALLS" || fail "unattended keymap attempted terminal activation"
pass "explicit keymap persists without prompting or activating in pipe mode"

: >"$CALLS"
printf '\n' | script -e -q -c "env -u OMARCHY_KEYBOARD_CONFIRMED bash '$work/driver' --keymap de" /dev/null >"$work/explicit-pty-output" ||
  fail "explicit keymap failed in an interactive terminal"
[[ $(sed -n '1,4p' "$CALLS") == $'preconditions\nauth\nactivate de pts/'* ]] ||
  fail "interactive explicit keymap was not authenticated and activated before persistence"
[[ $(sed -n '4p' "$CALLS") == 'keyboard' ]] || fail "interactive explicit keymap was not persisted after activation"
pass "explicit keymap authenticates and activates in a real PTY"

env -u OMARCHY_KEYBOARD_CONFIRMED bash "$work/driver" --keymap 'bad;layout' >"$work/invalid-output" 2>&1 &&
  fail "unsafe unattended keymap was accepted"
grep -qF 'Invalid console keymap' "$work/invalid-output" || fail "invalid keymap was not explained"
grep -qF 'bash install.sh --keymap us' "$ROOT/test/vm/run-install" || fail "install VM lacks explicit keymap"
grep -qF 'bash install.sh --keymap us' "$ROOT/test/vm/run-selective-edge" || fail "edge VM lacks explicit keymap"
pass "both pipe based VM harnesses supply a validated unattended keymap"
