#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

guard="$ROOT/default/libalpm/scripts/omarchy-platform-guard"
hook="$ROOT/default/libalpm/hooks/00-omarchy-platform-guard.hook"
leaf="$ROOT/install/hardware/platform-guard.sh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# The hook is the pacman side of the contract: every installed or upgraded
# package, before the transaction, with the names on stdin, aborting on failure,
# and running the guard at the path omarchy-settings installs it to.
expected_hook='[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Checking packages against this machine'"'"'s platform...
When = PreTransaction
Exec = /usr/share/libalpm/scripts/omarchy-platform-guard
NeedsTargets
AbortOnFail'
[[ $(<"$hook") == "$expected_hook" ]] || fail "the platform guard hook runs the guard before every install and upgrade"
[[ -x $guard ]] || fail "the platform guard is executable"
pass "the platform guard hook runs the guard before every install and upgrade"

# A repository database as repo-add writes it: one <name>-<version>/desc per
# package. Each argument is name[:group,group].
make_db() {
  local db="$1" spec name groups src
  shift
  src=$(mktemp -d "$test_tmp/db.XXXXXX")
  for spec in "$@"; do
    name=${spec%%:*}
    groups=""
    [[ $spec == *:* ]] && groups=${spec#*:}
    mkdir -p "$src/$name-1-1"
    {
      printf '%%FILENAME%%\n%s-1-1-aarch64.pkg.tar.zst\n\n' "$name"
      printf '%%NAME%%\n%s\n\n' "$name"
      printf '%%VERSION%%\n1-1\n\n'
      if [[ -n $groups ]]; then
        printf '%%GROUPS%%\n'
        tr ',' '\n' <<<"$groups"
        printf '\n'
      fi
      printf '%%ARCH%%\naarch64\n\n'
    } >"$src/$name-1-1/desc"
  done
  mkdir -p "$(dirname "$db")"
  tar -czf "$db" -C "$src" .
}

# The same records as the local database keeps them.
make_local() {
  local dir="$1" spec name groups
  shift
  mkdir -p "$dir"
  for spec in "$@"; do
    name=${spec%%:*}
    groups=""
    [[ $spec == *:* ]] && groups=${spec#*:}
    mkdir -p "$dir/$name-1-1"
    {
      printf '%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n' "$name"
      if [[ -n $groups ]]; then
        printf '%%GROUPS%%\n'
        tr ',' '\n' <<<"$groups"
        printf '\n'
      fi
    } >"$dir/$name-1-1/desc"
  done
}

apple=omarchy-platform-apple-silicon
qualcomm=omarchy-platform-qualcomm
db="$test_tmp/pacman"
make_db "$db/sync/omarchy.db" \
  "omarchy-mac:$apple" "linux-aurora:$apple" "linux-aurora-headers:$apple" "uboot-asahi:$apple" \
  "x1e-firmware:$qualcomm" "shared-firmware:$apple,$qualcomm" "typo-package:omarchy-platform-apple" \
  "omarchy-meta:omarchy"
make_db "$db/sync/extra.db" firefox "aquamarine:hyprland-stack" hyprland
# The same Apple-only name in a repository that does not tag it.
make_db "$db/sync/asahi-alarm.db" uboot-asahi m1n1

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  fake_platform "$test_tmp/$platform" "$platform"
  mkdir -p "$test_tmp/$platform/proc/1"
  ln -s / "$test_tmp/$platform/proc/1/root"
done

# $1 is the machine's platform fixture; the transaction's names follow.
run_guard() {
  local platform="$1"
  shift
  printf '%s\n' "$@" |
    OMARCHY_PACMAN_DB="${GUARD_DB:-$db}" OMARCHY_PROC_ROOT="${GUARD_PROC:-$test_tmp/$platform/proc}" \
      OMARCHY_IMAGE_TARGET="${GUARD_MANIFEST:-$test_tmp/no-manifest}" \
      PATH="$test_tmp/$platform/bin:$ROOT/bin:$PATH" "$guard" "${GUARD_ARGS[@]}" \
      >"$test_tmp/out" 2>"$test_tmp/err"
}
GUARD_ARGS=()

allows() {
  local description="$1"
  shift
  run_guard "$@" || fail "$description" "$(cat "$test_tmp/err")"
}

# A refusal is exit 1 with the guard's explanation, never a crash.
refuses() {
  local description="$1" status=0
  shift
  run_guard "$@" || status=$?
  (( status == 1 )) || fail "$description" "exit $status: $(cat "$test_tmp/err")"
  grep -Eq '^(Refusing to install packages built for another platform|Installed packages are built for another platform|Cannot tell which platform this machine is)' "$test_tmp/err" ||
    fail "$description is explained" "$(cat "$test_tmp/err")"
}

# The root-environment probes need a name no real system database carries,
# tagged for no platform so any machine refuses it, and an image build whose
# manifest names a platform this machine is not.
probe="omarchy-guard-probe-$$-$RANDOM"
make_db "$test_tmp/probe/sync/omarchy.db" "$probe:omarchy-platform-nowhere"
live=$("$ROOT/bin/omarchy-hw-platform" 2>/dev/null) || live=unknown
decoy=apple-silicon
[[ $live != "apple-silicon" ]] || decoy=qualcomm
fake_platform "$test_tmp/decoy" "$decoy"
mkdir -p "$test_tmp/decoy/proc/1" "$test_tmp/decoy-host"
ln -s "$test_tmp/decoy-host" "$test_tmp/decoy/proc/1/root"
printf 'platform=%s\n' "$decoy" >"$test_tmp/decoy-manifest"
chmod 644 "$test_tmp/decoy-manifest"
decoy_env=(OMARCHY_PACMAN_DB="$test_tmp/probe" OMARCHY_PROC_ROOT="$test_tmp/decoy/proc"
  OMARCHY_IMAGE_TARGET="$test_tmp/decoy-manifest" PATH="$test_tmp/decoy/bin:$ROOT/bin:$PATH")

# As root, the guard reads the live databases and the live platform, never the
# fixtures its environment names: a tagged name in a fixture database is only
# refused, and the decoy platform only reported, when the fixture is honoured.
root_runner=()
if (( EUID != 0 )); then
  root_runner=(unshare --user --map-root-user)
fi
if (( EUID == 0 )) || unshare --user --map-root-user true 2>/dev/null; then
  printf '%s\n' "$probe" | env "${decoy_env[@]}" "${root_runner[@]}" "$guard" >/dev/null 2>"$test_tmp/err" ||
    fail "root ignores a fixture database in its environment" "$(cat "$test_tmp/err")"
  reported=$(env "${decoy_env[@]}" "${root_runner[@]}" "$guard" --platform 2>/dev/null) || reported=unknown
  [[ $reported != "$decoy" ]] || fail "root ignores fixture platforms and manifests in its environment"
  pass "root ignores fixture databases, platforms and manifests in its environment"
else
  pass "no unprivileged user namespace; skipping the root override probe"
fi

require_platform_fixtures "the platform guard fixtures"

# The negative controls for the probes above: without root the fixtures are honoured.
GUARD_DB="$test_tmp/probe" refuses "the probe package is refused through the fixture" generic-aarch64 "$probe"
[[ $(env "${decoy_env[@]}" "$guard" --platform) == "$decoy" ]] || fail "the decoy platform is reported through the fixture"
pass "without root the guard answers from its fixtures"

for platform in apple-silicon qualcomm generic-aarch64 generic; do
  allows "untagged packages install on $platform" "$platform" firefox aquamarine hyprland omarchy-meta
  allows "an empty transaction passes on $platform" "$platform"

  if [[ $platform == "apple-silicon" ]]; then
    allows "Apple packages install on Apple Silicon" "$platform" omarchy-mac linux-aurora linux-aurora-headers firefox
  else
    refuses "Apple packages are refused on $platform" "$platform" firefox omarchy-mac
    [[ $(cat "$test_tmp/err") == "Refusing to install packages built for another platform. This machine is $platform:
  omarchy-mac: apple-silicon" ]] || fail "the refusal on $platform names each refused package and its platform" "$(cat "$test_tmp/err")"
  fi

  if [[ $platform == "qualcomm" ]]; then
    allows "Qualcomm packages install on Qualcomm" "$platform" x1e-firmware
  else
    refuses "Qualcomm packages are refused on $platform" "$platform" x1e-firmware
  fi

  if [[ $platform == "apple-silicon" || $platform == "qualcomm" ]]; then
    allows "a package tagged for two platforms installs on $platform" "$platform" shared-firmware
  else
    refuses "a package tagged for two platforms is refused on $platform" "$platform" shared-firmware
  fi

  refuses "a tag naming no platform is refused on $platform" "$platform" typo-package
  pass "the $platform fixture installs only the packages tagged for it"
done

# Privileged mode keeps exported functions out: one named awk would otherwise
# swallow every tag.
if printf 'omarchy-mac\n' | env "BASH_FUNC_awk%%=() { :; }" OMARCHY_PACMAN_DB="$db" \
  OMARCHY_PROC_ROOT="$test_tmp/generic-aarch64/proc" OMARCHY_IMAGE_TARGET="$test_tmp/no-manifest" \
  PATH="$test_tmp/generic-aarch64/bin:$ROOT/bin:$PATH" "$guard" 2>/dev/null; then
  fail "an exported function cannot hide tags from the guard"
fi
pass "an exported function cannot hide tags from the guard"

refuses "a transaction mixing platforms is refused" apple-silicon omarchy-mac x1e-firmware firefox
[[ $(cat "$test_tmp/err") == "Refusing to install packages built for another platform. This machine is apple-silicon:
  x1e-firmware: qualcomm" ]] || fail "only the packages for another platform are named" "$(cat "$test_tmp/err")"
pass "a transaction mixing platforms is refused and names only the misfits"

refuses "a name tagged in one repository is refused whichever repository supplies it" generic-aarch64 uboot-asahi
pass "tags follow the package name across repositories"

broken="$test_tmp/broken"
mkdir -p "$broken/sync"
cp "$db/sync/omarchy.db" "$broken/sync/"
printf 'not a database\n' >"$broken/sync/broken.db"
GUARD_DB=$broken allows "an unreadable database does not wedge other transactions" generic-aarch64 firefox
grep -Fq "could not read $broken/sync/broken.db" "$test_tmp/err" || fail "an unreadable database is reported" "$(cat "$test_tmp/err")"
GUARD_DB=$broken refuses "an unreadable database does not hide the other databases' tags" generic-aarch64 omarchy-mac
pass "an unreadable database is reported and skipped"

# A machine whose identity contradicts itself is only asked about when a
# transaction holds a tagged package, and then refuses it.
mkdir -p "$test_tmp/contradiction/proc/device-tree" "$test_tmp/contradiction/proc/1" "$test_tmp/contradiction/bin"
printf '%s\0' apple,j416c qcom,x1e80100 >"$test_tmp/contradiction/proc/device-tree/compatible"
ln -s / "$test_tmp/contradiction/proc/1/root"
cp "$test_tmp/apple-silicon/bin/uname" "$test_tmp/contradiction/bin/uname"
allows "untagged packages install when the platform cannot be told" contradiction firefox
refuses "tagged packages are refused when the platform cannot be told" contradiction omarchy-mac
grep -Fq "Cannot tell which platform this machine is" "$test_tmp/err" || fail "the refusal explains the unknown platform" "$(cat "$test_tmp/err")"
pass "an unknown platform refuses only tagged packages"

# Image builds: a chroot on some build host, with the target in a manifest.
manifest="$test_tmp/image-target"
chroot_proc() {
  local platform="$1" proc="$test_tmp/chroot-$1"
  rm -rf "$proc"
  cp -a "$test_tmp/$platform/proc" "$proc"
  rm "$proc/1/root"
  mkdir -p "$test_tmp/build-host-root"
  ln -s "$test_tmp/build-host-root" "$proc/1/root"
  printf '%s\n' "$proc"
}
printf '# written by the image builder\nbuilder=test\nplatform=apple-silicon\n' >"$manifest"
chmod 644 "$manifest"

GUARD_MANIFEST=$manifest refuses "a booted system ignores an image-target manifest" generic-aarch64 omarchy-mac
GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic-aarch64) \
  allows "an Apple image builds on a generic host from its manifest" generic-aarch64 omarchy-mac linux-aurora
GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic) \
  allows "an Apple image builds on an x86 host from its manifest" generic omarchy-mac
proc_less="$test_tmp/proc-less"
cp -a "$test_tmp/generic-aarch64/proc" "$proc_less"
rm -rf "$proc_less/1"
GUARD_MANIFEST=$manifest GUARD_PROC=$proc_less \
  allows "a root without /proc is an image build too" generic-aarch64 omarchy-mac
GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic-aarch64) \
  refuses "an Apple image refuses Qualcomm packages" generic-aarch64 x1e-firmware
printf 'platform=generic-aarch64\n' >"$manifest"
GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc apple-silicon) \
  refuses "the build host's Apple device tree never decides the image target" apple-silicon omarchy-mac
GUARD_PROC=$(chroot_proc apple-silicon) \
  allows "a chroot without a manifest, such as an installer on the target, uses the hardware" apple-silicon omarchy-mac
GUARD_PROC=$(chroot_proc generic-aarch64) \
  refuses "a build host's hardware refuses Apple packages when the image names no target" generic-aarch64 omarchy-mac
grep -Fq "An image built for other hardware names its target there" "$test_tmp/err" || fail "the refusal points a builder at the manifest" "$(cat "$test_tmp/err")"
refuses "a booted system refuses Apple packages" generic-aarch64 omarchy-mac
! grep -Fq "image build" "$test_tmp/err" || fail "a booted system's refusal says nothing about image builds" "$(cat "$test_tmp/err")"
hidden_root="$test_tmp/hidden-root"
cp -a "$test_tmp/generic-aarch64/proc" "$hidden_root"
rm "$hidden_root/1/root"
printf 'platform=apple-silicon\n' >"$manifest"
GUARD_MANIFEST=$manifest GUARD_PROC=$hidden_root \
  refuses "a system whose PID 1 root cannot be compared uses the hardware, not a manifest" generic-aarch64 omarchy-mac
GUARD_ARGS=(--platform)
GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic) allows "--platform reports an image build's target" generic
[[ $(cat "$test_tmp/out") == "apple-silicon" ]] || fail "--platform reports an image build's target" "$(cat "$test_tmp/out")"
GUARD_MANIFEST=$manifest allows "--platform reports a booted system's hardware" qualcomm
[[ $(cat "$test_tmp/out") == "qualcomm" ]] || fail "--platform reports a booted system's hardware" "$(cat "$test_tmp/out")"
GUARD_ARGS=()
pass "image builds take their platform from the manifest, and only image builds"

bad_manifest() {
  local description="$1"
  GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic-aarch64) \
    refuses "$description refuses tagged packages" generic-aarch64 omarchy-mac
  grep -Fq "image-target manifest" "$test_tmp/err" || fail "$description is explained" "$(cat "$test_tmp/err")"
  GUARD_MANIFEST=$manifest GUARD_PROC=$(chroot_proc generic-aarch64) \
    allows "$description still lets untagged packages install" generic-aarch64 firefox
}
printf 'platform=apple-silicon\n' >"$manifest"
chmod 664 "$manifest"
bad_manifest "a group-writable manifest"
chmod 646 "$manifest"
bad_manifest "a world-writable manifest"
chmod 644 "$manifest"
printf 'platform=apple\n' >"$manifest"
bad_manifest "a manifest naming an unknown platform"
printf 'platform=apple-silicon\nplatform=qualcomm\n' >"$manifest"
bad_manifest "a manifest naming two platforms"
printf 'target=apple-silicon\n' >"$manifest"
bad_manifest "a manifest without a platform"
printf 'platform=apple-silicon\n' >"$test_tmp/real-manifest"
rm "$manifest"
ln -s "$test_tmp/real-manifest" "$manifest"
bad_manifest "a symlinked manifest"
rm "$manifest"
pass "a manifest that is not root's own, well-formed file is refused"

# --installed checks the packages already installed, from the local database.
make_local "$test_tmp/installed-apple/local" firefox "omarchy-mac:$apple" "linux-aurora:$apple"
make_local "$test_tmp/installed-generic/local" firefox hyprland "omarchy-meta:omarchy"
GUARD_ARGS=(--installed)
GUARD_DB="$test_tmp/installed-apple" allows "installed Apple packages pass on Apple Silicon" apple-silicon
GUARD_DB="$test_tmp/installed-apple" refuses "installed Apple packages fail on generic aarch64" generic-aarch64
[[ $(cat "$test_tmp/err") == "Installed packages are built for another platform. This machine is generic-aarch64:
  linux-aurora: apple-silicon
  omarchy-mac: apple-silicon" ]] || fail "the installed check names each misfit" "$(cat "$test_tmp/err")"
GUARD_DB="$test_tmp/installed-generic" allows "untagged installed packages pass anywhere" generic
GUARD_DB="$test_tmp/empty" allows "an empty local database passes" generic
GUARD_ARGS=()
pass "installed packages are checked against the platform"

if "$guard" --bogus >/dev/null 2>&1; then
  fail "the guard rejects unknown arguments"
fi
pass "the guard rejects unknown arguments"

# Hardware setup runs the leaf first. A fresh install reaches it only after the
# installer's transactions, so it proves the guard is resident before hardware
# setup installs anything, and checks what the installer already placed.
alpm="$test_tmp/alpm"
run_leaf() {
  local platform="$1"
  OMARCHY_ALPM_ROOT="$alpm" OMARCHY_PACMAN_DB="${GUARD_DB:-$db}" OMARCHY_PROC_ROOT="$test_tmp/$platform/proc" \
    OMARCHY_IMAGE_TARGET="$test_tmp/no-manifest" PATH="$test_tmp/$platform/bin:$ROOT/bin:$PATH" \
    bash -eE -c 'source "$1"' bash "$leaf" >"$test_tmp/out" 2>"$test_tmp/err"
}

mkdir -p "$alpm"
if run_leaf apple-silicon; then
  fail "hardware setup refuses to start without the platform guard"
fi
grep -Fq "install omarchy-settings in a transaction before hardware setup" "$test_tmp/err" ||
  fail "a missing guard is explained" "$(cat "$test_tmp/err")"
mkdir -p "$alpm/usr/share/libalpm/hooks"
cp "$hook" "$alpm/usr/share/libalpm/hooks/"
if run_leaf apple-silicon; then
  fail "hardware setup refuses to start when the hook's guard is missing"
fi
mkdir -p "$alpm/usr/share/libalpm/scripts"
ln -s "$guard" "$alpm/usr/share/libalpm/scripts/omarchy-platform-guard"
GUARD_DB="$test_tmp/installed-apple" run_leaf apple-silicon || fail "hardware setup starts with the guard resident" "$(cat "$test_tmp/err")"
if GUARD_DB="$test_tmp/installed-apple" run_leaf qualcomm; then
  fail "hardware setup refuses packages the installer placed for another platform"
fi
mkdir -p "$alpm/etc/pacman.d/hooks"
ln -s /dev/null "$alpm/etc/pacman.d/hooks/00-omarchy-platform-guard.hook"
GUARD_DB="$test_tmp/installed-apple" run_leaf qualcomm || fail "a masked guard is the administrator's choice" "$(cat "$test_tmp/err")"
grep -Fq "overrides the pacman platform guard" "$test_tmp/out" || fail "a masked guard is reported" "$(cat "$test_tmp/out")"
pass "hardware setup starts only with the platform guard resident"

# Fresh-install order: nothing before the leaf installs a package. The system
# setup leaves run before hardware setup, and the leaf is hardware setup's first.
mapfile -t system_leaves < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(.*\)"$|\1|p' "$ROOT/install/config/all.sh")
(( ${#system_leaves[@]} > 0 )) || fail "system setup leaves are listed"
installers='omarchy-pkg-(add|install|aur-add|aur-install)|pacman[^|;&]*[[:space:]](-[[:alpha:]]*[SU][[:alpha:]]*|--sync|--upgrade)([[:space:]]|$)|omarchy-setup-mac'
for system_leaf in "${system_leaves[@]}"; do
  ! grep -Eq "$installers" "$ROOT/install/$system_leaf" || fail "system setup installs no packages before hardware setup" "$system_leaf"
done
config_line=$(grep -n 'source "\$OMARCHY_INSTALL/config/all.sh"' "$ROOT/bin/omarchy-apply-system" | cut -d: -f1)
hardware_line=$(grep -n -E '^[[:space:]]*omarchy-apply-hardware[[:space:]]+--' "$ROOT/bin/omarchy-apply-system" | head -n 1 | cut -d: -f1)
[[ -n $config_line && -n $hardware_line ]] && (( config_line < hardware_line )) || fail "system setup precedes hardware setup"
first_hardware_leaf=$(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(.*\)"$|\1|p' "$ROOT/install/hardware/all.sh" | head -n 1)
[[ $first_hardware_leaf == "hardware/platform-guard.sh" ]] ||
  fail "the platform guard check is hardware setup's first step" "first: $first_hardware_leaf"
pass "fresh-install setup installs nothing before the platform guard is proven resident"
