#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMARCHY_PATH="$ROOT"
source "$ROOT/install/helpers/pacman.sh"
omarchy-hw-platform() { echo "${fixture_platform:-generic}"; }
omarchy-hw-apple-silicon() { [[ ${fixture_platform:-generic} == "apple-silicon" ]]; }
repositories() { grep -o '^\[[^]]*\]' "$1" | tr -d '[]' | grep -vx options | tr '\n' ' '; }
for fixture_platform in generic apple-silicon qualcomm generic-aarch64; do
  for channel in stable rc edge; do
    omarchy_pacman_stage "$channel" "$work"
    case $fixture_platform in
      apple-silicon)
        [[ $(repositories "$work/pacman.conf") == "omarchy asahi-alarm core extra alarm aur " ]] ||
          fail 'Apple Silicon puts Omarchy first, then Asahi ALARM and Arch Linux ARM' "$(repositories "$work/pacman.conf")"
        ! omarchy_pacman_channel_qualified "$channel" || fail 'unqualified ARM channel refused'
        ;;
      qualcomm | generic-aarch64)
        [[ $(repositories "$work/pacman.conf") == "core extra alarm aur omarchy " ]] ||
          fail "$fixture_platform gets Arch Linux ARM and Omarchy, no Asahi repository" "$(repositories "$work/pacman.conf")"
        ;;
      generic)
        cmp -s "$work/pacman.conf" "$ROOT/default/pacman/pacman-$channel.conf" || fail 'x86 keeps its template'
        cmp -s "$work/mirrorlist" "$ROOT/default/pacman/mirrorlist-$channel" || fail 'x86 keeps its mirrors'
        omarchy_pacman_channel_qualified "$channel" || fail 'x86 channels remain available'
        ;;
    esac
    if [[ $fixture_platform != "generic" ]]; then
      ! grep -Fq '[multilib]' "$work/pacman.conf" || fail 'no x86 repository on ARM'
      grep -Fq '/$arch/$repo' "$work/mirrorlist" || fail 'ALARM mirror layout'
    fi
    grep -Fq "https://pkgs.omarchy.org/$channel/" "$work/pacman.conf" || fail 'selected channel URL'
  done
done
! omarchy_pacman_stage nonsense "$work" || fail 'invalid channel refused'
omarchy-hw-platform() { return 1; }
! omarchy_pacman_stage stable "$work" || fail 'an unknown platform stages nothing'
omarchy-hw-platform() { echo "${fixture_platform:-generic}"; }
pass "staging selects each platform's repositories for every channel"

# Exercise the source-controlled enablement seam with a test-only copy.
sed 's/qualified_arm_channels=()/qualified_arm_channels=(stable rc edge)/' "$ROOT/install/helpers/pacman.sh" >"$work/qualified.sh"
source "$work/qualified.sh"
fixture_platform=apple-silicon
for channel in stable rc edge; do omarchy_pacman_channel_qualified "$channel" || fail 'qualified ARM channel selectable'; done

# Preflight failures occur in an isolated database; no live package command.
sudo() { "$@"; }
pacman() { printf '%s\n' "$*" >>"$work/calls"; return "${pacman_status:-0}"; }
omarchy_pacman_stage edge "$work"
omarchy_pacman_preflight "$work" edge
for target in omarchy-dev omarchy-settings-dev omarchy-mac linux-asahi asahi-alarm-keyring; do
  grep -Fq "$target" "$work/calls" || fail "ARM preflight checks $target"
done
grep -Fq -- "--dbpath $work/db" "$work/calls" || fail 'preflight database isolated'
! grep -Fq '/etc/pacman.d/mirrorlist' "$work/check.conf" || fail 'preflight mirrorlist isolated'
pacman_status=42
status=0
omarchy_pacman_preflight "$work" edge || status=$?
[[ $status == 1 ]] || fail 'preflight failure blocks staging into live configuration'
pass 'qualified path preflights required packages and propagates failures'

# Shipped ARM finalization preserves the ISO-managed configuration without I/O.
source "$ROOT/install/helpers/pacman.sh"
cp() { fail 'offline unqualified ARM finalization must preserve existing files'; }
omarchy_pacman_finalize stable
pass 'offline finalization performs no sync or live configuration replacement'

# The package-resolution fixtures resolve the same repositories, in the same
# order, as each platform's edge template.
for fixture in apple:apple-silicon qualcomm:aarch64 generic-aarch64:aarch64; do
  [[ $(repositories "$ROOT/tools/package-resolution/platforms/${fixture%%:*}/pacman.conf") == \
    "$(repositories "$ROOT/default/pacman/${fixture#*:}/pacman-edge.conf")" ]] ||
    fail "the ${fixture%%:*} resolution fixture follows default/pacman/${fixture#*:}"
done
pass "package-resolution fixtures follow each platform's repositories"
