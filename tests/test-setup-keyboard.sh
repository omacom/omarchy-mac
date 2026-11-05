#!/bin/bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
failures=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "✓ $label"
    ((++pass))
  else
    echo "✗ $label"
    ((++failures))
  fi
}

# Stub the interactive and system-touching commands; gum drains stdin first
# because the prompt pipes the layout list in — exiting early kills cut with
# SIGPIPE and pipefail reads that as a cancelled prompt.
make_stubs() {
  local selection="$1"
  rm -rf "$WORK/bin"
  mkdir -p "$WORK/bin"
  : >"$WORK/calls"

  cat >"$WORK/bin/gum" <<STUB
#!/bin/bash
cat >/dev/null
if [[ -n '$selection' ]]; then
  printf '%s\n' '$selection'
else
  exit 1
fi
STUB

  cat >"$WORK/bin/localectl" <<'STUB'
#!/bin/bash
local_ifs=$IFS
IFS='|'
printf '%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
IFS=$local_ifs
case "$1" in
  status)
    echo "   VC Keymap: us"
    echo "  X11 Layout: us"
    ;;
  --no-pager)
    printf 'us\nuk\ndvorak\n'
    ;;
esac
STUB

  cat >"$WORK/bin/hyprctl" <<'STUB'
#!/bin/bash
IFS='|'
printf '%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
STUB
  chmod +x "$WORK/bin/"*
}

run_setup() {
  OMARCHY_PATH="$ROOT" OMARCHY_TEST_CALLS="$WORK/calls" \
    PATH="$WORK/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-setup-keyboard"
}

called() {
  grep -qF "$1" "$WORK/calls"
}

not_called() {
  ! grep -qF "$1" "$WORK/calls"
}

make_stubs "English (UK)"
run_setup >/dev/null
check "English (UK) persists the uk console keymap" \
  called "set-keymap|uk"
check "English (UK) persists the gb XKB layout" \
  called "set-x11-keymap|gb"
check "a successful pick reloads Hyprland" \
  called "reload"

make_stubs "English (US, Dvorak)"
run_setup >/dev/null
check "English (US, Dvorak) passes the dvorak variant through to XKB" \
  called "set-x11-keymap|us||dvorak"

make_stubs ""
run_setup >/dev/null
check "cancelling the picker changes no keymap" \
  not_called "set-keymap"
check "cancelling the picker changes no XKB layout" \
  not_called "set-x11-keymap"

echo ""
echo "$pass checks passed, $failures failed"
exit $((failures > 0))
