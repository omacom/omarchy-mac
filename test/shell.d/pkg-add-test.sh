#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"
cat >"$work/bin/pacman" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$PKG_LOG"
case $1 in
  -Q) [[ -f $PKG_STATE/$2 ]] ;;
  -S)
    [[ $PKG_CASE != transaction ]] || exit 5
    [[ $* != *unavailable* ]] || exit 1
    [[ $PKG_CASE != silent ]] || exit 0
    for package in "${@:2}"; do
      [[ $package == -* ]] || touch "$PKG_STATE/$package"
    done
    ;;
  *) exit 99 ;;
esac
SH
cat >"$work/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$ROOT/bin:$PATH" PKG_STATE="$work/state" PKG_LOG="$work/pacman.log"
for architecture in aarch64 arm64 x86_64; do
  export OMARCHY_UNAME_M="$architecture"
  for scenario in success transaction silent unavailable installed; do
    rm -f "$PKG_STATE/"* "$PKG_LOG"
    export PKG_CASE="$scenario"
    packages=(required)
    [[ $scenario != unavailable ]] || packages+=(unavailable)
    [[ $scenario != installed ]] || touch "$PKG_STATE/required"
    status=0
    "$ROOT/bin/omarchy-pkg-add" "${packages[@]}" >"$work/output" 2>&1 || status=$?
    case $scenario in
      success|installed) (( status == 0 )) || fail "$architecture $scenario succeeds" ;;
      *) (( status != 0 )) || fail "$architecture $scenario must propagate failure" ;;
    esac
    ! grep -q '^-Si' "$PKG_LOG" || fail "required packages are never filtered by repo lookup"
    if [[ $scenario == installed ]]; then
      ! grep -q '^-S ' "$PKG_LOG" || fail "already installed targets need no transaction"
    else
      grep -q -- '-S --noconfirm --needed required' "$PKG_LOG" || fail "the required target reaches pacman"
    fi
    [[ $scenario != unavailable ]] || grep -q -- 'required unavailable' "$PKG_LOG" || fail "an unavailable target is not silently dropped"
  done
done
pass "ARM and x86 preserve transaction, missing-package and false-success failures with the upstream required-package helper"
