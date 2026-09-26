#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/shell.d/base-test.sh"

harness="$ROOT/tools/acceptance/mac-image/run"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
unset "${!OMARCHY_VM_@}"

# A host that is not an aarch64 KVM host: a run that gets past its arguments
# stops at the first host check.
mkdir -p "$test_tmp/bin"
printf '#!/bin/bash\necho x86_64\n' >"$test_tmp/bin/uname"
chmod +x "$test_tmp/bin/uname"

run_harness() {
  PATH="$test_tmp/bin:$PATH" HOME="$test_tmp/home" bash "$harness" "$@" >"$test_tmp/out" 2>&1
}

scenarios=(first-boot conversion second-boot password-change recovery-reset update snapshot-restore factory-reset)

run_harness --list || fail "--list succeeds" "$(cat "$test_tmp/out")"
for name in "${scenarios[@]}" fresh-install all; do
  grep -Eq "^$name +[^ ]" "$test_tmp/out" || fail "--list names $name" "$(cat "$test_tmp/out")"
done
[[ ! -e $test_tmp/home ]] || fail "--list touches no state"
pass "--list names every scenario and the fresh-install and all sets without touching state"

for name in "${scenarios[@]}"; do
  grep -Eq "^scenario_${name//-/_}\(\) \{" "$harness" || fail "$name has a scenario function"
done
pass "every listed scenario has its own function"

expect_refusal() {
  local message=$1
  shift
  ! run_harness "$@" || fail "refuses: $*"
  grep -Fq -- "$message" "$test_tmp/out" || fail "refuses $* with: $message" "$(cat "$test_tmp/out")"
}

expect_refusal "Unknown scenario: reboot" --image "$test_tmp" --scenario first-boot,reboot
expect_refusal "give --image DIR or --payload ZIP" --scenario first-boot
expect_refusal "--image and --payload are exclusive" --image "$test_tmp" --payload "$test_tmp/p.zip"
expect_refusal "--lane is read from IMAGE with --image" --image "$test_tmp" --lane rc
expect_refusal "--scenario needs a name" --image "$test_tmp" --scenario
expect_refusal "Unknown option: --release" --release mac-image-10-rc
OMARCHY_VM_RUN_ID="../x" expect_refusal "OMARCHY_VM_RUN_ID must be" --image "$test_tmp"
pass "bad scenarios, inputs and run IDs are refused before the host is checked"

for selection in fresh-install all "update,snapshot-restore" second-boot; do
  expect_refusal "this harness boots aarch64 guests" --image "$test_tmp" --scenario "$selection"
done
[[ ! -e $test_tmp/home ]] || fail "a refused host keeps no state"
pass "valid selections reach the host checks, and a refused host keeps no state"

# The cases that wait for an entrypoint probe the paths their skip reasons name.
for path in /usr/lib/omarchy/mac-boot/update-verify /usr/bin/omarchy-drive-recover /etc/boot/hooks/pre.d/04-omarchy-mac-snapshot-check /usr/lib/omarchy/mac-boot/reset-prepare; do
  [[ $(grep -Fc -- "$path" "$harness") -ge 2 ]] || fail "$path is both probed and named in its skip reason"
done
pass "each entrypoint case probes the path its skip reason names"
