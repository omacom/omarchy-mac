#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-steam-fex is the Apple Silicon launcher (muvm and FEX), so the
# installer and the migration for existing Steam installs gate on the platform,
# not on the CPU architecture.
installer="$ROOT/bin/omarchy-install-gaming-steam"
migration="$ROOT/migrations/1789522888.sh"

require_platform_fixtures "the Steam FEX platform gates"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
mkdir -p "$stub_bin" "$test_tmp/home"

for command_name in omarchy-pkg-add omarchy-launch-steam; do
  cat >"$stub_bin/$command_name" <<'SH'
#!/bin/bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$TEST_LOG"
SH
done
for command_name in omarchy-install-gaming-gpu-lib32 omarchy-pkg-present omarchy-cmd-present setsid; do
  printf '#!/bin/bash\nexit 0\n' >"$stub_bin/$command_name"
done
chmod +x "$stub_bin"/*

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/$platform" "$platform"
done

run_on() {
  local platform="$1" fixture="$test_tmp/$1"
  shift
  : >"$calls"
  TEST_LOG="$calls" HOME="$test_tmp/home" OMARCHY_PROC_ROOT="$fixture/proc" \
    PATH="$stub_bin:$fixture/bin:$ROOT/bin:$PATH" "$@" >/dev/null
}

run_on apple-silicon bash "$installer"
grep -Fxq 'omarchy-pkg-add steam omarchy-steam-fex' "$calls" ||
  fail "Apple Silicon installs Steam with omarchy-steam-fex" "$(cat "$calls")"
grep -Fxq 'omarchy-launch-steam --prepare' "$calls" ||
  fail "Apple Silicon prepares the FEX launcher" "$(cat "$calls")"
pass "the Steam installer adds the FEX launcher on Apple Silicon"

for platform in qualcomm generic-aarch64 generic; do
  run_on "$platform" bash "$installer"
  grep -Fxq 'omarchy-pkg-add steam' "$calls" ||
    fail "$platform installs plain Steam" "$(cat "$calls")"
  ! grep -Fq 'omarchy-launch-steam' "$calls" ||
    fail "$platform does not prepare the Apple FEX launcher" "$(cat "$calls")"
done
pass "the Steam installer keeps the Apple FEX launcher off other platforms"

run_on apple-silicon bash -euo pipefail "$migration"
grep -Fxq 'omarchy-pkg-add omarchy-steam-fex' "$calls" ||
  fail "the migration adds omarchy-steam-fex to existing Apple Silicon Steam installs" "$(cat "$calls")"
pass "the migration adds omarchy-steam-fex to existing Apple Silicon Steam installs"

for platform in qualcomm generic-aarch64 generic; do
  run_on "$platform" bash -euo pipefail "$migration"
  [[ ! -s $calls ]] || fail "the migration leaves $platform Steam installs alone" "$(cat "$calls")"
done
pass "the migration leaves Steam installs on other platforms alone"
