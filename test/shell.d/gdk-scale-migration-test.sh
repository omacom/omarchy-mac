#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

migration="$ROOT/migrations/1790518456.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

monitors="$test_dir/.config/hypr/monitors.lua"
mkdir -p "$(dirname "$monitors")"

run_migration() {
  HOME="$test_dir" bash -euo pipefail "$migration" >/dev/null
}

run_migration || fail "gdk scale migration runs without a monitors.lua"
pass "gdk scale migration runs without a monitors.lua"

printf '%s\n' 'hl.monitor({ output = "", scale = "auto" })' 'local omarchy_gdk_scale = 2' 'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' >"$monitors"
run_migration
grep -qxF -- '-- local omarchy_gdk_scale = 2' "$monitors" && grep -qxF -- '-- hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' "$monitors" ||
  fail "gdk scale migration comments out the stock GDK_SCALE lines"
grep -qxF 'hl.monitor({ output = "", scale = "auto" })' "$monitors" || fail "gdk scale migration keeps the rest of monitors.lua"
before=$(sha256sum "$monitors")
run_migration
[[ $(sha256sum "$monitors") == "$before" ]] || fail "gdk scale migration is idempotent"
pass "gdk scale migration comments out the stock GDK_SCALE lines once"

printf '%s\n' 'local omarchy_gdk_scale = 1' 'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' >"$monitors"
before=$(sha256sum "$monitors")
run_migration
[[ $(sha256sum "$monitors") == "$before" ]] || fail "gdk scale migration keeps a GDK_SCALE the user changed"
pass "gdk scale migration keeps a GDK_SCALE the user changed"
