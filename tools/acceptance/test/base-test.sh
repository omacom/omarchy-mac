#!/bin/bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
export ROOT
pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
require_command() { command -v "$1" >/dev/null || fail "required command is available: $1"; }
