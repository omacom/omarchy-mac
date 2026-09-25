#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_platform_fixtures "the settings runtime profile"

# omarchy-settings ships the same mkinitcpio drop-ins on every platform; each
# decides at runtime what it adds. Compose them the way mkinitcpio does: the
# main config, then every drop-in in C sort order, concatenated and sourced once.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ -f $ROOT/default/settings-runtime-profile ]] ||
  fail "the source marks itself for the omarchy-settings recipe"

stock_hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
omarchy_hooks="base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs"

# An Apple boot package fragment: it sorts before omarchy_hooks.conf and adds
# its hook to whatever HOOKS it finds.
cat >"$work/90-apple-fragment.conf" <<'CONF'
_fragment_hooks=()
for _fragment_hook in "${HOOKS[@]}"; do
  [[ $_fragment_hook == filesystems ]] && _fragment_hooks+=(asahi)
  _fragment_hooks+=("$_fragment_hook")
done
HOOKS=("${_fragment_hooks[@]}")
unset _fragment_hooks _fragment_hook
CONF

# Prints "HOOKS|MODULES" for a platform, with or without the Apple fragment.
composed() {
  local platform=$1 fragment=$2 conf_d="$work/$1-$2/mkinitcpio.conf.d"

  fake_platform "$work/$platform" "$platform"
  mkdir -p "$conf_d"
  printf 'MODULES=()\nFILES=()\nHOOKS=(%s)\n' "$stock_hooks" >"$work/$platform-$fragment/mkinitcpio.conf"
  cp "$ROOT"/etc/mkinitcpio.conf.d/*.conf "$conf_d/"
  if [[ $fragment == with-fragment ]]; then
    cp "$work/90-apple-fragment.conf" "$conf_d/"
  fi

  {
    cat "$work/$platform-$fragment/mkinitcpio.conf"
    LC_ALL=C find "$conf_d" -maxdepth 1 -name '*.conf' -print0 | LC_ALL=C sort -z | xargs -0 cat
  } >"$work/$platform-$fragment/config"

  OMARCHY_PROC_ROOT="$work/$platform/proc" PATH="$work/$platform/bin:$ROOT/bin:$PATH" \
    OMARCHY_PCI_DEVICES_PATH="$work/no-pci" bash -c '
      XKBLAYOUT=us
      source "$1"
      printf "%s|%s\n" "${HOOKS[*]}" "${MODULES[*]}"
    ' bash "$work/$platform-$fragment/config"
}

result=$(composed apple-silicon with-fragment)
[[ ${result%%|*} == "${stock_hooks/filesystems/asahi filesystems}" ]] ||
  fail "Apple Silicon keeps the HOOKS its platform composed" "actual: ${result%%|*}"
[[ " ${result#*|} " == *" thunderbolt? "* ]] ||
  fail "Apple Silicon asks for the Thunderbolt module only if its kernel has it" "actual: ${result#*|}"
pass "Apple Silicon keeps the HOOKS its platform composed"

for platform in qualcomm generic-aarch64 generic; do
  result=$(composed "$platform" without-fragment)
  [[ ${result%%|*} == "$omarchy_hooks" ]] ||
    fail "$platform gets the Omarchy HOOKS baseline" "actual: ${result%%|*}"
  [[ ${result#*|} == "thunderbolt?" ]] ||
    fail "$platform asks for the Thunderbolt module only if its kernel has it" "actual: ${result#*|}"
done
pass "every other platform gets the Omarchy HOOKS baseline and an optional Thunderbolt module"

# The detector failing (contradictory identity) or missing leaves the baseline
# in place, as before the profile existed.
mkdir -p "$work/contradiction/proc/device-tree"
printf '%s\0' apple,j416c qcom,x1e80100 >"$work/contradiction/proc/device-tree/compatible"
hooks=$(OMARCHY_PROC_ROOT="$work/contradiction/proc" PATH="$ROOT/bin:$PATH" bash -c '
  XKBLAYOUT=us FILES=()
  source "$1"
  echo "${HOOKS[*]}"
' bash "$ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>&1)
[[ $hooks == "$omarchy_hooks" ]] || fail "a failing detector keeps the baseline" "actual: $hooks"
mkdir -p "$work/empty-path"
hooks=$(PATH="$work/empty-path" /bin/bash -c '
  XKBLAYOUT=us FILES=()
  source "$1"
  echo "${HOOKS[*]}"
' bash "$ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>&1)
[[ $hooks == "$omarchy_hooks" ]] || fail "a missing detector keeps the baseline quietly" "actual: $hooks"
pass "without a platform answer the baseline applies, as it did before"
