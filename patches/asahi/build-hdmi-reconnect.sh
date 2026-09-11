#!/bin/bash
# Build only: never install a package, change GRUB, or reboot.
set -euo pipefail

if (( $# != 3 )); then
  printf 'Usage: %s CLEAN_KERNEL_SOURCE ASAHI_CONFIG NEW_OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi
if (( EUID == 0 )); then
  printf 'Build as an unprivileged user.\n' >&2
  exit 1
fi
if [[ $(uname -m) != "aarch64" ]]; then
  printf 'This recipe requires a native aarch64 Arch/Asahi build host.\n' >&2
  exit 1
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(realpath -- "$1")
config=$(realpath -- "$2")
output=$(realpath -m -- "$3")
baseline=ce9f2eba72c061a50b2d790450e90af3439d8c24
[[ -f $config ]]
[[ $(git -C "$source_dir" rev-parse --show-toplevel) == "$source_dir" ]]
[[ $(git -C "$source_dir" rev-parse HEAD) == "$baseline" ]]
[[ -z $(git -C "$source_dir" status --porcelain) ]]
if [[ -e $output ]]; then
  printf 'Output directory must not already exist: %s\n' "$output" >&2
  exit 1
fi
# Refuse ignored build products too; use a fresh disposable source checkout.
if [[ -e $source_dir/.config || -e $source_dir/include/generated/utsrelease.h ]]; then
  printf 'Source already configured; use a fresh disposable checkout.\n' >&2
  exit 1
fi
python3 "$here/../../test/asahi/reconnect.py" --source "$source_dir"
git -C "$source_dir" apply --check "$here/apple-dcp-hdmi-reconnect.patch"
git -C "$source_dir" apply "$here/apple-dcp-hdmi-reconnect.patch"
git -C "$source_dir" diff --check
install -m644 "$config" "$source_dir/.config"
"$source_dir/scripts/config" --file "$source_dir/.config" --set-str LOCALVERSION '-1-1-ARCH-hdmi-recover' --disable LOCALVERSION_AUTO
make -C "$source_dir" LOCALVERSION= olddefconfig
make -C "$source_dir" LOCALVERSION= prepare
[[ $(make -s -C "$source_dir" LOCALVERSION= kernelrelease) == "7.1.13-1-1-ARCH-hdmi-recover" ]]
make -C "$source_dir" -j"${JOBS:-8}" LOCALVERSION= drivers/gpu/drm/apple/apple_drv.o drivers/gpu/drm/apple/dcp.o drivers/gpu/drm/apple/iomfb.o drivers/gpu/drm/apple/iomfb_v12_3.o drivers/gpu/drm/apple/iomfb_v13_3.o
make -C "$source_dir" -j"${JOBS:-8}" LOCALVERSION= Image modules dtbs
mkdir -p -- "$output"
install -m644 "$here/PKGBUILD" "$output/PKGBUILD"
export ASAHI_KERNEL_SOURCE="$source_dir"
# Keep makepkg.conf PKGDEST from sending the candidate outside this directory.
(cd -- "$output" && PKGDEST="$output" makepkg --nodeps --noconfirm)
python3 "$here/validate-package.py" "$output"
printf 'BUILD_AND_PACKAGE_VALIDATED (not installed): %s\n' "$output"
