#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT"/install "$work/root"
mkdir -p "$work/root/etc/systemd/system" "$work/bin"
cp "$ROOT"/legacy/omarchy-wifi-resume-fix.service "$work/root/etc/systemd/system/"
systemctl --root="$work/root" enable omarchy-wifi-resume-fix.service
printf '#!/bin/bash\necho apple-silicon\n' >"$work/bin/omarchy-hw-platform"
printf '#!/bin/bash\necho "14e4:${WIFI_ID:-4433}"\n' >"$work/bin/lspci"
chmod +x "$work/bin/"*
PATH="$work/bin:$PATH" "$work/root/usr/bin/omarchy-mac-setup-system" "$work/root"
for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
  link="$work/root/etc/systemd/system/$target.target.wants/omarchy-wifi-resume-fix.service"
  [[ $(readlink "$link") == /usr/lib/systemd/system/omarchy-wifi-resume-fix.service ]] || fail 'legacy enablement points to vendor unit'
done
pass 'real systemctl upgrade repairs generated enablement links' 

# A fresh BCM4388 Mac gets the vendor unit enabled for every sleep target.
"$ROOT"/install "$work/fresh"
WIFI_ID=4434 PATH="$work/bin:$PATH" "$work/fresh/usr/bin/omarchy-mac-setup-system" "$work/fresh"
for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
  link="$work/fresh/etc/systemd/system/$target.target.wants/omarchy-wifi-resume-fix.service"
  [[ $(readlink "$link") == "/usr/lib/systemd/system/omarchy-wifi-resume-fix.service" ]] || fail 'BCM4388 enables the vendor unit'
done
[[ ! -e $work/fresh/etc/systemd/system/omarchy-wifi-resume-fix.service ]] || fail 'fresh setup writes no /etc unit'
pass 'real systemctl enables recovery on a fresh BCM4388 Mac'
