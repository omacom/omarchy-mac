#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
home="$test_tmp/home"
calls="$test_tmp/calls"
mkdir -p "$stub_bin" "$home"

cat >"$stub_bin/fc-list" <<'SH'
#!/bin/bash
echo "CaskaydiaMono Nerd Font"
SH

cat >"$stub_bin/pgrep" <<'SH'
#!/bin/bash
printf 'pgrep %s\n' "$*" >>"$CALLS"
case " $* " in
  *" -x foot "*|*" -x ghostty "*)
    # Real pgrep prints matching PIDs; the font setter must not leak them.
    echo 8105
    exit 0
    ;;
esac
exit 1
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify %s\n' "$*" >>"$CALLS"
if [[ $1 == -g || $1 == --glyph ]]; then
  if [[ ${2:-} == -* || -z ${2:-} ]]; then
    echo "Usage: omarchy-notification-send [--app-name <app-name>] [-g <glyph>] ... <headline> [description]" >&2
    exit 1
  fi
fi
exit 0
SH

cat >"$stub_bin/omarchy-restart-shell" <<'SH'
#!/bin/bash
echo restart-shell >>"$CALLS"
SH

cat >"$stub_bin/omarchy-hook" <<'SH'
#!/bin/bash
printf 'hook %s\n' "$*" >>"$CALLS"
SH

chmod +x "$stub_bin"/*

: >"$calls"
HOME="$home" CALLS="$calls" PATH="$stub_bin:$PATH" \
  "$ROOT/bin/omarchy-font-set" "CaskaydiaMono Nerd Font" >"$test_tmp/out" 2>"$test_tmp/err"

[[ ! -s $test_tmp/out ]] || fail "font set does not print process IDs" "$(cat "$test_tmp/out")"
[[ ! -s $test_tmp/err ]] || fail "font set sends a valid restart notification" "$(cat "$test_tmp/err")"
grep -Fx 'notify You must restart Ghostty to see font change' "$calls" >/dev/null ||
  fail "font set notifies Ghostty with a headline" "$(cat "$calls")"
grep -Fx 'notify You must restart Foot to see font change' "$calls" >/dev/null ||
  fail "font set notifies Foot with a headline" "$(cat "$calls")"
if grep -E 'notify -g' "$calls" >/dev/null; then
  fail "font set does not pass -g without a glyph" "$(cat "$calls")"
fi
pass "font set suppresses pgrep output and sends a valid restart notification"
