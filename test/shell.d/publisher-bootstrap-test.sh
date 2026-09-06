#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/download" "$work/bin" "$work/home" "$work/source/default/pacman/aarch64" "$work/empty-archives"
cp "$ROOT/bin/omarchy-pkg-publish-aarch64" "$work/download/publisher"
cat >"$work/source/default/pacman/aarch64/pacman-stable.conf" <<'CONF'
[omarchy-aarch64]
Server = https://github.com/fixture/packages/releases/download/test
CONF
for command in dirname grep sed head find sort; do
  ln -s "$(command -v "$command")" "$work/bin/$command"
done
cat >"$work/bin/uname" <<'SH'
#!/bin/bash
printf 'uname\n' >>"$TEST_UNAME_LOG"
printf '%s\n' "$TEST_ARCH"
exit "${TEST_ARCH_STATUS:-0}"
SH
chmod +x "$work/bin/uname"
export TEST_UNAME_LOG="$work/uname.log"

# Execute the actual downloaded file with no Omarchy commands, package tools,
# network clients or publisher available. A build must stop at missing makepkg.
for arch in aarch64 arm64; do
  status=0
  HOME="$work/home" OMARCHY_PATH="$work/source" TEST_ARCH="$arch" PATH="$work/bin" \
    /bin/bash "$work/download/publisher" >"$work/output" 2>&1 || status=$?
  (( status != 0 )) && grep -q 'makepkg is required' "$work/output" ||
    fail "downloaded publisher passes its $arch guard without installed helpers" "$(cat "$work/output")"
done
for scenario in unknown failed; do
  arch=unknown
  uname_status=0
  [[ $scenario != failed ]] || { arch=aarch64; uname_status=1; }
  status=0
  HOME="$work/home" OMARCHY_PATH="$work/source" TEST_ARCH="$arch" TEST_ARCH_STATUS="$uname_status" PATH="$work/bin" \
    /bin/bash "$work/download/publisher" >"$work/output" 2>&1 || status=$?
  (( status != 0 )) || fail "downloaded publisher rejects $scenario architecture"
  ! grep -q 'makepkg is required' "$work/output" || fail "$scenario detection cannot reach the build prerequisite"
done
pass "single-file publisher bootstraps supported ARM aliases and rejects unknown or failed detection"

rm "$TEST_UNAME_LOG"
status=0
HOME="$work/home" OMARCHY_PATH="$work/source" TEST_ARCH=unknown TEST_ARCH_STATUS=1 PATH="$work/bin" \
  /bin/bash "$work/download/publisher" --from "$work/empty-archives" >"$work/output" 2>&1 || status=$?
(( status != 0 )) && grep -q 'no packages in' "$work/output" || fail "prebuilt mode reaches only its empty fixture directory"
[[ ! -e $TEST_UNAME_LOG ]] || fail "prebuilt mode remains architecture-independent"
pass "--from mode does not run architecture detection; no package build or publication is attempted"
