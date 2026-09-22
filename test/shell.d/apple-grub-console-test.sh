#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
printf '#!/bin/bash\nexit "${TEST_NOT_APPLE:-0}"\n' >"$test_tmp/bin/omarchy-hw-apple-silicon"
printf '#!/bin/bash\nexit "${TEST_NOT_LIMINE:-1}"\n' >"$test_tmp/bin/omarchy-mac-limine-active"
for name in grub-probe grub-mkconfig; do
  printf '#!/bin/bash\nexit 0\n' >"$test_tmp/bin/$name"
done
for name in update-grub omarchy-mac-boot-update; do
  cat >"$test_tmp/bin/$name" <<'STUB'
#!/bin/bash
echo "${0##*/}" >>"$TEST_CALLS"
exit "${TEST_UPDATE_FAILURE:-0}"
STUB
done
chmod +x "$test_tmp/bin"/*
export PATH="$test_tmp/bin:$PATH" TEST_CALLS="$test_tmp/calls"
export OMARCHY_GRUB_DEFAULT="$test_tmp/grub" OMARCHY_GRUB_CONSOLE_PENDING="$test_tmp/state/pending"
run() { bash -e -c 'source "$1"' _ "$ROOT/install/hardware/apple/grub-console.sh"; }
cat >"$test_tmp/grub" <<'CONF'
GRUB_VIDEO_BACKEND="obsolete"
GRUB_CMDLINE_LINUX="ignored"
#GRUB_VIDEO_BACKEND="unused"
GRUB_VIDEO_BACKEND="old"
GRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_FONT="/keep/font.pf2"
CONF
cp "$test_tmp/grub" "$test_tmp/original"
TEST_NOT_APPLE=1 run
OMARCHY_MAC_IMAGE_BUILD=1 run
cmp -s "$test_tmp/grub" "$test_tmp/original" || fail "non-Apple and deferred image paths are untouched"
[[ ! -e $TEST_CALLS ]] || fail "deferred runs do not update boot files"
pass "non-Apple and image preparation remain unchanged"

if TEST_UPDATE_FAILURE=7 run; then fail "failed regeneration is reported"; fi
[[ -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "failed regeneration remains pending"
grep -Fxq 'GRUB_VIDEO_BACKEND="efi_gop"' "$test_tmp/grub" || fail "GOP backend is pinned"
(( $(grep -c '^GRUB_VIDEO_BACKEND=' "$test_tmp/grub") == 1 )) || fail "duplicate backend assignments are collapsed"
grep -Fxq 'GRUB_CMDLINE_LINUX="rd.luks.uuid=luks-id rootflags=subvol=@ rootflags=x-systemd.device-timeout=0"' "$test_tmp/grub" || fail "last cmdline and encryption options are preserved"
grep -Fxq 'GRUB_FONT="/keep/font.pf2"' "$test_tmp/grub" || fail "visual settings remain untouched"
run
[[ ! -e $OMARCHY_GRUB_CONSOLE_PENDING ]] || fail "successful retry clears pending regeneration"
(( $(wc -l <"$TEST_CALLS") == 2 )) || fail "retry regenerates unchanged defaults"
run
(( $(wc -l <"$TEST_CALLS") == 2 )) || fail "configured defaults are idempotent"
pass "GOP and root wait preserve effective cmdline and retry regeneration"

# Existing Limine installs need their UKI rebuilt from the edited defaults.
sed -i 's/ rootflags=x-systemd.device-timeout=0//' "$test_tmp/grub"
TEST_NOT_LIMINE=0 run
[[ $(tail -n 1 "$TEST_CALLS") == "omarchy-mac-boot-update" ]] || fail "Limine command-line edits rebuild the active UKI"
pass "active Limine uses the coordinated boot updater"

# The same defaults are required by a fresh image with no GRUB installed.
sed -i 's/ rootflags=x-systemd.device-timeout=0//' "$test_tmp/grub"
OMARCHY_GRUB_PROBE=omarchy-test-no-grub run
(( $(wc -l <"$TEST_CALLS") == 3 )) || fail "a fresh no-GRUB image does not regenerate GRUB"
grep -q 'rootflags=x-systemd.device-timeout=0' "$test_tmp/grub" || fail "no-GRUB image still gets the root wait"
pass "fresh no-GRUB images receive shared command-line defaults"
