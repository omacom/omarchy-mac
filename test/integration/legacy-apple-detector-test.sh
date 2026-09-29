#!/bin/bash
# omarchy-mac keeps the pre-Quattro omarchy-hw-apple name for user services that
# still call it. Installed beside the runtime's predicate, it must agree with it.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime-test.sh"
require_platform_fixtures "the legacy Apple detector"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
usr_bin=$work/usr-bin
mkdir -p "$usr_bin"
ln -sf "$ROOT"/bin/* "$usr_bin/"
ln -sf "$MAC/bin/omarchy-hw-apple" "$usr_bin/"

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fixture=$work/$platform
  fake_platform "$fixture" "$platform"
  predicate_status=0
  OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-hw-apple-silicon" || predicate_status=$?
  legacy_status=0
  OMARCHY_PROC_ROOT="$fixture/proc" PATH="$fixture/bin:$ROOT/bin:$PATH" "$usr_bin/omarchy-hw-apple" || legacy_status=$?
  if [[ $platform == "apple-silicon" ]]; then
    (( predicate_status == 0 && legacy_status == 0 )) || fail "both Apple predicates accept the Apple fixture"
  else
    (( predicate_status != 0 && legacy_status != 0 )) || fail "both Apple predicates reject the $platform fixture"
  fi
  pass "the legacy detector agrees with the runtime's on the $platform fixture"
done
