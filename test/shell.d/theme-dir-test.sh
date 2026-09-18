#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

home="$test_tmp/home"
packaged="$test_tmp/omarchy"
mkdir -p "$home/.config/omarchy/themes/osaka-jade" "$packaged/themes/tokyo-night" "$packaged/themes/catppuccin-latte"

theme_dir() {
  HOME="$home" OMARCHY_PATH="$packaged" "$ROOT/bin/omarchy-theme-dir" "$@"
}

[[ $(theme_dir "Osaka Jade") == "$home/.config/omarchy/themes/osaka-jade" ]] ||
  fail "theme dir resolves a display name from theme current to a user theme"
[[ $(theme_dir osaka-jade) == "$home/.config/omarchy/themes/osaka-jade" ]] ||
  fail "theme dir still accepts the kebab-case slug"
pass "theme dir resolves user-installed display names and slugs"

[[ $(theme_dir "Tokyo Night") == "$packaged/themes/tokyo-night" ]] ||
  fail "theme dir resolves a display name to a packaged theme"
[[ $(theme_dir "Catppuccin Latte") == "$packaged/themes/catppuccin-latte" ]] ||
  fail "theme dir slugifies multi-word packaged names"
pass "theme dir resolves packaged display names"

if out=$(theme_dir "Does Not Exist" 2>&1); then
  fail "theme dir fails for an unknown name"
fi
[[ $out == *"does not exist"* ]] || fail "theme dir names the missing theme" "$out"
[[ $out != *"/Does Not Exist"* && $out != *"/does-not-exist"* ]] ||
  fail "theme dir does not print a nonexistent path" "$out"
pass "theme dir fails instead of printing a nonexistent path"

if theme_dir "../evil" >/dev/null 2>&1; then
  fail "theme dir rejects a path-climbing name"
fi
if theme_dir "." >/dev/null 2>&1; then
  fail "theme dir rejects '.'"
fi
pass "theme dir rejects names that climb out of the theme directories"
