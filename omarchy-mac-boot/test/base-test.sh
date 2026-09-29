#!/bin/bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null || fail "required command is available: $1"; }
# Fixture core helpers without requiring an installed desktop.
export PATH="$ROOT/test/helpers:$PATH"
# Tests that read the Omarchy runtime (its HOOKS baseline, leaves and package
# lists) take it from the checkout OMARCHY_TEST_RUNTIME names, and skip without one.
requires_runtime() {
  if [[ -z ${OMARCHY_TEST_RUNTIME:-} ]]; then
    printf 'skip - %s: OMARCHY_TEST_RUNTIME names no runtime checkout\n' "$1"
    return 1
  fi
}
