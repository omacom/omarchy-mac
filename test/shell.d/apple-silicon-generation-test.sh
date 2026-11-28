#!/bin/bash

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source "$test_dir/base-test.sh"

authority="$ROOT/bin/omarchy-hw-apple-silicon-generation"
parser_bash="${PARSER_BASH:-/bin/bash}"
[[ -x $authority ]] || fail "Apple Silicon generation authority is executable"
pass "Apple Silicon generation authority is executable"

header=$(awk '
  NR == 1 && /^#!/ { next }
  /^[[:space:]]*$/ { if (seen) print; next }
  /^[[:space:]]*#/ { seen=1; print; next }
  { exit }
' "$authority")
grep -Fqx '# omarchy:summary=Identify the Apple Silicon generation from device-tree data' <<<"$header" ||
  fail "generation authority has command metadata"
grep -Fqx '# omarchy:hidden=true' <<<"$header" || fail "generation authority is hidden"
pass "generation authority has hidden command metadata"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
fixture="$test_tmp/compatible"
stderr_file="$test_tmp/stderr"

run_parser() {
  local mode="$1" expected_status="$2" expected_output="$3" expected_reason="$4"
  local source_path="${5:-$fixture}"
  local actual_output actual_status
  if actual_output=$("$parser_bash" -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" "$3"' bash "$authority" "$source_path" "$mode" 2>"$stderr_file"); then
    actual_status=0
  else
    actual_status=$?
  fi
  [[ $actual_status == "$expected_status" ]] || fail "$expected_reason status" "expected $expected_status, got $actual_status"
  [[ $actual_output == "$expected_output" ]] || fail "$expected_reason stdout" "expected <$expected_output>, got <$actual_output>"
  if [[ $mode == "key" ]]; then
    if (( expected_status == 0 )); then
      [[ ! -s $stderr_file ]] || fail "$expected_reason key mode is quiet" "$(cat "$stderr_file")"
    else
      grep -Fqx "$expected_reason" "$stderr_file" || fail "$expected_reason key mode reports reason" "$(cat "$stderr_file")"
    fi
  fi
}

set_fixture() {
  printf '%b' "$1" >"$fixture"
}

confirmed_cases='m1|apple,t8103
m1-pro|apple,t6000
m1-max|apple,t6001
m1-ultra|apple,t6002
m2|apple,t8112
m2-pro|apple,t6020
m2-max|apple,t6021
m2-ultra|apple,t6022
m3|apple,t8122
m3-pro|apple,t6030
m3-ultra|apple,t6032
m4|apple,t8132'
while IFS='|' read -r expected token; do
  [[ -n $expected ]] || continue
  set_fixture "apple,j274\\0$token\\0apple,arm-platform\\0"
  run_parser key 0 "$expected" identity-confirmed
  pass "confirmed $token maps to $expected"
done <<<"$confirmed_cases"

for token in apple,t6031 apple,t6034; do
  set_fixture "apple,j514\\0$token\\0"
  run_parser key 0 m3-max identity-confirmed
  pass "confirmed M3 Max token $token maps to m3-max"
done

set_fixture 'apple,j274\0apple,arm-platform\0'
run_parser key 1 '' unrecognized-compatible
set_fixture 'arm64\0brcm,foo\0apple,arm-platform\0'
run_parser key 1 '' unrecognized-compatible
set_fixture 'apple,t6040\0'
run_parser key 1 '' unconfirmed-compatible
set_fixture 'apple,t6041\0'
run_parser key 1 '' unconfirmed-compatible
set_fixture 'apple,t9999\0'
run_parser key 1 '' unrecognized-compatible
pass "context, unconfirmed, and unknown selectors fail closed"

set_fixture 'apple,t8103\0apple,t8103\0'
run_parser key 1 '' ambiguous-compatible
set_fixture 'apple,t8103\0apple,t8122\0'
run_parser key 1 '' conflicting-compatible
set_fixture 'apple,t8122\0apple,t8103\0'
run_parser key 1 '' conflicting-compatible
set_fixture 'apple,t6031\0apple,t6034\0'
run_parser key 1 '' conflicting-compatible
set_fixture 'apple,t8103\0apple,t9999\0'
run_parser key 1 '' conflicting-compatible
set_fixture 'apple,t8103\0apple,t6040\0'
run_parser key 1 '' conflicting-compatible
pass "selector multiplicity is order-independent"

set_fixture ''
run_parser key 1 '' empty-compatible
set_fixture '\0'
run_parser key 1 '' empty-compatible
set_fixture 'apple,t8103\0\0'
run_parser key 1 '' empty-compatible
set_fixture 'apple,t8103'
run_parser key 1 '' truncated-record
set_fixture 'apple,t8103\377\0'
run_parser key 1 '' non-ascii-compatible
set_fixture 'apple,t8103\303\251\0'
run_parser key 1 '' non-ascii-compatible
set_fixture 'apple,t810x\0'
run_parser key 1 '' malformed-compatible
set_fixture 'apple,t81030\0'
run_parser key 1 '' malformed-compatible
set_fixture 'apple,t810x\0apple,t8103\377\0'
run_parser key 1 '' non-ascii-compatible
set_fixture 'apple,t8103\377\0apple,t810x\0'
run_parser key 1 '' non-ascii-compatible
set_fixture 'apple,t810x\0\0apple,t8103\377\0'
run_parser key 1 '' empty-compatible
pass "byte and grammar precedence is deterministic"

missing="$test_tmp/missing"
if "$parser_bash" -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" key' bash "$authority" "$missing" >"$test_tmp/missing-out" 2>"$stderr_file"; then
  fail "missing compatible path is rejected"
fi
[[ ! -s $test_tmp/missing-out ]] || fail "missing path has no key output"
grep -Fqx missing-compatible "$stderr_file" || fail "missing path reports its reason"
mkdir "$test_tmp/directory"
run_parser key 1 '' unreadable-compatible "$test_tmp/directory"
pass "missing and unreadable sources fail closed"

set_fixture 'apple,t8103\0'
if diagnose=$("$parser_bash" -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" diagnose' bash "$authority" "$fixture" 2>"$stderr_file"); then
  :
else
  fail "diagnose accepts a confirmed fixture" "$(cat "$stderr_file")"
fi
[[ -z $diagnose ]] || fail "diagnose has no stdout"
grep -Fqx "source=$fixture" "$stderr_file" || fail "diagnose reports source"
grep -Fqx 'record[0]=\x61\x70\x70\x6c\x65\x2c\x74\x38\x31\x30\x33' "$stderr_file" || fail "diagnose escapes every record byte"
! grep -Fq 'apple,t8103' "$stderr_file" || fail "diagnose never echoes raw records"
grep -Fqx 'key=m1' <(grep '^key=' "$stderr_file") || fail "diagnose reports derived key"
grep -Fqx 'reason=identity-confirmed' <(grep '^reason=' "$stderr_file") || fail "diagnose reports identity reason"
pass "diagnose uses canonical escaped stderr output"

set_fixture 'apple,t8103\377\0'
if diagnose=$($parser_bash -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" diagnose' bash "$authority" "$fixture" 2>"$stderr_file"); then
  fail "diagnose rejects a non-ASCII record"
fi
[[ -z $diagnose ]] || fail "failed diagnose has no stdout"
grep -Fqx 'record[0]=\x61\x70\x70\x6c\x65\x2c\x74\x38\x31\x30\x33\xff' "$stderr_file" || fail "diagnose escapes invalid bytes"
! grep -Fq 'apple,t8103' "$stderr_file" || fail "failed diagnose never echoes raw records"
grep -Fqx 'reason=non-ascii-compatible' <(grep '^reason=' "$stderr_file") || fail "diagnose reports non-ASCII reason"
pass "diagnose escapes rejected bytes without raw output"

set_fixture 'apple,t8103\0'
if direct=$("$parser_bash" -c '"$1" --key' bash "$authority" 2>"$test_tmp/direct-err"); then
  direct_status=0
else
  direct_status=$?
fi
if overridden=$(OMARCHY_DEVICE_TREE_COMPATIBLE="$fixture" "$parser_bash" -c '"$1" --key' bash "$authority" 2>"$test_tmp/override-err"); then
  override_status=0
else
  override_status=$?
fi
[[ $direct_status == "$override_status" ]] || fail "executable ignores source environment override"
cmp -s "$test_tmp/direct-err" "$test_tmp/override-err" || fail "executable uses only hardcoded source"
[[ $direct == "$overridden" ]] || fail "executable ignores source environment output override"
if "$authority" --key "$fixture" >"$test_tmp/extra-out" 2>"$test_tmp/extra-err"; then
  extra_status=0
else
  extra_status=$?
fi
[[ $extra_status == 2 ]] || fail "executable rejects a source path argument" "expected 2, got $extra_status"
grep -Fq 'usage:' "$test_tmp/extra-err" || fail "extra source argument reports usage"
pass "executable hardcodes default source and rejects overrides"

source_sentinel=$("$parser_bash" -c 'source "$1"; printf sourced' bash "$authority")
[[ $source_sentinel == sourced ]] || fail "authority source guard avoids running main"
pass "authority is sourceable without running main"

stub_bin="$test_tmp/stub-bin"
calls="$test_tmp/calls"
mkdir -p "$stub_bin"
: >"$calls"
for command_name in sudo systemctl pacman mount cryptsetup git makepkg curl install; do
  cat >"$stub_bin/$command_name" <<'SH'
#!/bin/bash
printf '%s\n' "${0##*/}" >>"$TEST_CALLS"
exit 99
SH
done
chmod +x "$stub_bin"/*
set_fixture 'apple,t810x\0'
if PATH="$stub_bin:$PATH" TEST_CALLS="$calls" "$parser_bash" -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" key' bash "$authority" "$fixture" >/dev/null 2>"$stderr_file"; then
  fail "rejected input remains a failure with privileged stubs"
fi
[[ ! -s $calls ]] || fail "identity parser invokes no privileged commands" "$(cat "$calls")"
pass "rejected input invokes no privileged commands"

set_fixture 'apple,t8103\0'
mutant="$test_tmp/mutant"
cp "$authority" "$mutant"
sed -i.bak 's/apple,t8103) OMARCHY_APPLE_SILICON_KEY="m1"/apple,t8103) OMARCHY_APPLE_SILICON_KEY="unknown"/' "$mutant"
if "$parser_bash" -c 'source "$1"; omarchy_apple_silicon_generation_parse "$2" key' bash "$mutant" "$fixture" >"$test_tmp/mutant-out" 2>"$stderr_file"; then
  fail "mapping mutation is detected by runtime fixture"
fi
[[ ! -s $test_tmp/mutant-out ]] || fail "mapping mutation does not produce the expected key"
pass "runtime mapping mutation fails the focused proof"

metadata_bash=$(command -v bash)
if [[ -x /opt/homebrew/bin/bash ]]; then
  metadata_bash=/opt/homebrew/bin/bash
fi
if command -v jq >/dev/null && "$metadata_bash" -c '((BASH_VERSINFO[0] >= 4))'; then
  metadata=$($metadata_bash "$ROOT/bin/omarchy" commands --all --json)
  jq -e --arg binary omarchy-hw-apple-silicon-generation 'any(.commands[]; .binary == $binary and .hidden == true and (.summary | length > 0))' <<<"$metadata" >/dev/null ||
    fail "metadata router exposes hidden generation authority"
  pass "metadata router exposes hidden generation authority"
else
  pass "metadata router check deferred on Bash without associative arrays or jq"
fi
