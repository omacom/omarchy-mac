#!/bin/bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null || fail "required command is available: $1"; }
# Fixture core helpers without requiring an installed desktop.
export PATH="$ROOT/test/helpers:$PATH"
