#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A device tree fixture, shaped after the real t8103-j293 tree as the kernel
# exposes it. Both display controllers are named "dcp@" -- the external one is
# dcp@271c00000 and is external by virtue of its compatible string, not its name.
# phandle values are 4 big-endian bytes, the same encoding /proc/device-tree uses.
make_tree() { # make_tree <dir> <dcpext-status> <wire-displayport:yes|no>
  local dir=$1 status=$2 wired=$3
  local internal="$dir/soc/dcp@231c00000"
  local external="$dir/soc/dcp@271c00000"
  local conn="$dir/soc/i2c@235010000/usb-pd@3f/connector"
  local other="$dir/soc/i2c@235010000/usb-pd@38/connector"

  mkdir -p "$internal" "$external" "$conn" "$other"
  printf 'apple,j293\0apple,t8103\0' >"$dir/compatible"
  printf 'Apple MacBook Pro (13-inch, M1, 2020)\0' >"$dir/model"

  printf 'apple,t8103-dcp\0apple,dcp\0' >"$internal/compatible"
  printf '\x00\x00\x00\x26' >"$internal/phandle"
  printf 'okay\0' >"$internal/status"

  printf 'apple,t8103-dcpext\0apple,dcpext\0' >"$external/compatible"
  printf '\x00\x00\x00\x45' >"$external/phandle"
  printf '%s\0' "$status" >"$external/status"

  printf 'USB-C Left-front\0' >"$conn/label"
  printf 'USB-C Left-back\0' >"$other/label"
  [[ $wired == "yes" ]] && printf '\x00\x00\x00\x45' >"$conn/displayport"
  return 0
}

# The whole point of the check: both halves have to hold. Either one alone is the
# state a machine sits in halfway through enabling this, and reporting success
# there would send someone hunting for a cable fault that does not exist.
make_tree "$TMP/ok" okay yes
OMARCHY_DEVICE_TREE="$TMP/ok" "$ROOT/bin/omarchy-hw-dp-altmode" ||
  fail "dp-altmode is detected when dcpext is enabled and the connector is wired"
pass "dp-altmode is detected when dcpext is enabled and the connector is wired"

make_tree "$TMP/disabled" disabled yes
OMARCHY_DEVICE_TREE="$TMP/disabled" "$ROOT/bin/omarchy-hw-dp-altmode" &&
  fail "dp-altmode is not detected while dcpext is disabled"
pass "dp-altmode is not detected while dcpext is disabled"

make_tree "$TMP/unwired" okay no
OMARCHY_DEVICE_TREE="$TMP/unwired" "$ROOT/bin/omarchy-hw-dp-altmode" &&
  fail "dp-altmode is not detected without the displayport phandle"
pass "dp-altmode is not detected without the displayport phandle"

# A phandle that names no enabled node must not count. This is what a connector
# left pointing at a removed node looks like.
make_tree "$TMP/dangling" okay yes
printf '\x00\x00\x00\x99' >"$TMP/dangling/soc/i2c@235010000/usb-pd@3f/connector/displayport"
OMARCHY_DEVICE_TREE="$TMP/dangling" "$ROOT/bin/omarchy-hw-dp-altmode" &&
  fail "dp-altmode is not detected when the phandle names no enabled node"
pass "dp-altmode is not detected when the phandle names no enabled node"

# The internal panel controller is enabled on every machine. Keying on the node
# name would accept it, since it is called dcp@ exactly like the external one --
# only the compatible string separates them.
make_tree "$TMP/internal" okay yes
printf '\x00\x00\x00\x26' >"$TMP/internal/soc/i2c@235010000/usb-pd@3f/connector/displayport"
OMARCHY_DEVICE_TREE="$TMP/internal" "$ROOT/bin/omarchy-hw-dp-altmode" &&
  fail "dp-altmode is not detected when the phandle names the internal controller"
pass "dp-altmode is not detected when the phandle names the internal controller"

# Non-Apple hardware must fall out of the diagnostic without claiming anything.
mkdir -p "$TMP/pc"
printf 'some,laptop\0' >"$TMP/pc/compatible"
OUT=$(OMARCHY_DEVICE_TREE="$TMP/pc" "$ROOT/bin/omarchy-debug-dp-altmode")
[[ $OUT == *"not an Apple Silicon machine"* ]] ||
  fail "the diagnostic exits cleanly on non-Apple hardware" "$OUT"
pass "the diagnostic exits cleanly on non-Apple hardware"

# The stock Asahi state is the common one, and it has to say plainly that this is
# expected rather than reading as a fault.
OUT=$(PATH="$ROOT/bin:$PATH" OMARCHY_DEVICE_TREE="$TMP/disabled" \
  OMARCHY_TYPEC_PATH="$TMP/none" OMARCHY_DRM_PATH="$TMP/none" \
  "$ROOT/bin/omarchy-debug-dp-altmode")
[[ $OUT == *"expected state on a stock Asahi kernel"* && $OUT == *"Nothing is broken"* ]] ||
  fail "the diagnostic explains the stock Asahi state instead of reporting a fault" "$OUT"
pass "the diagnostic explains the stock Asahi state instead of reporting a fault"

# Asahi's own fairydust branch is where this is actually implemented. Without
# naming it the doc reads as if the only route were a third party's patches.
[[ $OUT == *"fairydust"* ]] ||
  fail "the diagnostic points at Asahi's own branch rather than leaving it unnamed" "$OUT"
pass "the diagnostic points at Asahi's own branch rather than leaving it unnamed"

# A missing detector must never be reported as a negative result. Called by bare
# name it is not on PATH in a checkout, and "NOT enabled" would then be
# indistinguishable from a machine that genuinely lacks the route.
ISOLATED="$TMP/isolated"
mkdir -p "$ISOLATED"
cp "$ROOT/bin/omarchy-debug-dp-altmode" "$ISOLATED/"
set +e
OUT=$(PATH=/usr/bin:/bin OMARCHY_PATH=/nonexistent OMARCHY_DEVICE_TREE="$TMP/ok" \
  bash "$ISOLATED/omarchy-debug-dp-altmode" 2>&1)
rc=$?
set -e
(( rc != 0 )) ||
  fail "the diagnostic fails loudly when the detector is missing" "exit $rc: $OUT"
[[ $OUT != *"NOT enabled"* ]] ||
  fail "a missing detector is not reported as a negative result" "$OUT"
pass "a missing detector fails loudly instead of reading as a negative result"

# Resolved from the script's own directory, a checkout answers for itself.
OUT=$(PATH=/usr/bin:/bin OMARCHY_PATH=/nonexistent OMARCHY_DEVICE_TREE="$TMP/ok" \
  OMARCHY_TYPEC_PATH="$TMP/none" OMARCHY_DRM_PATH="$TMP/none" \
  bash "$ROOT/bin/omarchy-debug-dp-altmode")
[[ $OUT == *"controller: enabled"* ]] ||
  fail "the diagnostic finds the detector next to itself when run from a checkout" "$OUT"
pass "the diagnostic finds the detector next to itself when run from a checkout"

# HDMI is a separate path and works on the machines that have the port. Without
# saying so, someone on a 14"/16" reads this as "no external display at all".
grep -q 'HDMI' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc puts HDMI outside its scope"
grep -q 'fairydust' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc names Asahi's fairydust branch as the canonical work"
pass "the doc scopes out HDMI and names fairydust"

# A reader on a stock kernel must be told that "not enabled" is the expected
# answer there, and that the machine this was written on runs a patched tree --
# without it the two results read as a contradiction rather than as the check
# working.
grep -q 'On a stock tree the check reports the route as not enabled' \
  "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc says a stock tree is expected to report the route as not enabled"
grep -q 'runs such a tree' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc states that the machine it was written against runs a patched tree"
pass "the doc separates the stock answer from the patched one"

# t8112 is the third shape and the strongest case for testing both halves: the
# M2 mini ships the external controller enabled and still has no connector
# wired to it. A check that accepted an enabled controller alone would call
# that machine working.
grep -q 't8112' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc covers t8112 alongside t8103 and t6021"
grep -q 'j473' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc records the enabled-controller-but-unwired machine"
pass "the doc covers t8112 and the enabled-but-unwired case"

# A DisplayLink dock sold as a DisplayPort adapter fails in exactly the shape
# this doc describes, for an unrelated reason. Naming the vendor id is what
# lets someone tell the two apart.
grep -q '17e9' "$ROOT/docs/apple-silicon-dp-altmode.md" ||
  fail "the doc names the DisplayLink vendor id so the two failures can be told apart"
pass "the doc separates a DisplayLink adapter from the alt-mode gap"

# portN is assigned in i2c probe order and has been observed to swap between two
# boots on the same machine, so nothing may resolve the port by its number.
grep -q 'portN' "$ROOT/bin/omarchy-debug-dp-altmode" ||
  fail "the diagnostic records why the port is resolved by i2c address"
grep -qE '0-00\[0-9a-f\]\+' "$ROOT/bin/omarchy-debug-dp-altmode" ||
  fail "the diagnostic resolves the cable's port by i2c address"
pass "the diagnostic resolves the cable's port by i2c address, not by port number"
