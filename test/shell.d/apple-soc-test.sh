#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

soc="$ROOT/bin/omarchy-hw-apple-soc"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# The kernel's compatible file: NUL-separated, machine first, then SoC.
compat() {
  local file="$test_tmp/$1"
  shift
  printf '%s\0' "$@" >"$file"
  printf '%s' "$file"
}

m1=$(compat m1 apple,j314s apple,t6000 apple,arm-platform)
m2=$(compat m2 apple,j413 apple,t8112 apple,arm-platform)
m3=$(compat m3 apple,j516s apple,t6030 apple,arm-platform)
m3max=$(compat m3max apple,j514c apple,t6031 apple,arm-platform)
m3ultra=$(compat m3ultra apple,j575d apple,t6032 apple,arm-platform)
m4=$(compat m4 apple,j713 apple,t8132 apple,arm-platform)
m4pro=$(compat m4pro apple,j714 apple,t6040 apple,arm-platform)
m5=$(compat m5 apple,j815 apple,t6050 apple,arm-platform)
pi=$(compat pi raspberrypi,4-model-b brcm,bcm2711)

run() {
  OMARCHY_APPLE_COMPATIBLE="$1" OMARCHY_DRM_SYSFS_PATH="$test_tmp/no-drm" \
    OMARCHY_PLATFORM_DRIVERS_PATH="$test_tmp/no-drivers" bash "$soc" "${@:2}"
}

[[ $(run "$m1") == "m1" ]] || fail "t6000 is an M1 Pro"
pass "t6000 is an M1 Pro"
[[ $(run "$m2") == "m2" ]] || fail "t8112 is an M2"
pass "t8112 is an M2"
[[ $(run "$m3") == "m3" ]] || fail "t6030 is an M3 Pro"
pass "t6030 is an M3 Pro"
[[ $(run "$m3max") == "m3" ]] || fail "t6031 is an M3 Max"
pass "t6031 is an M3 Max"
[[ $(run "$m3ultra") == "m3" ]] || fail "t6032 is an M3 Ultra"
pass "t6032 is an M3 Ultra"
run "$m3ultra" --is m3 || fail "--is m3 matches an M3 Ultra"
pass "--is m3 matches an M3 Ultra"
[[ $(run "$m4") == "m4" ]] || fail "t8132 is an M4"
pass "t8132 is an M4"
! run "$m4pro" || fail "t6040 stays unmapped until a confirmed M4 Pro device tree"
pass "t6040 stays unmapped until a confirmed M4 Pro device tree"
! run "$m5" || fail "t6050 is not claimed as M4"
pass "t6050 is not claimed as M4"

[[ $(run "$m3" --codename) == "j516s" ]] || fail "the codename is the non-SoC apple entry"
pass "the codename is the non-SoC apple entry"

run "$m3" --is m3 || fail "--is matches the detected generation"
pass "--is matches the detected generation"
! run "$m3" --is m2 || fail "--is rejects another generation"
pass "--is rejects another generation"

! run "$pi" || fail "a non-Apple device tree exits 1"
pass "a non-Apple device tree exits 1"
! run "$test_tmp/missing" || fail "no device tree exits 1"
pass "no device tree exits 1"

# GPU: no DRM card at all means no driver.
! run "$m3" --gpu || fail "--gpu is false with no DRM device"
pass "--gpu is false with no DRM device"

# A card whose driver is not asahi (simpledrm on an M3) is still no driver.
mkdir -p "$test_tmp/drm/card0/device" "$test_tmp/drivers/simple-framebuffer"
ln -s "$test_tmp/drivers/simple-framebuffer" "$test_tmp/drm/card0/device/driver"
! OMARCHY_APPLE_COMPATIBLE="$m3" OMARCHY_DRM_SYSFS_PATH="$test_tmp/drm" \
  OMARCHY_PLATFORM_DRIVERS_PATH="$test_tmp/no-drivers" bash "$soc" --gpu ||
  fail "--gpu is false when only simpledrm is bound"
pass "--gpu is false when only simpledrm is bound"

# The asahi driver bound to a card is the yes.
mkdir -p "$test_tmp/drm/card1/device" "$test_tmp/drivers/asahi"
ln -s "$test_tmp/drivers/asahi" "$test_tmp/drm/card1/device/driver"
OMARCHY_APPLE_COMPATIBLE="$m1" OMARCHY_DRM_SYSFS_PATH="$test_tmp/drm" \
  OMARCHY_PLATFORM_DRIVERS_PATH="$test_tmp/no-drivers" bash "$soc" --gpu ||
  fail "--gpu is true when the asahi driver is bound"
pass "--gpu is true when the asahi driver is bound"

# The platform-bus view alone is also enough.
mkdir -p "$test_tmp/drivers2/asahi"
touch "$test_tmp/drivers2/asahi/206400000.gpu"
OMARCHY_APPLE_COMPATIBLE="$m1" OMARCHY_DRM_SYSFS_PATH="$test_tmp/no-drm" \
  OMARCHY_PLATFORM_DRIVERS_PATH="$test_tmp/drivers2" bash "$soc" --gpu ||
  fail "--gpu is true from the platform driver binding"
pass "--gpu is true from the platform driver binding"

# --gpu on a non-Apple machine is a no, not an error about the flag.
! run "$pi" --gpu || fail "--gpu is false off Apple hardware"
pass "--gpu is false off Apple hardware"
