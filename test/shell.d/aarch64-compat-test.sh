#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Static checks first: these run on any machine (and in CI on aarch64) and
# assert the repo's aarch64 surface without needing Asahi hardware. The dynamic
# checks at the bottom simulate aarch64 with stubbed commands.

# x86 configs at default/pacman/ must stay byte-compatible with upstream:
# Architecture = auto and the x86 [omarchy] repo. Pinning aarch64 here would
# break every x86 install the moment this tree is merged.
for config in "$ROOT"/default/pacman/pacman*.conf; do
  grep -qF 'Architecture = auto' "$config" ||
    fail "x86 pacman configs keep Architecture = auto" "missing in: $(basename "$config")"
  grep -qF '[omarchy]' "$config" ||
    fail "x86 pacman configs offer the upstream [omarchy] repo" "missing in: $(basename "$config")"
  grep -qF 'pkgs.omarchy.org' "$config" ||
    fail "x86 pacman configs point at pkgs.omarchy.org" "missing in: $(basename "$config")"
  grep -qF 'Architecture = aarch64' "$config" &&
    fail "x86 pacman configs must not pin aarch64" "pinned in: $(basename "$config")"
  grep -qF '[omarchy-aarch64]' "$config" &&
    fail "x86 pacman configs must not offer the ARM repo" "in: $(basename "$config")"
done
pass "x86 pacman configs match upstream"

grep -qF 'Server = https://pkgs.omarchy.org/stable/$arch' "$ROOT/default/pacman/pacman-stable.conf" ||
  fail "x86 stable pacman config points at the stable Omarchy repo"
grep -qF 'Server = https://pkgs.omarchy.org/rc/$arch' "$ROOT/default/pacman/pacman-rc.conf" ||
  fail "x86 rc pacman config points at the rc Omarchy repo, not edge"
grep -qF 'Server = https://pkgs.omarchy.org/edge/$arch' "$ROOT/default/pacman/pacman-edge.conf" ||
  fail "x86 edge pacman config points at the edge Omarchy repo"
pass "x86 pacman channel configs keep their upstream repo URLs"

# aarch64 configs live under default/pacman/aarch64/ so they cannot leak into
# an x86 refresh. They pin aarch64, offer the community ARM repository, and
# restrict official edge to explicitly selected compatibility packages.
for config in "$ROOT"/default/pacman/aarch64/pacman*.conf; do
  grep -qF 'Architecture = aarch64' "$config" ||
    fail "every aarch64 pacman config pins aarch64" "missing in: $(basename "$config")"
  grep -qF '[omarchy-aarch64]' "$config" ||
    fail "every aarch64 pacman config offers the Omarchy ARM repo" "missing in: $(basename "$config")"
  section=$(awk '/^\[/ { selected = ($0 == "[omarchy]") } selected { print }' "$config")
  grep -qxF 'Usage = Sync' <<< "$section" || fail "official edge requires explicit targets in $config"
  grep -qxF 'SigLevel = Required DatabaseOptional' <<< "$section" || fail "official edge requires signed packages in $config"
  grep -qxF 'Server = https://pkgs.omarchy.org/edge/$arch' <<< "$section" || fail "official edge uses target architecture in $config"
  if grep '^[[:space:]]*Server.*pkgs\.omarchy\.org' "$config" | grep -vxF 'Server = https://pkgs.omarchy.org/edge/$arch'; then
    fail "no x86 or alternate-channel official repository in $config"
  fi
done
pass "aarch64 pacman configs pin ARM and restrict official edge"

# The regular distribution mirrorlists must remain Arch Linux ARM sources;
# official edge belongs only in its restricted, separate repository section.
leaky=()
while read -r file; do
  [[ -n $file ]] || continue
  leaky+=("${file#"$ROOT"/}")
done < <(grep -l 'omarchy\.org' "$ROOT"/default/pacman/aarch64/mirrorlist* 2>/dev/null || true)
(( ${#leaky[@]} == 0 )) ||
  fail "no aarch64 mirrorlist points at an x86 Omarchy mirror" "still x86: ${leaky[*]}"
pass "no aarch64 mirrorlist points at an x86 Omarchy mirror"

# refresh-pacman selects the tree from omarchy-hw-aarch64 rather than shipping
# a single aarch64-only pacman.conf.
grep -qF 'machine_arch=$(omarchy-hw-arch)' "$ROOT/bin/omarchy-refresh-pacman" ||
  fail "omarchy-refresh-pacman selects the pacman tree by architecture"
pass "omarchy-refresh-pacman selects the pacman tree by architecture"

grep -qF 'pkgs.omarchy.org/$candidate/' "$ROOT/bin/omarchy-refresh-pacman-mirrorlist" &&
  grep -qF 'mirrorlist-$channel' "$ROOT/bin/omarchy-refresh-pacman-mirrorlist" ||
  fail "the x86 mirrorlist refresh follows the installed package channel"
pass "the x86 mirrorlist refresh follows the installed package channel"

# Paths must derive from OMARCHY_PATH (AGENTS.md); a hardcoded HOME breaks once
# the checkout is wired to /usr/share/omarchy.
if grep -qF '$HOME/.local/share/omarchy' "$ROOT/bin/omarchy-refresh-pacman-mirrorlist"; then
  fail "the mirrorlist refresh derives its source from OMARCHY_PATH, not HOME"
fi
pass "the mirrorlist refresh derives its source from OMARCHY_PATH"

# The upstream x86 upgrade rewrites /etc/pacman.d/mirrorlist to x86 mirrors and
# must refuse to run on Apple Silicon (the inverse of the guard in
# omarchy-upgrade-to-quattro-mac). It is not safe to execute here — it writes
# /etc through sudo — so assert the guard statically instead.
grep -qF '    x86_64) ;;' "$ROOT/bin/omarchy-upgrade-to-quattro" ||
  fail "the upstream x86 upgrade fences itself off on Apple Silicon"
pass "the upstream x86 upgrade fences itself off on Apple Silicon"

negated_arch_calls=$(rg -n '! omarchy-hw-aarch64' "$ROOT/bin" "$ROOT/install" || true)
[[ -z $negated_arch_calls ]] ||
  fail "architecture gates never turn a missing detector into x86 success" "$negated_arch_calls"
pass "all architecture gates fail closed when detection is unavailable"

# Required package failure propagation is exercised with the real helper and
# mocked package transactions in pkg-add-test.sh, equally on ARM and x86.
