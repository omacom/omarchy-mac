#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/install/helpers/package-recipes.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fixture="$work/source"
checkout_fixture="$work/checkout"
mkdir -p "$fixture" "$checkout_fixture/packaging"
git -C "$fixture" init -q
for package in omarchy omarchy-settings omarchy-keyring ttf-jetbrains-mono-nerd-basic; do
  mkdir -p "$fixture/pkgbuilds/$package"
  printf 'reviewed\n' >"$fixture/pkgbuilds/$package/PKGBUILD"
done
git -C "$fixture" add .
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qm reviewed
pin=$(git -C "$fixture" rev-parse HEAD)
printf '%s\n' "$pin" >"$checkout_fixture/packaging/omarchy-pkgs.commit"
cat >"$checkout_fixture/packaging/mac-profile.patch" <<'PATCH'
--- a/pkgbuilds/omarchy/PKGBUILD
+++ b/pkgbuilds/omarchy/PKGBUILD
@@ -1 +1 @@
-reviewed
+profile
PATCH

printf 'new upstream\n' >"$fixture/pkgbuilds/omarchy/PKGBUILD"
git -C "$fixture" -c user.name=Test -c user.email=test@example.invalid commit -qam newer
printf 'uncommitted\n' >"$fixture/pkgbuilds/omarchy/PKGBUILD"
before=$(git -C "$fixture" status --porcelain=v1)
head_before=$(git -C "$fixture" rev-parse HEAD)
source_dir=$(OMARCHY_PKGS_PATH="$fixture/pkgbuilds" omarchy_package_recipe_source "$checkout_fixture" "$pin")
[[ $(omarchy_package_recipe_commit "$checkout_fixture") == "$pin" ]] || fail "the pin resolves exactly"
omarchy_package_recipe_export "$checkout_fixture" "$source_dir" "$work/export" "$pin"
[[ $(cat "$work/export/pkgbuilds/omarchy/PKGBUILD") == "profile" ]] || fail "the pinned object receives the reviewed profile"
[[ $(cat "$fixture/pkgbuilds/omarchy/PKGBUILD") == "uncommitted" ]] || fail "the source working tree stays untouched"
[[ $(git -C "$fixture" status --porcelain=v1) == "$before" && $(git -C "$fixture" rev-parse HEAD) == "$head_before" ]] || fail "the recipe source refs and index stay untouched"
pass "recipe export uses the pinned commit despite a newer, dirty source checkout"
omarchy_package_recipe_export "$checkout_fixture" "$source_dir" "$fixture/nested-stage" "$pin"
[[ $(cat "$fixture/nested-stage/pkgbuilds/omarchy/PKGBUILD") == "profile" ]] || fail "a stage inside another checkout still applies the profile"
pass "recipe patch application also works with TMPDIR inside another Git checkout"

# The builder declares checkout readonly. Exercise all helpers in that actual
# caller context so a helper local cannot accidentally shadow the global.
bash -euo pipefail -c '
  source "$ROOT/build-packages.sh"
  resolved_pin=$(omarchy_package_recipe_commit "$1")
  [[ $resolved_pin == "$4" ]]
  resolved_source=$(OMARCHY_PKGS_PATH="$2/pkgbuilds" omarchy_package_recipe_source "$1" "$resolved_pin")
  omarchy_package_recipe_export "$1" "$resolved_source" "$3" "$resolved_pin"
  [[ $(cat "$3/pkgbuilds/omarchy/PKGBUILD") == "profile" ]]
  [[ $checkout == "$ROOT" ]]
' _ "$checkout_fixture" "$fixture" "$work/builder-export" "$pin" || fail "recipe helpers work with the actual builder and its readonly globals"
pass "the actual builder can resolve and export pinned recipes with its readonly globals"

for bad in main b81d678b invalid; do
  printf '%s\n' "$bad" >"$checkout_fixture/packaging/omarchy-pkgs.commit"
  if omarchy_package_recipe_commit "$checkout_fixture" >/dev/null 2>&1; then
    fail "non-immutable recipe pins are rejected"
  fi
done
if OMARCHY_PKGS_PATH="$fixture" omarchy_package_recipe_source "$checkout_fixture" 0000000000000000000000000000000000000000 >/dev/null 2>&1; then
  fail "an explicit recipe source missing the pin fails closed"
fi
sed -i 's/^-reviewed/-obsolete/' "$checkout_fixture/packaging/mac-profile.patch"
if omarchy_package_recipe_export "$checkout_fixture" "$source_dir" "$work/stale" "$pin" >/dev/null 2>&1; then
  fail "a stale recipe profile fails closed"
fi
pass "invalid pins, missing objects and stale profiles stop the build"

# These stubs exercise dependency-check behavior, never the system package DB.
mkdir -p "$work/bin"
cat >"$work/bin/makepkg" <<'STUB'
#!/bin/bash
printf 'makedepends = git\nmakedepends_aarch64 = imagemagick\n'
STUB
cat >"$work/bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == -T ]] || exit 99
[[ ${DEPENDENCY_STATUS:-0} != 127 || ${EMPTY_MISSING:-0} == 1 ]] || printf 'imagemagick\n'
exit "${DEPENDENCY_STATUS:-0}"
STUB
cat >"$work/bin/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_LOG"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" SUDO_LOG="$work/sudo.log"
if ! (
  source "$ROOT/build-packages.sh"
  DEPENDENCY_STATUS=0 install_build_dependencies "$fixture/pkgbuilds"
); then
  fail "an equipped builder needs no privilege escalation"
fi
for status in 127 1; do
  if (
    source "$ROOT/build-packages.sh"
    DEPENDENCY_STATUS=$status install_build_dependencies "$fixture/pkgbuilds"
  ) >/dev/null 2>&1; then
    fail "dependency check failures stop an ordinary build"
  fi
done
if (
  source "$ROOT/build-packages.sh"
  EMPTY_MISSING=1 DEPENDENCY_STATUS=127 install_build_dependencies "$fixture/pkgbuilds"
) >/dev/null 2>&1; then
  fail "a failed dependency check with empty output does not look successful"
fi
[[ ! -e $SUDO_LOG ]] || fail "default dependency checks never invoke sudo"
(
  source "$ROOT/build-packages.sh"
  OMARCHY_BUILD_DEPS=install DEPENDENCY_STATUS=127 install_build_dependencies "$fixture/pkgbuilds"
)
[[ $(cat "$SUDO_LOG") == "pacman -S --needed --noconfirm imagemagick" ]] || fail "only explicit install mode installs missing build dependencies"
pass "default builds only check dependencies; installation requires explicit mode"

require_command bsdtar
mkdir -p "$work/artifacts" "$work/metadata"
for package in omarchy omarchy-settings; do
  printf 'pkgname = %s\npkgver = 4.0.2-1\n' "$package" >"$work/metadata/.PKGINFO"
  bsdtar -czf "$work/artifacts/$package.pkg.tar.gz" -C "$work/metadata" .PKGINFO
done
(
  export OMARCHY_PACKAGE_OUTPUT="$work/artifacts"
  source "$ROOT/build-packages.sh"
  write_build_provenance "$pin"
)
grep -qx "runtime_version=$(cat "$ROOT/version")" "$work/artifacts/build-provenance.txt" || fail "provenance includes the source version"
grep -qx 'package=omarchy 4.0.2-1 omarchy.pkg.tar.gz' "$work/artifacts/build-provenance.txt" || fail "provenance reads actual archive metadata"
printf 'pkgname = omarchy-settings\npkgver = 4.0.2-2\n' >"$work/metadata/.PKGINFO"
bsdtar -czf "$work/artifacts/omarchy-settings.pkg.tar.gz" -C "$work/metadata" .PKGINFO
if (
  export OMARCHY_PACKAGE_OUTPUT="$work/artifacts"
  source "$ROOT/build-packages.sh"
  write_build_provenance "$pin"
) >/dev/null 2>&1; then
  fail "mismatched archive package releases fail validation"
fi
(
  export OMARCHY_PACKAGE_OUTPUT="$work/artifacts"
  source "$ROOT/build-packages.sh"
  remove_old_packages
)
[[ ! -e $work/artifacts/build-provenance.txt && ! -e $work/artifacts/omarchy.pkg.tar.gz ]] || fail "a rebuild clears stale archives and provenance"
pass "provenance records archive metadata and source version, rejects mismatched releases and is cleared on rebuild"
