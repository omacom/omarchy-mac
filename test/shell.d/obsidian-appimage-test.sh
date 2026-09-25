#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/user/hardware/apple/obsidian.sh"
all="$ROOT/install/user/all.sh"

grep -Fq 'hardware/apple/obsidian.sh' "$all" ||
  fail "Obsidian AppImage setup runs during user setup"
pass "Obsidian AppImage setup runs during user setup"

require_platform_fixtures "the Obsidian platform gate"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ ${OBSIDIAN_PRESENT:-0} != 1 && ! -e ${OBSIDIAN_INSTALLED:-/nonexistent} ]]
SH
cat >"$stub_bin/omarchy-pkg-available" <<'SH'
#!/bin/bash
[[ ${REPO_HAS_OBSIDIAN:-1} == 1 ]]
SH
cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'pkg-add %s\n' "$*" >>"$TEST_LOG"
touch "$OBSIDIAN_INSTALLED"
SH
cat >"$stub_bin/omarchy-pkg-aur-add" <<'SH'
#!/bin/bash
printf 'aur-add %s\n' "$*" >>"$TEST_LOG"
SH
chmod +x "$stub_bin"/*
for platform in apple-silicon qualcomm generic; do
  fake_platform "$test_tmp/$platform" "$platform"
done

run_leaf() {
  local fixture="$test_tmp/${1:-generic}"
  : >"$calls"
  rm -f "$test_tmp/installed"
  OBSIDIAN_PRESENT="${2:-0}" REPO_HAS_OBSIDIAN="${3:-1}" \
    TEST_LOG="$calls" OBSIDIAN_INSTALLED="$test_tmp/installed" OMARCHY_PROC_ROOT="$fixture/proc" \
    PATH="$stub_bin:$fixture/bin:$ROOT/bin:$PATH" bash -c 'source "$1"' _ "$leaf"
}

run_leaf generic 0
[[ ! -s $calls ]] || fail "x86 does not install obsidian-appimage" "$(cat "$calls")"
pass "x86 leaves the packaged Obsidian name alone"

run_leaf qualcomm 0
[[ ! -s $calls ]] || fail "the Apple leaf does not install Obsidian on Qualcomm" "$(cat "$calls")"
pass "the Apple leaf leaves other aarch64 platforms alone"

run_leaf apple-silicon 1
[[ ! -s $calls ]] || fail "Apple Silicon does not reinstall a present Obsidian" "$(cat "$calls")"
pass "Apple Silicon skips Obsidian when the command is already present"

run_leaf apple-silicon 0
grep -Fxq 'pkg-add obsidian-appimage' "$calls" ||
  fail "Apple Silicon asks the repos for obsidian-appimage" "$(cat "$calls")"
! grep -q aur-add "$calls" || fail "a repo install does not also build from the AUR" "$(cat "$calls")"
pass "Apple Silicon installs Obsidian from the AppImage package"

run_leaf apple-silicon 0 0
grep -Fxq 'aur-add obsidian-appimage' "$calls" ||
  fail "Apple Silicon falls back to the AUR when the repos lack obsidian-appimage" "$(cat "$calls")"
! grep -q pkg-add "$calls" ||
  fail "Apple Silicon does not call pkg-add when the repos lack the package" "$(cat "$calls")"
pass "Apple Silicon falls back to the AUR when the repos lack obsidian-appimage"
