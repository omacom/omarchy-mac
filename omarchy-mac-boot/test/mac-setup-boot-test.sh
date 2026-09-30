#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# setup-boot, omarchy-lifecycle-dispatch's boot setup operation: the GRUB
# console leaf, then the Limine leaf, from the staged package, with the rebuild
# request only on an image's first boot.
(( EUID != 0 )) || { pass 'fixture roots are ignored as root; behaviour cases skipped'; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
"$ROOT/install" "$root"
entry=$root/usr/lib/omarchy/mac-boot/setup-boot
[[ -x $entry && $(stat -c %a "$entry") == 755 ]] || fail 'the setup-boot entrypoint is staged for omarchy-lifecycle-dispatch'
for leaf in grub-console limine-boot; do
  cat >"$root/usr/lib/omarchy-mac/boot/setup/$leaf.sh" <<SH
echo "$leaf rebuild=\${OMARCHY_IMAGE_BOOT_REBUILD:-none}" >>"$work/ran"
[[ ! -e $work/$leaf-fail ]] || return 1
SH
done
run() { rm -f "$work/ran"; OMARCHY_MAC_BOOT_ROOT=$root "$entry" "$@"; }

run
[[ $(<"$work/ran") == $'grub-console rebuild=none\nlimine-boot rebuild=none' ]] || fail 'the console leaf runs, then the Limine leaf' "$(cat "$work/ran")"
run image-first-boot
[[ $(<"$work/ran") == $'grub-console rebuild='"$root"$'/var/lib/omarchy/image/boot-rebuild\nlimine-boot rebuild='"$root"'/var/lib/omarchy/image/boot-rebuild' ]] ||
  fail "an image's first boot asks for the deferred rebuild" "$(cat "$work/ran")"
pass 'setup-boot runs the console leaf, then the Limine leaf, asking for the rebuild on an image first boot'

touch "$work/grub-console-fail"
if run 2>/dev/null; then fail 'a failed console leaf fails setup-boot'; fi
[[ $(<"$work/ran") == 'grub-console rebuild=none' ]] || fail 'the Limine leaf does not run after the console leaf failed'
rm "$work/grub-console-fail"
touch "$work/limine-boot-fail"
if run 2>/dev/null; then fail 'a failed Limine leaf fails setup-boot'; fi
rm "$work/limine-boot-fail"
for arguments in first-boot 'image-first-boot extra'; do
  status=0
  # shellcheck disable=SC2086
  run $arguments 2>/dev/null || status=$?
  (( status == 2 )) || fail "setup-boot refuses '$arguments'"
done
pass 'a failed leaf fails setup-boot, and it takes only image-first-boot'
