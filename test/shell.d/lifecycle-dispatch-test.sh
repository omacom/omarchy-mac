#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dispatch="$ROOT/bin/omarchy-lifecycle-dispatch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

operations=(provision-prepare provision-commit provision-verify reset-prepare reset-verify reset-commit reset-rollback update-preflight update-verify boot-rebuild luks-slots)
apple_optional=(update-preflight boot-rebuild)

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$tmp/$platform" "$platform"
done
mkdir -p "$tmp/contradiction/proc/device-tree"
printf '%s\0' apple,j416c qcom,x1e80100 >"$tmp/contradiction/proc/device-tree/compatible"
cp -r "$tmp/apple-silicon/bin" "$tmp/contradiction/bin"

# A root-owned directory of entrypoints stands in for the boot package; in a
# fixture root the caller's own files count as root's.
implementation=usr/lib/omarchy/mac-boot
install_implementation() {
  local root=$1 operation
  rm -rf "$root"
  mkdir -p "$root/$implementation"
  for operation in "${operations[@]}"; do
    cat >"$root/$implementation/$operation" <<SH
#!/bin/bash
{ printf '%s' "$operation"; printf ' %q' "\$@"; echo; } >>"$tmp/ran"
env >"$tmp/env"
[[ ! -e $tmp/fail-with ]] || exit "\$(cat "$tmp/fail-with")"
SH
    chmod 755 "$root/$implementation/$operation"
  done
  chmod -R go-w "$root"
}

# Runs the dispatcher on a platform fixture: $1 platform, $2 lifecycle root.
on() {
  local platform=$1 root=$2
  shift 2
  OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_LIFECYCLE_ROOT="$root" PATH="$tmp/$platform/bin:$PATH" \
    "$dispatch" "$@"
}

# -p in the shebang is what keeps a root caller's exported functions and
# BASH_ENV out, so an ordinary Bash launch with a decoy -p argument is refused
# before it resolves anything.
status=0
output=$(/usr/bin/bash "$dispatch" -p 2>&1) || status=$?
(( status == 126 )) && [[ $output == "Refusing an unsafe Bash startup." ]] ||
  fail "an ordinary Bash launch with a decoy -p is refused" "status $status: $output"
pass "an ordinary Bash launch with a decoy -p is refused"

require_platform_fixtures "lifecycle dispatch on platform fixtures"

full=$tmp/full
install_implementation "$full"
empty=$tmp/empty
mkdir -p "$empty"

# x86, generic aarch64 and Qualcomm register no boot package: every operation
# is a no-op there, even with Mac entrypoints on disk that would fail.
echo 9 >"$tmp/fail-with"
for platform in generic generic-aarch64 qualcomm; do
  for operation in "${operations[@]}"; do
    rm -f "$tmp/ran"
    output=$(on "$platform" "$full" "$operation" --flag 2>&1) || fail "$platform: $operation is a no-op" "$output"
    [[ -z $output && ! -e $tmp/ran ]] || fail "$platform: $operation runs nothing and says nothing" "$output"
    output=$(on "$platform" "$full" --resolve "$operation" 2>&1) || fail "$platform: $operation resolves" "$output"
    [[ -z $output ]] || fail "$platform: $operation resolves to nothing" "$output"
  done
  pass "$platform: every operation is a no-op and no Mac entrypoint runs"
done
rm -f "$tmp/fail-with"

# Apple with omarchy-mac-boot: each operation runs its entrypoint with the
# caller's arguments, a cleared environment and a fixed PATH.
export CALLER_SECRET=leak
for operation in "${operations[@]}"; do
  rm -f "$tmp/ran"
  on apple-silicon "$full" "$operation" first "second arg" || fail "apple: $operation runs its entrypoint"
  [[ $(cat "$tmp/ran") == "$operation first second\\ arg" ]] || fail "apple: $operation passes its arguments" "$(cat "$tmp/ran")"
  ! grep -q CALLER_SECRET "$tmp/env" || fail "apple: $operation does not pass the caller's environment" "$(cat "$tmp/env")"
  grep -qx 'PATH=/usr/local/sbin:/usr/local/bin:/usr/bin' "$tmp/env" || fail "apple: $operation runs with a fixed PATH" "$(cat "$tmp/env")"
  resolved=$(on apple-silicon "$full" --resolve "$operation") || fail "apple: $operation resolves"
  [[ $resolved == "$full/$implementation/$operation" ]] || fail "apple: $operation resolves to its entrypoint" "$resolved"
done
unset CALLER_SECRET
echo 7 >"$tmp/fail-with"
status=0
on apple-silicon "$full" provision-commit || status=$?
(( status == 7 )) || fail "apple: the entrypoint's exit status is the dispatcher's" "status: $status"
rm -f "$tmp/fail-with"
pass "apple: each operation runs the boot package's entrypoint with its arguments and status"

# Apple without omarchy-mac-boot: required operations fail naming the package
# and entrypoint; optional ones are no-ops.
for operation in "${operations[@]}"; do
  status=0
  output=$(on apple-silicon "$empty" "$operation" 2>&1) || status=$?
  if [[ " ${apple_optional[*]} " == *" $operation "* ]]; then
    (( status == 0 )) && [[ -z $output ]] || fail "apple: optional $operation is a no-op without the boot package" "$output"
    output=$(on apple-silicon "$empty" --resolve "$operation" 2>&1) && [[ -z $output ]] ||
      fail "apple: optional $operation resolves to nothing without the boot package" "$output"
  else
    (( status == 3 )) || fail "apple: required $operation fails with status 3 without the boot package" "status: $status"
    [[ $output == "Error: $operation on apple-silicon needs omarchy-mac-boot, which provides /usr/lib/omarchy/mac-boot/$operation; it is not installed" ]] ||
      fail "apple: required $operation names the missing package and entrypoint" "$output"
    status=0
    on apple-silicon "$empty" --resolve "$operation" >/dev/null 2>&1 || status=$?
    (( status == 3 )) || fail "apple: required $operation does not resolve without the boot package" "status: $status"
  fi
done
pass "apple: without omarchy-mac-boot required operations fail with a clear message and optional ones are no-ops"

# An installed omarchy-mac-boot that predates an operation is named with its
# version, as an update away rather than missing.
older=$tmp/older
mkdir -p "$older/usr/lib/omarchy/mac-boot" "$older/var/lib/pacman/local/omarchy-mac-boot-20260921-10"
for operation in "${operations[@]}"; do
  [[ " ${apple_optional[*]} " == *" $operation "* ]] && continue
  status=0
  output=$(on apple-silicon "$older" "$operation" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == "Error: $operation on apple-silicon needs /usr/lib/omarchy/mac-boot/$operation, which omarchy-mac-boot 20260921-10 does not provide; update omarchy-mac-boot" ]] ||
    fail "apple: an omarchy-mac-boot without $operation is named with its version" "status $status: $output"
done
pass "apple: an installed omarchy-mac-boot that lacks a required operation fails asking for its update"

# An entrypoint anyone but root could have changed never runs, optional or not.
untrusted() {
  local description=$1 operation=$2
  rm -f "$tmp/ran"
  if output=$(on apple-silicon "$full" "$operation" 2>&1); then
    fail "apple: $description is refused"
  fi
  [[ ! -e $tmp/ran ]] || fail "apple: $description never runs"
  [[ $output == *"refusing /usr/lib/omarchy/mac-boot/$operation"* ]] || fail "apple: $description is named" "$output"
  if on apple-silicon "$full" --resolve "$operation" >/dev/null 2>&1; then
    fail "apple: $description does not resolve"
  fi
}

install_implementation "$full"
chmod g+w "$full/$implementation/update-preflight"
untrusted "a group-writable optional entrypoint" update-preflight

install_implementation "$full"
chmod o+w "$full/$implementation/provision-commit"
untrusted "a world-writable entrypoint" provision-commit

install_implementation "$full"
chmod o+w "$full/usr/lib/omarchy"
untrusted "an entrypoint in a world-writable directory" provision-verify

install_implementation "$full"
mv "$full/$implementation/provision-prepare" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$full/$implementation/provision-prepare"
untrusted "a symlinked entrypoint" provision-prepare

install_implementation "$full"
chmod 644 "$full/$implementation/boot-rebuild"
untrusted "a non-executable entrypoint" boot-rebuild

install_implementation "$full"
rm "$full/$implementation/reset-verify"
mkdir "$full/$implementation/reset-verify"
chmod 755 "$full/$implementation/reset-verify"
untrusted "a directory in place of an entrypoint" reset-verify
pass "apple: an entrypoint that is not a root-owned file in root-owned directories never runs"

install_implementation "$full"
for arguments in "" "unknown-operation" "--resolve" "--resolve unknown-operation"; do
  rm -f "$tmp/ran"
  status=0
  output=$(on apple-silicon "$full" $arguments 2>&1) || status=$?
  (( status == 2 )) && [[ $output == Usage:* ]] || fail "'$arguments' is a usage error" "status $status: $output"
  [[ ! -e $tmp/ran ]] || fail "'$arguments' runs nothing"
done
status=0
output=$(on apple-silicon "$full" "provision-prepare provision-commit" 2>&1) || status=$?
(( status == 2 )) && [[ ! -e $tmp/ran ]] || fail "two operation names in one argument are a usage error" "status $status: $output"
pass "an operation outside the fixed set is a usage error"

rm -f "$tmp/ran"
if output=$(on contradiction "$full" provision-commit 2>&1); then
  fail "a platform the detector cannot settle fails the operation"
fi
[[ ! -e $tmp/ran && $output == *"cannot determine the hardware platform for provision-commit"* ]] ||
  fail "an undetermined platform runs nothing and says why" "$output"
pass "an undetermined platform fails closed"

rm -f "$tmp/ran"
if output=$(cd "$tmp" && on apple-silicon full provision-commit 2>&1); then
  fail "a relative fixture root is refused"
fi
[[ ! -e $tmp/ran && $output == "Error: OMARCHY_LIFECYCLE_ROOT must be an absolute path" ]] ||
  fail "a relative fixture root runs nothing and says why" "$output"
pass "a relative fixture root is refused"

# Root resolves only the fixed /usr/lib path, whatever fixture root its
# environment names. A copy beside a detector that always answers Apple keeps
# the live platform out of the way.
if unshare --user --map-root-user true 2>/dev/null; then
  mkdir -p "$tmp/rootbin"
  cp "$dispatch" "$tmp/rootbin/"
  printf '#!/bin/bash\necho apple-silicon\n' >"$tmp/rootbin/omarchy-hw-platform"
  chmod +x "$tmp/rootbin/omarchy-hw-platform"
  rm -f "$tmp/ran"
  status=0
  output=$(OMARCHY_LIFECYCLE_ROOT="$full" unshare --user --map-root-user "$tmp/rootbin/omarchy-lifecycle-dispatch" reset-prepare 2>&1) ||
    status=$?
  (( status != 0 )) && [[ ! -e $tmp/ran && $output != *"$tmp"* && $output == *" /usr/lib/omarchy/mac-boot/reset-prepare"* ]] ||
    fail "root ignores a fixture root in its environment" "status $status: $output"
  pass "root ignores fixture roots when resolving an operation"

  printf 'touch %q\n' "$tmp/bash-env-ran" >"$tmp/bash-env"
  dirname() { touch "$tmp/function-ran"; echo /nonexistent; }
  export -f dirname
  BASH_ENV="$tmp/bash-env" unshare --user --map-root-user "$dispatch" --resolve provision-commit >/dev/null 2>&1 || true
  unset -f dirname
  [[ ! -e $tmp/bash-env-ran && ! -e $tmp/function-ran ]] || fail "root runs no code from BASH_ENV or exported functions"
  pass "root runs no code from BASH_ENV or exported functions"
else
  skip "no unprivileged user namespace; skipping the root override probe"
fi
