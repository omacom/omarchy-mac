#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_platform_fixtures "platform package lists"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMARCHY_PATH="$ROOT"

names() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$@"
}

# Package names that exist only for Apple Silicon.
apple_only='^(omarchy-mac(-.*)?|linux-aurora(-.*)?|linux-asahi(-.*)?|m1n1(-.*)?|uboot-asahi|asahi-.*|avd-fw|libva-v4l2_request-avd|speakersafetyd|widevine)$'

base=$(names "$ROOT/install/omarchy-base.packages")
aarch64=$(names "$ROOT/install/omarchy-aarch64.packages")

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$work/$platform" "$platform"
  defaults=$(OMARCHY_PROC_ROOT="$work/$platform/proc" PATH="$work/$platform/bin:$ROOT/bin:$PATH" omarchy-pkg-defaults)
  [[ $defaults == "$(omarchy-pkg-defaults "$platform")" ]] ||
    fail "$platform: the detected platform selects its own list"
  printf '%s\n' "$defaults" >"$work/$platform.packages"

  [[ -z $(sort "$work/$platform.packages" | uniq -d) ]] || fail "$platform: each package is listed once"
  [[ $(head -n "$(wc -l <<<"$base")" "$work/$platform.packages") == "$base" ]] ||
    fail "$platform: the base list comes first, unchanged"

  case $platform in
    generic)
      [[ $defaults == "$base" ]] || fail "x86_64 installs exactly the base list"
      [[ $defaults == "$(grep -v '^#' "$ROOT/install/omarchy-base.packages" | grep -v '^$')" ]] ||
        fail "x86_64 installs what omarchy-reinstall-pkgs read from the base list before"
      ;;
    *)
      while IFS= read -r package; do
        grep -Fxq "$package" "$work/$platform.packages" || fail "$platform: aarch64 addition $package"
      done <<<"$aarch64"
      ;;
  esac

  if [[ $platform == apple-silicon ]]; then
    while IFS= read -r package; do
      grep -Fxq "$package" "$work/$platform.packages" || fail "Apple Silicon: $package"
    done < <(names "$ROOT/install/omarchy-apple.packages")
  else
    ! grep -Eq "$apple_only" "$work/$platform.packages" ||
      fail "$platform: no Apple Silicon package" "$(grep -E "$apple_only" "$work/$platform.packages")"
  fi

  if [[ $platform == qualcomm ]]; then
    grep -Fxq linux-firmware-qcom "$work/$platform.packages" || fail "Qualcomm adds its firmware"
  else
    ! grep -Fxq linux-firmware-qcom "$work/$platform.packages" || fail "$platform: no Qualcomm firmware"
  fi
done
pass "each platform composes base, architecture and platform lists, and only Apple Silicon names Apple packages"

! omarchy-pkg-defaults riscv 2>/dev/null || fail "an unknown platform is refused"
pass "an unknown platform is refused"

# omarchy-reinstall-pkgs installs the detected platform's set.
mkdir -p "$work/stubs"
cat >"$work/stubs/omarchy-update-pacman" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
SH
cat >"$work/stubs/omarchy-refresh-pacman" <<'SH'
#!/bin/bash
printf 'refresh %s\n' "$*" >>"$STUB_LOG"
SH
printf '#!/bin/bash\n' >"$work/stubs/lspci"
chmod +x "$work/stubs/"*

for platform in apple-silicon generic; do
  export STUB_LOG="$work/$platform.log"
  : >"$STUB_LOG"
  OMARCHY_PROC_ROOT="$work/$platform/proc" PATH="$work/stubs:$work/$platform/bin:$ROOT/bin:$PATH" \
    omarchy-reinstall-pkgs
  expected="-Syu --noconfirm --needed $(tr '\n' ' ' <"$work/$platform.packages")"
  [[ $(tail -n 1 "$STUB_LOG") == "${expected% }" ]] ||
    fail "$platform: reinstall installs the platform's default set" "$(tail -n 1 "$STUB_LOG")"
done
pass "omarchy-reinstall-pkgs installs the platform's default set"
