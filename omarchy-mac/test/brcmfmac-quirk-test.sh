#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# omarchy-mac-setup-system takes the Intel Mac Broadcom quirk out of
# /etc/modprobe.d/brcmfmac.conf wherever an unguarded runtime migration put it.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/omarchy-hw-platform" <<'STUB'
#!/bin/bash
echo "${PLATFORM:-apple-silicon}"
STUB
cat >"$work/bin/lspci" <<'STUB'
#!/bin/bash
echo "Broadcom [14e4:4433]"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
stage=$work/root
"$ROOT/install" "$stage"
setup=$stage/usr/bin/omarchy-mac-setup-system
conf=$stage/etc/modprobe.d/brcmfmac.conf
pending=$stage/var/lib/omarchy/migrations/1789172112-initramfs-pending
mkdir -p "${conf%/*}"
block="# Broadcom's firmware supplicant and authenticator fail the WPA four-way
# handshake on Apple hardware, which surfaces as a rejected password. Disable
# both so wpa_supplicant performs the handshake instead.
options brcmfmac feature_disable=0x82000"

reset() { rm -rf "$conf" "$pending" "${conf%/*}"/.brcmfmac.conf.*; }
setup() { "$setup" "$stage" >"$work/out" 2>"$work/err"; }

reset
setup
[[ ! -e $conf && ! -e $pending ]] || fail 'no file, nothing to do'

# What 1786391100 wrote on a Mac without the file: a blank line and the block.
printf '\n%s\n' "$block" >"$conf"
setup
[[ ! -e $conf && -f $pending ]] || fail 'a file holding only the quirk goes, with the rebuild recorded'
grep -q 'Removed the Intel Mac Broadcom quirk' "$work/out" || fail 'the removal is reported'

# Appended after the owner's own options, with more of theirs after it.
reset
printf 'options brcmfmac roamoff=1\n# keep me\n\n%s\noptions brcmfmac p2pon=1\n' "$block" >"$conf"
chmod 600 "$conf"
setup
[[ $(<"$conf") == $'options brcmfmac roamoff=1\n# keep me\noptions brcmfmac p2pon=1' ]] ||
  fail 'only the quirk, its comment block and blank line go' "$(cat "$conf")"
[[ $(stat -c %a "$conf") == 600 && -f $pending ]] || fail 'the kept file keeps its mode'
[[ -z $(find "${conf%/*}" -name '.brcmfmac.conf.*') ]] || fail 'no temporary file is left'

# The bare line, and comments the owner changed, which stay.
reset
printf '# my note\noptions brcmfmac feature_disable=0x82000\n' >"$conf"
setup
[[ $(<"$conf") == '# my note' ]] || fail 'a bare quirk line goes and the owner comment stays'
reset
printf '# Broadcom quirk, mine\noptions brcmfmac feature_disable=0x82000\n\n\n' >"$conf"
setup
[[ $(<"$conf") == '# Broadcom quirk, mine' ]] || fail 'an edited comment is the owner line'
reset
printf '%s\n' "${block%options*}" | sed '/^$/d' >"$conf"
printf 'options brcmfmac feature_disable=0x82000\n' >>"$conf"
printf '\n\n' >>"$conf"
setup
[[ ! -e $conf ]] || fail 'a file left with only blank lines goes'
pass 'the quirk line goes wherever it is, with only what the migration wrote around it'

# Anything that is not exactly the line stays, and nothing is recorded.
for line in '#options brcmfmac feature_disable=0x82000' 'options brcmfmac feature_disable=0x82000 roamoff=1' \
  '  options brcmfmac feature_disable=0x82000' 'options brcmfmac feature_disable=0x2000'; do
  reset
  printf '%s\n' "$line" >"$conf"
  cp "$conf" "$work/expected"
  setup
  cmp -s "$conf" "$work/expected" && [[ ! -e $pending ]] || fail "not the exact line: $line"
done
reset
printf '\n%s\n' "$block" >"$conf"
PLATFORM=generic setup
[[ -f $conf && ! -e $pending ]] || fail 'a machine that is not a Mac is untouched'
reset
printf '\n%s\n' "$block" >"$work/target"
ln -s "$work/target" "$conf"
setup
[[ -L $conf && $(<"$work/target") == $'\n'"$block" && ! -e $pending ]] || fail 'a link and its target are left alone'
grep -q 'it is a link' "$work/err" || fail 'a link gets the manual fix'
pass 'other lines, other machines and links are left alone'
