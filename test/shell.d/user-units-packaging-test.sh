#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# 4.0.2 shipped user units in /usr/share/omarchy that were never installed to
# /usr/lib/systemd/user/, so enabling them failed and first-run replayed at
# every login. Two invariants stop a repeat: every omarchy unit that first-run
# or a migration enables must exist as shipped source, and the package build
# must install every shipped source unit.

units_dir="$ROOT/default/systemd/user"
enable_script="$ROOT/install/user/first-run/enable-user-units.sh"

# omarchy-update-user-notify.service ships only as a PKGBUILD alias symlink
# for pre-1785095882 users; config-test.sh guards that alias.
alias_units='omarchy-update-user-notify.service'

referenced=$(
  {
    cat "$enable_script"
    grep -h 'systemctl --user enable' "$ROOT"/migrations/*.sh || true
  } | grep -hoE '[A-Za-z0-9@_-]+\.service' | sort -u
)

checked=0
while read -r unit; do
  [[ -n $unit ]] || continue
  case $unit in
    omarchy-*.service | bt-agent.service) ;;
    *) continue ;;
  esac
  [[ " $alias_units " == *" $unit "* ]] && continue
  [[ -f "$units_dir/$unit" ]] ||
    fail "every enabled omarchy user unit ships as source" "referenced but not in default/systemd/user: $unit"
  checked=$((checked + 1))
done <<<"$referenced"
(( checked >= 7 )) ||
  fail "the reference scan sees the first-run unit list" "found only $checked units"
pass "every omarchy user unit enabled by first-run or a migration ships in default/systemd/user"

# Shipped source only reaches /usr/lib/systemd/user/ through the build's glob
# install; a hand-maintained list is exactly what rotted in 4.0.2.
grep -qF 'for omarchy_user_unit in default/systemd/user/*.service' "$ROOT/build-packages.sh" ||
  fail "the package build installs every default/systemd/user unit, not a hand-maintained list"
grep -A4 'package == "omarchy-settings"' "$ROOT/build-packages.sh" | grep -q install_all_user_units ||
  fail "the glob install is applied when building omarchy-settings"
pass "the package build glob-installs every shipped user unit"

# The two units 4.0.2 dropped stay pinned by name so a rename or deletion of
# either source file is a conscious decision, not silent coverage loss.
for unit in omarchy-brightness-keyboard-auto.service omarchy-speaker-tuning.service; do
  [[ -f "$units_dir/$unit" ]] ||
    fail "the units 4.0.2 failed to package still ship as source" "missing: $unit"
done
pass "the units 4.0.2 failed to package still ship as source"
