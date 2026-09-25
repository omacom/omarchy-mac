#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$ROOT"/install "$work/root"
mkdir -p "$work/root/etc/systemd/system" "$work/bin"
cp "$ROOT"/legacy/omarchy-wifi-resume-fix.service "$work/root/etc/systemd/system/"
systemctl --root="$work/root" enable omarchy-wifi-resume-fix.service
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
printf '#!/bin/bash\necho "14e4:4433"\n' >"$work/bin/lspci"
chmod +x "$work/bin/"*
PATH="$work/bin:$PATH" "$work/root/usr/bin/omarchy-mac-setup-system" "$work/root"
for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
  link="$work/root/etc/systemd/system/$target.target.wants/omarchy-wifi-resume-fix.service"
  [[ $(readlink "$link") == /usr/lib/systemd/system/omarchy-wifi-resume-fix.service ]] || fail 'legacy enablement points to vendor unit'
done
pass 'real systemctl upgrade repairs generated enablement links' 

# speakersafetyd is enabled by this package's preset alone, applied once.
root="$work/speakers"
"$ROOT"/install "$root"
setup="$root/usr/bin/omarchy-mac-setup-system"
wants="$root/etc/systemd/system/multi-user.target.wants/speakersafetyd.service"
marker="$root/var/lib/omarchy-mac/speaker-safety-configured"
mkdir -p "$root/usr/lib/systemd/system"
# Arch disables every unit no preset names.
echo 'disable *' >"$root/usr/lib/systemd/system-preset/99-default.preset"
speakers() { PATH="$work/bin:$PATH" "$setup" "$root" >/dev/null 2>&1; }
speakers
[[ ! -e $wants && ! -e $marker ]] || fail 'setup waits for speakersafetyd to be installed'
printf '[Service]\nExecStart=/usr/bin/speakersafetyd\n[Install]\nWantedBy=multi-user.target\n' >"$root/usr/lib/systemd/system/speakersafetyd.service"
speakers
[[ $(readlink "$wants") == /usr/lib/systemd/system/speakersafetyd.service && -f $marker ]] || fail 'the package preset enables speakersafetyd'
systemctl --root="$root" disable speakersafetyd.service >/dev/null 2>&1
speakers
[[ ! -e $wants ]] || fail 'an explicit disable after setup survives'
pass 'the package preset enables speakersafetyd once it is installed, and disables survive'

rm "$marker"
ln -s /dev/null "$root/etc/systemd/system/speakersafetyd.service"
speakers || fail 'a masked speakersafetyd does not fail setup'
[[ $(readlink "$root/etc/systemd/system/speakersafetyd.service") == /dev/null && ! -e $wants && ! -e $marker ]] ||
  fail 'a masked speakersafetyd stays masked'
rm "$root/etc/systemd/system/speakersafetyd.service"
mkdir -p "$root/etc/systemd/system-preset"
echo 'disable speakersafetyd.service' >"$root/etc/systemd/system-preset/10-local.preset"
speakers
[[ ! -e $wants ]] || fail 'an administrator preset outranks the package preset'
pass 'masks and administrator presets keep speakersafetyd disabled'
