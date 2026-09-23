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
  printf 'hyprctl|%s|%s\n' "$2" "$3" >>"$trace"
  [[ ${HYPR_FAIL:-0} != 1 || $2 != input:kb_layout ]]
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
activate_install_keyboard de /dev/tty2
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
[[ $(sed -n '/^hyprctl/p' "$trace") == $'hyprctl|input:kb_variant|\nhyprctl|input:kb_layout|us\nhyprctl|input:kb_variant|dvorak\nhyprctl|input:kb_options|compose:caps,shift:both_capslock_cancel' ]] ||
  fail "Hyprland does not activate the selected XKB layout and variant"
! grep -q '^confirm|' "$trace" || fail "successful Hyprland activation asks for manual setup"
pass "Hyprland terminals activate the mapped XKB layout live"

: >"$trace"
HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard ru /dev/pts/2
[[ $(sed -n '/^hyprctl/p' "$trace") == $'hyprctl|input:kb_variant|\nhyprctl|input:kb_layout|us,ru\nhyprctl|input:kb_variant|,\nhyprctl|input:kb_options|compose:caps,shift:both_capslock_cancel,grp:alts_toggle' ]] ||
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
HYPRLAND_INSTANCE_SIGNATURE=desktop activate_install_keyboard custom-map /dev/pts/5
grep -qF "warn|Choose this desktop's equivalent of console layout custom-map" "$trace" ||
  fail "unmapped console keymap is presented as an XKB layout"
grep -qF 'confirm|Press Enter after changing' "$trace" || fail "unmapped keymap does not wait for acknowledgement"
! grep -q '^hyprctl|' "$trace" || fail "unmapped console keymap is applied to Hyprland"
pass "unmapped console layouts require a manual desktop equivalent"
