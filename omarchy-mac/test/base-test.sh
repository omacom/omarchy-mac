#!/bin/bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s %s\n' "$1" "${2:-}" >&2; exit 1; }
