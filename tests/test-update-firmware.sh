#!/bin/bash
# Checks how omarchy-update-firmware reports fwupd's outcome. fwupdmgr exits 2
# when there is nothing to update, which is the normal result on Apple Silicon
# (fwupd cannot update Mac system firmware), so that must not read as a failure.
# Real errors must still fail. Runs anywhere: fwupdmgr, sudo and the hardware
# check are stubs on PATH.

set -uo pipefail

TOOL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-update-firmware"
pass=0
failures=0

stub_dir="$(mktemp -d)"
trap 'rm -rf -- "$stub_dir"' EXIT

stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$stub_dir/$1"
  chmod +x "$stub_dir/$1"
}

# Only fwupdmgr runs for real; the EFI binary install must not touch /boot.
stub sudo '[[ $1 == "fwupdmgr" ]] && exec "$@"; exit 0'
stub omarchy-cmd-missing 'exit 1'
stub fwupdmgr '[[ $1 == "update" ]] && exit "$UPDATE_STATUS"; exit 0'

# Runs the tool with fwupdmgr update exiting $1, on Apple hardware when $2 is
# "apple". Sets $status and $output.
run() {
  if [[ $2 == "apple" ]]; then
    stub omarchy-hw-apple 'exit 0'
  else
    stub omarchy-hw-apple 'exit 1'
  fi
  output=$(UPDATE_STATUS=$1 PATH="$stub_dir:$PATH" bash "$TOOL" 2>&1)
  status=$?
}

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

not() {
  ! "$@"
}

echo "=== fwupd outcomes ==="

run 0 other
check "a successful update succeeds" [ "$status" = 0 ]

run 2 other
check "nothing to update succeeds" [ "$status" = 0 ]

run 1 other
check "a failed update fails" [ "$status" = 1 ]

run 2 apple
check "nothing to update on Apple Silicon succeeds" [ "$status" = 0 ]
check "Apple Silicon is told system firmware comes from macOS" grep -q "macOS" <<<"$output"

run 2 other
check "other hardware gets no macOS note" not grep -q "macOS" <<<"$output"

echo
echo "$pass passed, $failures failed"
((failures == 0))
