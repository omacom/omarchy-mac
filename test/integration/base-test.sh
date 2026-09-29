#!/bin/bash
# Tests of the packages together, and against the Omarchy runtime they install into.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
MAC=$REPO/omarchy-mac
BOOT=$REPO/omarchy-mac-boot
export REPO MAC BOOT
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s %s\n' "$1" "${2:-}" >&2; exit 1; }
# The runtime comes from the checkout OMARCHY_TEST_RUNTIME names; without one, tests needing it skip.
requires_runtime() {
  if [[ -z ${OMARCHY_TEST_RUNTIME:-} ]]; then
    printf 'skip - %s: OMARCHY_TEST_RUNTIME names no runtime checkout\n' "$1"
    return 1
  fi
}
