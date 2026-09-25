#!/bin/bash

[[ ${BASH_SOURCE[0]} != "$0" ]] || {
  echo "base-test.sh is a library; source it from a test" >&2
  exit 1
}

TOOLS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export TOOLS

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
require_command() { command -v "$1" >/dev/null || fail "$1 is required"; }

file_sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
