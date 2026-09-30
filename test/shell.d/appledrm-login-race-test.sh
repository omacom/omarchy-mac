#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

leaf="$ROOT/install/hardware/apple/fix-appledrm-login-race.sh"
all="$ROOT/install/hardware/all.sh"
migration="$ROOT/migrations/1790792903.sh"

grep -Fq 'apple/fix-appledrm-login-race.sh' "$all" ||
  fail "the SDDM wait runs during hardware setup"
[[ -f $migration ]] || fail "existing installs get the SDDM wait"
grep -Fq 'install/hardware/apple/fix-appledrm-login-race.sh' "$migration" ||
  fail "the migration runs the hardware leaf"
pass "fresh and existing installs are wired to the SDDM wait"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
dropin_dir="$test_tmp/etc/systemd/system/sddm.service.d"
dropin="$dropin_dir/wait-appledrm.conf"
compatible="$test_tmp/device-tree-compatible"
mkdir -p "$stub_bin"

# Every case says which architecture it runs on rather than inherit the
# machine running the suite.
cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

if [[ ${1:-} == "-m" ]]; then
  echo "${ARCH:-aarch64}"
else
  exec /usr/bin/uname "$@"
fi
SH
chmod +x "$stub_bin/uname"

# run_logged sources leaves under bash -eE; the migration runs the same file
# under pipefail, so exercise the stricter of the two.
run_leaf() {
  local arch="$1" machine="$2"
  rm -rf "$test_tmp/etc"
  if [[ -n $machine ]]; then
    printf '%s\0' "$machine" >"$compatible"
  else
    rm -f "$compatible"
  fi
  ARCH="$arch" PATH="$stub_bin:$PATH" \
    OMARCHY_DEVICE_TREE_COMPATIBLE="$compatible" OMARCHY_SDDM_DROPIN_DIR="$dropin_dir" \
    bash -eE -o pipefail -c 'source "$1"' bash "$leaf" </dev/null >/dev/null
}

for machine in apple,j314s apple,j293 apple,j414c; do
  run_leaf aarch64 "$machine"
  [[ -f $dropin ]] || fail "an Apple Silicon Mac gets the SDDM wait" "$machine"
done
pass "an Apple Silicon Mac gets the SDDM wait"

# A failed or timed-out wait must never keep SDDM from starting.
grep -Eq '^ExecStartPre=-/usr/bin/udevadm wait --timeout=[0-9]+ /dev/dri/by-path/platform-soc:display-subsystem-card$' "$dropin" ||
  fail "the wait is bounded and cannot block SDDM" "$(cat "$dropin")"
grep -qx '\[Service\]' "$dropin" || fail "the drop-in has a [Service] section" "$(cat "$dropin")"
pass "the wait is bounded and cannot block SDDM"

run_leaf x86_64 apple,j314s
[[ ! -e $dropin ]] || fail "an x86 machine gets no SDDM wait"
run_leaf aarch64 ""
[[ ! -e $dropin ]] || fail "an arm64 machine without a device tree gets no SDDM wait"
run_leaf aarch64 "raspberrypi,5-model-b"
[[ ! -e $dropin ]] || fail "a non-Apple arm64 machine gets no SDDM wait"
pass "other machines get no SDDM wait"
