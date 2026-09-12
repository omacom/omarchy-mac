#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A leaf that no all.sh sources never runs, and nothing else reports that. The
# Quattro merge left several behind, so pin every stage to its driver.
stages=(config hardware login post-install user)

# Known-unwired leaves. Wiring one means deleting its line here, so the list
# cannot quietly grow and cannot quietly rot.
unwired_leaves=(
  # Quattro moved the Neovim setup into the omarchy-nvim package.
  "config/lazyvim.sh"
  # A function library sourced by omarchy-cmd-tzupdate-*, not a setup leaf.
  "config/timezone-detection.sh"
  # Superseded by the on-demand omarchy-setup-zsh command.
  "config/zsh.sh"
  # Restores mkinitcpio pacman hooks that the x86 ISO disables to speed its
  # install. Nothing on the Mac path disables them, so wiring it would only add
  # a redundant mkinitcpio -P.
  "login/enable-mkinitcpio.sh"
)

leaf_is_known_unwired() {
  local candidate="$1" known
  for known in "${unwired_leaves[@]}"; do
    [[ $candidate == "$known" ]] && return 0
  done
  return 1
}

unwired_found=()
for stage in "${stages[@]}"; do
  all_script="$ROOT/install/$stage/all.sh"
  [[ -f $all_script ]] || fail "install/$stage/all.sh exists"

  while read -r leaf; do
    relative="${leaf#"$ROOT/install/"}"

    [[ $relative == "$stage/all.sh" ]] && continue
    # first-run leaves are driven by omarchy-provision-first-run, not an all.sh.
    [[ $relative == "$stage/first-run/"* ]] && continue
    leaf_is_known_unwired "$relative" && continue

    grep -qF "$relative" "$all_script" || unwired_found+=("install/$relative")
  done < <(find "$ROOT/install/$stage" -name '*.sh' -type f | sort)
done

# Reported together: fixing them one failure at a time hides the real size of it.
if (( ${#unwired_found[@]} )); then
  fail "every install stage leaf is wired into its all.sh" \
    "unwired leaves:$(printf '\n  %s' "${unwired_found[@]}")"
fi
pass "every install stage leaf is wired into its all.sh"

for known in "${unwired_leaves[@]}"; do
  [[ -f "$ROOT/install/$known" ]] ||
    fail "the known-unwired list names real files" "gone: install/$known"
  stage="${known%%/*}"
  if grep -qF "$known" "$ROOT/install/$stage/all.sh"; then
    fail "the known-unwired list only names leaves that are still unwired" "now wired: install/$known"
  fi
done
pass "the known-unwired list is accurate"

# The Apple screen-share picker builds an AUR package, which makepkg refuses to
# do as root, so it has to run in the per-user stage rather than post-install.
grep -qF 'user/hardware/apple/share-picker.sh' "$ROOT/install/user/all.sh" ||
  fail "the Apple screen-share picker runs in the per-user stage"
pass "the Apple screen-share picker runs in the per-user stage"

# Obsidian is the same shape of problem: obsidian in the default set is a
# pkgbase whose outputs are obsidian-bin (x86_64 only) and obsidian-appimage,
# so nothing named "obsidian" installs on aarch64. The substitution builds an
# AUR package, so it belongs in the per-user stage for the same reason.
grep -qF 'user/hardware/apple/obsidian.sh' "$ROOT/install/user/all.sh" ||
  fail "the Apple Obsidian substitution runs in the per-user stage"
pass "the Apple Obsidian substitution runs in the per-user stage"

grep -qF 'user/hardware/apple/mic.sh' "$ROOT/install/user/all.sh" ||
  fail "the Apple Silicon mic mapping runs in the per-user stage"
pass "the Apple Silicon mic mapping runs in the per-user stage"

# Asking for the pkgbase again would reproduce the bug it exists to fix.
grep -qF 'obsidian-appimage' "$ROOT/install/user/hardware/apple/obsidian.sh" ||
  fail "the substitution asks for obsidian-appimage by name"
if grep -qE 'omarchy-pkg-aur-add[[:space:]]+obsidian$' "$ROOT/install/user/hardware/apple/obsidian.sh"; then
  fail "the substitution must not ask for the obsidian pkgbase"
fi
pass "the substitution asks for obsidian-appimage by name"

# Skipped in the base set, installed by name here: one without the other is
# either a wasted build or no Obsidian at all.
grep -qx 'obsidian' "$ROOT/install/omarchy-aarch64-unavailable.packages" ||
  fail "the obsidian pkgbase is skipped in the default set"
pass "the obsidian pkgbase is skipped in the default set"

# The ARM repo carries a built obsidian-appimage, so the substitution must try
# the repos before building 118 MB of AppImage locally -- and must still build
# when the repo is unreachable.
obsidian_script="$ROOT/install/user/hardware/apple/obsidian.sh"
grep -qF 'omarchy-pkg-add obsidian-appimage' "$obsidian_script" ||
  fail "the substitution tries the repos before building"
grep -qF 'omarchy-pkg-aur-add obsidian-appimage' "$obsidian_script" ||
  fail "the substitution still falls back to building"
pass "the substitution prefers the repo and falls back to building"
