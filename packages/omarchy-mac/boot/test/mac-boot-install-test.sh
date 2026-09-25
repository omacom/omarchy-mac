#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# install DESTDIR stages the whole omarchy-mac-boot package from this source:
# commands, sourced modules and the initramfs/first-boot payload in files/.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage=$tmp/stage

if bash "$ROOT/install" relative 2>/dev/null; then fail "a relative staging directory is refused"; fi
if bash "$ROOT/install" / 2>/dev/null; then fail "the live root is refused"; fi
bash "$ROOT/install" "$stage"
pass "install stages into an absolute directory only"

while IFS= read -r -d '' file; do
  path=${file#"$ROOT/files/"}
  staged=$stage/$path
  if [[ -L $file ]]; then
    [[ -L $staged && $(readlink "$staged") == "$(readlink "$file")" ]] || fail "$path stays a symlink to $(readlink "$file")"
    continue
  fi
  cmp -s "$file" "$staged" || fail "$path is staged byte for byte"
  mode=644
  [[ -x $file ]] && mode=755
  [[ $(stat -c %a "$staged") == "$mode" ]] || fail "$path is staged with mode $mode"
done < <(find "$ROOT/files" \( -type f -o -type l \) -print0)
[[ ! -e $stage/boot ]] || fail "staging writes nothing to the boot partition"
cmp -s "$ROOT/LICENSE" "$stage/usr/share/licenses/omarchy-mac-boot/LICENSE" || fail "the license is staged"
for file in "$ROOT"/bin/*; do
  [[ -x $stage/usr/bin/${file##*/} ]] || fail "${file##*/} is staged as a command"
done
pass "every payload file keeps its installed path, content and mode"

# Every shipped mkinitcpio drop-in rebuilds the initramfs when it changes.
hook=$ROOT/files/usr/share/libalpm/hooks/91-omarchy-mac-boot-initramfs.hook
for dropin in "$ROOT"/files/etc/mkinitcpio.conf.d/*.conf; do
  grep -Fxq "Target = etc/mkinitcpio.conf.d/${dropin##*/}" "$hook" || fail "the ALPM hook matches ${dropin##*/}"
done
pass "the ALPM hook rebuilds the initramfs for every shipped drop-in"
