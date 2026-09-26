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
export OMARCHY_PROVISION_OWNER_SOURCE=1
grep -Fxq omarchy-mac-boot "$ROOT/install/omarchy-apple.packages" || fail "Apple fresh-install inputs carry the boot package"
pass "Apple installs carry the boot package their lifecycles dispatch to"
bash "$ROOT/packages/omarchy-mac/boot/install" "$work/stage"
bash -c 'source "$1"' _ "$ROOT/bin/omarchy-provision-owner"
# Factory reset is upstream's script, which elevates when run: it only parses.
bash -n "$ROOT/bin/omarchy-system-factory-reset"
pass "Apple lifecycles load the separately staged package"

# Owner provisioning and factory reset reach the Mac's boot chain only through
# omarchy-lifecycle-dispatch; the boot package owns the files below.
# Factory reset has no Apple step of its own left either, the Mac's first-boot
# state included.
patterns=(/boot/omarchy encrypt.state rd.luks.key /etc/default/grub omarchy-mac-boot omarchy-mac/boot update-grub)
for entry in omarchy-provision-owner omarchy-system-factory-reset; do
  [[ $entry != omarchy-system-factory-reset ]] || patterns+=(omarchy-hw-apple-silicon mac-first-boot efi/omarchy)
  for pattern in "${patterns[@]}"; do
    ! grep -Fq -- "$pattern" "$ROOT/bin/$entry" ||
      fail "$entry leaves $pattern to the boot package" "$(grep -Fn -- "$pattern" "$ROOT/bin/$entry")"
  done
done
for operation in provision-prepare provision-commit provision-verify reset-prepare reset-verify reset-commit reset-rollback luks-slots; do
  [[ -x $work/stage/usr/lib/omarchy/mac-boot/$operation ]] || fail "omarchy-mac-boot ships $operation"
done
pass "owner provisioning and factory reset handle Apple boot files only through the boot package's dispatch entrypoints"
[[ ! -e $work/stage/boot ]] || fail "staging does not change boot files"
while IFS= read -r -d '' file; do
  shipped=$ROOT/packages/omarchy-mac/boot/files/${file#"$work/stage/"}
  [[ -e $shipped || -L $shipped ]] || fail "staged ${file#"$work/stage"} is a shipped package file"
done < <(find "$work/stage/etc" \( -type f -o -type l \) -print0)
pass "boot package staging writes only its shipped configuration outside vendor paths"
