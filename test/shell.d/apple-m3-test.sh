#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

installer="$ROOT/bin/omarchy-mac-asahi-install"
all="$ROOT/install/hardware/all.sh"
vulkan="$ROOT/install/hardware/vulkan.sh"
envs="$ROOT/default/hypr/envs.lua"
apple_lua="$ROOT/default/hypr/apple.lua"
uwsm_env="$ROOT/default/uwsm/env.d/10-omarchy"
pkgbuild="$ROOT/pkgbuilds/linux-asahi-wip/PKGBUILD"
kernel_wip="$ROOT/bin/omarchy-mac-kernel-wip"

grep -q 'apple/m3.sh' "$all" || fail "the M3 leaf runs during hardware setup"
pass "the M3 leaf runs during hardware setup"

grep -q 'omarchy-hw-apple-soc --gpu' "$vulkan" || fail "vulkan-asahi is gated on a bound GPU driver"
pass "vulkan-asahi is gated on a bound GPU driver"
! grep -q 'grep -qi "apple" /proc/device-tree/compatible' "$vulkan" ||
  fail "vulkan.sh no longer keys vulkan-asahi off the device tree alone"
pass "vulkan.sh no longer keys vulkan-asahi off the device tree alone"

grep -q 'require("default.hypr.apple")' "$envs" || fail "envs.lua loads the Apple session settings"
pass "envs.lua loads the Apple session settings"
grep -q 'AQ_NO_MODIFIERS' "$uwsm_env" || fail "UWSM sets AQ_NO_MODIFIERS before Hyprland starts"
pass "UWSM sets AQ_NO_MODIFIERS before Hyprland starts"
! grep -q 'hl.env("AQ_NO_MODIFIERS"' "$apple_lua" || fail "apple.lua does not set AQ_NO_MODIFIERS after Aquamarine init"
pass "apple.lua does not set AQ_NO_MODIFIERS after Aquamarine init"
grep -q -- '--gpu' "$apple_lua" || fail "apple.lua asks whether the GPU driver is bound"
pass "apple.lua asks whether the GPU driver is bound"
grep -q 'no_hardware_cursors' "$apple_lua" || fail "apple.lua still sets software-rendering Hyprland config"
pass "apple.lua still sets software-rendering Hyprland config"
grep -q -- '--rollback-boot' "$kernel_wip" || fail "the WIP kernel command can restore boot.bin"
pass "the WIP kernel command can restore boot.bin"
grep -q 'boot.bin.old' "$kernel_wip" || fail "the WIP kernel command documents boot.bin.old recovery"
pass "the WIP kernel command documents boot.bin.old recovery"

bash -n "$pkgbuild" || fail "the linux-asahi-wip PKGBUILD parses"
pass "the linux-asahi-wip PKGBUILD parses"
grep -q 'OMARCHY_KERNEL_BRANCH' "$pkgbuild" || fail "the kernel branch is a build-time choice"
pass "the kernel branch is a build-time choice"
! grep -q '^conflicts=' "$pkgbuild" || fail "linux-asahi-wip installs alongside linux-asahi"
pass "linux-asahi-wip installs alongside linux-asahi"

# The macOS installer wrapper: bash 3.2 syntax; on an M3 it swaps in Asahi's
# own installer package when Asahi Alarm's has no M3 device table, turns on
# the expert-mode question, and adds 14.8.3 to the installer data wherever it
# is missing.
bash -n "$installer" || fail "omarchy-mac-asahi-install parses"
pass "omarchy-mac-asahi-install parses"
! grep -qE '\$\{[a-z_]+,,\}|declare -A' "$installer" ||
  fail "omarchy-mac-asahi-install stays within macOS bash 3.2"
pass "omarchy-mac-asahi-install stays within macOS bash 3.2"
grep -q 'cdn.asahilinux.org/installer' "$installer" ||
  fail "omarchy-mac-asahi-install can fall back to Asahi's own installer package"
pass "omarchy-mac-asahi-install can fall back to Asahi's own installer package"
grep -q 'export EXPERT=1' "$installer" ||
  fail "omarchy-mac-asahi-install turns on the expert-mode question for an M3"
pass "omarchy-mac-asahi-install turns on the expert-mode question for an M3"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck source=/dev/null
source "$installer"

mkdir -p "$test_tmp/old" "$test_tmp/new"
printf '    0x6022: "13.4",     # T6022, M2 Ultra\n    "j180dap":  Device("13.4", False),\n' >"$test_tmp/old/main.py"
printf '    0x6030: "14.8.3",   # T6030, M3 Pro\n    "j516sap":  Device("14.8.3", True),\n' >"$test_tmp/new/main.py"
! installer_knows_m3 "$test_tmp/old" || fail "an installer whose device table ends at M2 is recognised as such"
pass "an installer whose device table ends at M2 is recognised as such"
installer_knows_m3 "$test_tmp/new" || fail "an installer with the M3 device table is recognised"
pass "an installer with the M3 device table is recognised"

cat >"$test_tmp/data.json" <<'JSON'
{
    "os_list": [
        {
            "name": "Asahi Alarm Minimal (BTRFS)",
            "supported_fw": [
                "12.3",
                "12.3.1",
                "13.5"
            ],
            "package": "https://asahi-alarm.org/asahi-base-btrfs.zip"
        },
        {
            "name": "one line",
            "supported_fw": ["13.5"]
        },
        {
            "name": "already there",
            "supported_fw": ["13.5", "14.8.3"]
        },
        {
            "name": "empty",
            "supported_fw": []
        },
        {
            "name": "Tethered boot (m1n1, for development)",
            "supported_fw": null
        }
    ]
}
JSON

# shellcheck source=/dev/null
source "$installer"
patch_installer_data "$test_tmp/data.json" "$test_tmp/out.json"

python3 - "$test_tmp/out.json" <<'PY' || fail "the patched installer data is what the installer needs"
import json, sys
d = json.load(open(sys.argv[1]))
fw = {o["name"]: o.get("supported_fw") for o in d["os_list"]}
assert fw["Asahi Alarm Minimal (BTRFS)"] == ["14.8.3", "12.3", "12.3.1", "13.5"], fw
assert fw["one line"] == ["13.5", "14.8.3"], fw
assert fw["already there"] == ["13.5", "14.8.3"], fw
assert fw["empty"] == ["14.8.3"], fw
assert fw["Tethered boot (m1n1, for development)"] is None, fw
PY
pass "the patched installer data is what the installer needs"

patch_installer_data "$test_tmp/out.json" "$test_tmp/twice.json"
cmp -s "$test_tmp/out.json" "$test_tmp/twice.json" || fail "patching is idempotent"
pass "patching is idempotent"

[[ $(mac_generation_for j516sap) == "m3" ]] || fail "J516s is an M3 Pro"
pass "J516s is an M3 Pro"
[[ $(mac_generation_for j575dap) == "m3" ]] || fail "J575d is an M3 Ultra"
pass "J575d is an M3 Ultra"
[[ $(mac_generation_for j316sap) == "m1" ]] || fail "J316s is an M1 Pro"
pass "J316s is an M1 Pro"
[[ $(mac_generation_for j999ap) == "unknown" ]] || fail "an unlisted target is unknown"
pass "an unlisted target is unknown"

grep -q 't6032' "$ROOT/bin/omarchy-mac-setup" ||
  fail "the guided setup warns on an M3 Ultra as well as M3/Pro/Max"
pass "the guided setup warns on an M3 Ultra as well as M3/Pro/Max"

# UWSM, not apple.lua, must export AQ_NO_MODIFIERS before Aquamarine starts.
stub_soc="$test_tmp/bin/omarchy-hw-apple-soc"
mkdir -p "$(dirname "$stub_soc")"
cat >"$stub_soc" <<'SH'
#!/bin/bash
case ${1:-} in
  --gpu) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub_soc"
aq=$(
  OMARCHY_PATH="$test_tmp" HOME="$test_tmp" bash -c '
    apple_soc="${OMARCHY_PATH%/}/bin/omarchy-hw-apple-soc"
    if [ -x "$apple_soc" ] && "$apple_soc" >/dev/null 2>&1 && ! "$apple_soc" --gpu; then
      export AQ_NO_MODIFIERS=1
    fi
    printf %s "${AQ_NO_MODIFIERS:-}"
  '
)
[[ $aq == "1" ]] || fail "UWSM exports AQ_NO_MODIFIERS when the GPU driver is unbound"
pass "UWSM exports AQ_NO_MODIFIERS when the GPU driver is unbound"

# The same block must stay in the UWSM env file, not only in this test.
python3 - "$uwsm_env" <<'PY' || fail "the UWSM env file is what exports AQ_NO_MODIFIERS"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert "AQ_NO_MODIFIERS=1" in text
assert "omarchy-hw-apple-soc" in text
assert "--gpu" in text
PY
pass "the UWSM env file is what exports AQ_NO_MODIFIERS"
