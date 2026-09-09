#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/audio.sh"
all="$ROOT/install/hardware/all.sh"
migration=$(grep -rl 'Install the protected Asahi audio stack' "$ROOT/migrations" | head -n 1 || true)

[[ -f $leaf ]] || fail "the Apple Silicon audio setup leaf ships"
grep -Fq 'apple/audio.sh' "$all" ||
  fail "Apple Silicon audio setup runs during hardware setup"
[[ -n $migration ]] || fail "existing Apple Silicon installs get the audio repair"
pass "fresh and existing installs are wired to Apple Silicon audio setup"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
calls="$test_tmp/calls.log"
compatible="$test_tmp/compatible"
installed_marker="$test_tmp/audio-installed"
mkdir -p "$stub_bin"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

printf '%s\n' "$TEST_ARCH"
SH

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

[[ ! -e $AUDIO_INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash

[[ -e $AUDIO_INSTALLED_MARKER ]]
SH

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash

printf 'omarchy-pkg-add' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
if (( ${PACKAGE_INSTALL_SUCCEEDS:-1} == 1 )); then
  touch "$AUDIO_INSTALLED_MARKER"
fi
exit 0
SH

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

"$@"
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash

printf 'systemctl' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

cat >"$stub_bin/omarchy-state" <<'SH'
#!/bin/bash

printf 'omarchy-state' >>"$TEST_LOG"
printf '\t%s' "$@" >>"$TEST_LOG"
printf '\n' >>"$TEST_LOG"
SH

chmod +x "$stub_bin"/*

run_audio_setup() {
  local script="$1" arch="$2" machine="$3" install_succeeds="${4:-1}"
  printf '%s\0' "$machine" >"$compatible"

  PATH="$stub_bin:$ROOT/bin:$PATH" \
    TEST_ARCH="$arch" \
    OMARCHY_UNAME_M="$arch" \
    TEST_LOG="$calls" \
    AUDIO_INSTALLED_MARKER="$installed_marker" \
    PACKAGE_INSTALL_SUCCEEDS="$install_succeeds" \
    OMARCHY_APPLE_COMPATIBLE="$compatible" \
    OMARCHY_PATH="$ROOT" \
    bash -euo pipefail -c 'source "$1"' bash "$script" >/dev/null
}

: >"$calls"
run_audio_setup "$leaf" aarch64 apple,j413

expected_call=$'omarchy-pkg-add\trtkit\tpipewire-pulse\tpipewire-alsa\tasahi-audio\tspeakersafetyd'
grep -Fxq "$expected_call" "$calls" ||
  fail "fresh Apple Silicon installs get the complete protected audio stack" "$(cat "$calls")"
pass "fresh Apple Silicon installs get the complete protected audio stack"

run_audio_setup "$leaf" aarch64 apple,j413
(( $(grep -Fxc "$expected_call" "$calls") == 1 )) ||
  fail "fresh Apple Silicon audio setup is idempotent" "$(cat "$calls")"
pass "fresh Apple Silicon audio setup is idempotent"

rm -f "$installed_marker"
: >"$calls"
run_audio_setup "$migration" aarch64 apple,j413
grep -Fxq "$expected_call" "$calls" ||
  fail "the migration repairs an existing Apple Silicon install" "$(cat "$calls")"
expected_reboot=$'omarchy-state\tset\treboot-required'
grep -Fxq "$expected_reboot" "$calls" ||
  fail "the migration requests the reboot that activates the audio stack" "$(cat "$calls")"

run_audio_setup "$migration" aarch64 apple,j413
(( $(grep -Fxc "$expected_call" "$calls") == 1 )) ||
  fail "the Apple Silicon audio migration is idempotent" "$(cat "$calls")"
(( $(grep -Fxc "$expected_reboot" "$calls") == 1 )) ||
  fail "an already repaired install does not request another reboot" "$(cat "$calls")"
pass "the migration repairs existing Apple Silicon installs idempotently"

rm -f "$installed_marker"
: >"$calls"
errors="$test_tmp/errors.log"
run_audio_setup "$leaf" aarch64 apple,j413 0 2>"$errors" ||
  fail "an incomplete install does not abort hardware setup" "$(cat "$errors")"
grep -Fq 'protected Asahi audio stack is incomplete' "$errors" ||
  fail "fresh setup explains the incomplete audio stack" "$(cat "$errors")"

: >"$calls"
: >"$errors"
run_audio_setup "$migration" aarch64 apple,j413 0 2>"$errors" ||
  fail "an incomplete install does not abort the migration" "$(cat "$errors")"
grep -Fq 'protected Asahi audio stack is incomplete' "$errors" ||
  fail "the migration explains the incomplete audio stack" "$(cat "$errors")"
! grep -Fq 'reboot-required' "$calls" ||
  fail "an incomplete install does not ask for a pointless reboot" "$(cat "$calls")"
pass "an incomplete package install warns instead of aborting"

rm -f "$installed_marker"
: >"$calls"
run_audio_setup "$migration" x86_64 apple,j413
run_audio_setup "$migration" aarch64 linux,dummy
[[ ! -s $calls ]] ||
  fail "the Apple Silicon audio repair skips unrelated hardware" "$(cat "$calls")"
pass "the Apple Silicon audio repair skips unrelated hardware"
