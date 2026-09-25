#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/runtime/install/provisioning" "$work/bin" "$work/stage"
cp "$ROOT/install/provisioning/luks-rekey.sh" "$ROOT/install/provisioning/luks-recovery.sh" "$work/runtime/install/provisioning/"
printf 'Omarchy\n' >"$work/runtime/logo.txt"
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/omarchy-hw-apple-silicon"
export PATH="$work/bin:$PATH" OMARCHY_PATH="$work/runtime"
export OMARCHY_PROVISION_OWNER_SOURCE=1 OMARCHY_FACTORY_RESET_SOURCE=1
export OMARCHY_MAC_BOOT_LIB="$work/stage/usr/lib/omarchy-mac/boot"
for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  if bash -c 'source "$1"' _ "$ROOT/bin/$entry" 2>"$work/error"; then
    fail "$entry must refuse missing required boot support"
  fi
  grep -q 'Required omarchy-mac-boot' "$work/error" || fail "missing package is diagnosed"
done
grep -Fxq omarchy-mac-boot "$ROOT/install/omarchy-apple.packages" || fail "Apple fresh-install inputs carry the boot package"
pass "Apple lifecycles fail closed without their boot package, which Apple installs carry"
bash "$ROOT/packages/omarchy-mac/boot/install" "$work/stage"
for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  bash -c 'source "$1"' _ "$ROOT/bin/$entry"
done
pass "Apple lifecycles load the separately staged package"
[[ ! -e $work/stage/boot ]] || fail "staging does not change boot files"
while IFS= read -r -d '' file; do
  [[ -e $ROOT/packages/omarchy-mac/boot/files/${file#"$work/stage/"} ]] || fail "staged ${file#"$work/stage"} is a shipped package file"
done < <(find "$work/stage/etc" \( -type f -o -type l \) -print0)
pass "boot package staging writes only its shipped configuration outside vendor paths"
