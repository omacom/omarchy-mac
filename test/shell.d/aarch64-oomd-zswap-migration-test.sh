#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1790593200.sh"
[[ -f $migration ]] || fail "oomd and zswap repair migration exists"
[[ $(stat -c %a "$migration") == 644 ]] || fail "migration is mode 0644, since the runner does not use the executable bit"
[[ $(head -n 1 "$migration") != "#!"* ]] || fail "migration has no shebang; the runner supplies bash -euo pipefail"
pass "oomd and zswap repair migration has the runner's file shape"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
call_log="$test_tmp/calls"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
exec "$@"
SH
cat >"$stub_bin/install" <<'SH'
#!/bin/bash
printf 'install %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
exec /usr/bin/install "$@"
SH
cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
exit 0
SH
cat >"$stub_bin/systemd-tmpfiles" <<'SH'
#!/bin/bash
printf 'systemd-tmpfiles %s\n' "$*" >>"$OMARCHY_TEST_CALL_LOG"
exit 0
SH
chmod +x "$stub_bin"/*

run_migration() {
  : >"$call_log"
  PATH="$stub_bin:/usr/bin:/bin" \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_TEST_CALL_LOG="$call_log" \
    OMARCHY_SETTINGS_RESTORE_ROOT="$1" \
    OMARCHY_ZRAM_ROOT="$1" \
    bash -euo pipefail "$migration"
}

root="$test_tmp/fresh"
run_migration "$root"
oomd_system="$root/etc/systemd/oomd.conf.d/00-omarchy-mac-restore.conf"
oomd_user="$root/usr/lib/systemd/user/app.slice.d/00-omarchy-mac-restore.conf"
zswap="$root/etc/tmpfiles.d/00-omarchy-mac-zswap.conf"
cmp "$ROOT/etc/systemd/oomd.conf.d/10-omarchy.conf" "$oomd_system" || fail "system oomd repair copies the shipped thresholds"
cmp "$ROOT/default/systemd/user/app.slice.d/10-oomd.conf" "$oomd_user" || fail "user oomd repair copies the app.slice kill policy"
[[ ! -e $root/etc/systemd/oomd.conf.d/10-omarchy.conf ]] || fail "repair must not occupy the path a future settings package owns"
[[ ! -e $root/usr/lib/systemd/user/app.slice.d/10-oomd.conf ]] || fail "repair must not occupy the vendor user-unit filename"
[[ ! -e $zswap ]] || fail "zswap stays at the kernel default when this machine has no zram configuration"
[[ $(stat -c %a "$oomd_system") == 644 ]] || fail "restored drop-ins are mode 0644"
grep -F 'systemctl try-restart systemd-oomd.service' "$call_log" >/dev/null || fail "oomd is restarted so it reads the new thresholds" "$(cat "$call_log")"
grep -F 'systemctl --user daemon-reload' "$call_log" >/dev/null || fail "user manager reloads the app.slice drop-in" "$(cat "$call_log")"
grep -F 'omarchy-usb-autosuspend' "$call_log" >/dev/null && fail "USB autosuspend blacklist is not restored" "$(cat "$call_log")"
grep -F 'limine' "$call_log" >/dev/null && fail "Limine configuration is not restored" "$(cat "$call_log")"
pass "machines without zram get the oomd repairs and nothing else"

run_migration "$root"
grep -F 'install ' "$call_log" >/dev/null && fail "a second run must not reinstall existing repairs" "$(cat "$call_log")"
pass "the repair is idempotent"

canonical="$test_tmp/canonical"
mkdir -p "$canonical/etc/systemd/oomd.conf.d" "$canonical/usr/lib/systemd/user/app.slice.d"
printf 'kept\n' >"$canonical/etc/systemd/oomd.conf.d/10-omarchy.conf"
printf 'kept\n' >"$canonical/usr/lib/systemd/user/app.slice.d/10-oomd.conf"
run_migration "$canonical"
[[ ! -e $canonical/etc/systemd/oomd.conf.d/00-omarchy-mac-restore.conf ]] || fail "an existing system oomd drop-in is left alone"
[[ ! -e $canonical/usr/lib/systemd/user/app.slice.d/00-omarchy-mac-restore.conf ]] || fail "an existing vendor app.slice drop-in is left alone"
[[ $(<"$canonical/etc/systemd/oomd.conf.d/10-omarchy.conf") == "kept" ]] || fail "existing oomd configuration was overwritten"
pass "files the package or an administrator already installed are not replaced"

zram_root="$test_tmp/zram"
mkdir -p "$zram_root/etc/systemd"
printf '[zram0]\n' >"$zram_root/etc/systemd/zram-generator.conf"
run_migration "$zram_root"
cmp "$ROOT/etc/tmpfiles.d/omarchy-zswap.conf" "$zram_root/etc/tmpfiles.d/00-omarchy-mac-zswap.conf" || fail "zram machines disable zswap so pages are not compressed twice"
grep -F "systemd-tmpfiles --create $zram_root/etc/tmpfiles.d/00-omarchy-mac-zswap.conf" "$call_log" >/dev/null || fail "zswap disable is applied without waiting for reboot" "$(cat "$call_log")"
[[ ! -e $zram_root/etc/tmpfiles.d/omarchy-zswap.conf ]] || fail "zswap repair must not occupy the package path"
pass "zram machines also disable zswap, beside the package path"
