#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command bsdtar
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export FIXTURE_DIR="$work" INSTALL_HELPER="$ROOT/install/helpers/mac-install.sh"
mkdir -p "$work/bin" "$work/archives" "$work/cache"

# Real package archives exercise metadata and payload checks without a package
# manager, root privileges, network, or writes outside this fixture.
make_packages() {
  local scenario="$1" package version payload
  rm -f "$work/archives/"*
  for package in omarchy omarchy-settings omarchy-keyring ttf-jetbrains-mono-nerd-basic; do
    payload="$work/payload"
    rm -rf "$payload"
    mkdir -p "$payload"
    version=4.0.2-3
    if [[ $package == "omarchy-settings" && $scenario == "mismatch" ]]; then version=4.0.2-4; fi
    printf 'pkgname = %s\npkgver = %s\narch = aarch64\n' "$package" "$version" > "$payload/.PKGINFO"
    if [[ $package == "omarchy" ]]; then
      if [[ $scenario != "snapper" ]]; then echo 'depend = snapper' >> "$payload/.PKGINFO"; fi
      if [[ $scenario != "protocol" ]]; then
        mkdir -p "$payload/usr/share/omarchy/install/helpers"
        printf '# omarchy:mac-install-protocol=1\n' > "$payload/usr/share/omarchy/install/helpers/mac-install.sh"
      fi
    elif [[ $package == "omarchy-settings" ]]; then
      mkdir -p "$payload/etc/mkinitcpio.conf.d" "$payload/usr/share/omarchy/default/systemd/user" "$payload/usr/lib/systemd/user"
      if [[ $scenario != "boot" ]]; then touch "$payload/etc/mkinitcpio.conf.d/omarchy_hooks.conf"; fi
      touch "$payload/usr/share/omarchy/default/systemd/user/omarchy-brightness-keyboard-auto.service"
      if [[ $scenario != "keyboard" ]]; then touch "$payload/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service"; fi
    fi
    printf 'selected-%s\n' "$package" > "$payload/INSTALLER_TEST_PAYLOAD"
    bsdtar -czf "$work/archives/$package-$version-aarch64.pkg.tar.gz" -C "$payload" .PKGINFO $(cd "$payload" && printf '%s\n' * 2>/dev/null | sed '/^\*$/d')
  done
}
cat > "$work/bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat > "$work/bin/pacman-conf" <<'STUB'
#!/bin/bash
printf '%s/cache\n' "$FIXTURE_DIR"
STUB
cat > "$work/bin/pacman" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE_DIR/pacman.log"
case $1 in
  -Spdd)
    [[ $* == *omarchy-aarch64/omarchy* ]] || exit 99
    [[ $SCENARIO != "unavailable" ]] || exit 1
    for file in "$FIXTURE_DIR/archives/"*; do
      info=$(bsdtar -xOf "$file" .PKGINFO)
      name=$(sed -n 's/^pkgname = //p' <<< "$info")
      version=$(sed -n 's/^pkgver = //p' <<< "$info")
      repo=omarchy-aarch64
      arch=aarch64
      [[ $SCENARIO != "repository" ]] || repo=extra
      [[ $SCENARIO != "architecture" ]] || arch=x86_64
      printf '%s %s %s %s %s\n' "$repo" "$name" "$version" "$arch" "${file##*/}"
    done
    ;;
  -Swdd)
    while [[ $1 != "--cachedir" ]]; do shift; done
    cp "$FIXTURE_DIR/archives/"* "$2/"
    if [[ $SCENARIO == "changed" ]]; then rm -f "$2/"*; fi
    ;;
  -U)
    touch "$FIXTURE_DIR/installed"
    mkdir -p "$FIXTURE_DIR/package-state"
    needed=0
    for arg in "$@"; do
      if [[ $arg == "--needed" ]]; then needed=1; fi
    done
    for file in "$@"; do
      [[ $file != -* ]] || continue
      info=$(bsdtar -xOf "$file" .PKGINFO)
      name=$(sed -n 's/^pkgname = //p' <<< "$info")
      version=$(sed -n 's/^pkgver = //p' <<< "$info")
      # Model pacman's same-version skip: older custom content survives when
      # --needed is passed, despite the requested archive containing new files.
      if (( needed )) && [[ -f $FIXTURE_DIR/package-state/$name.version ]] &&
        [[ $(cat "$FIXTURE_DIR/package-state/$name.version") == "$version" ]]; then
        continue
      fi
      printf '%s\n' "$version" > "$FIXTURE_DIR/package-state/$name.version"
      bsdtar -xOf "$file" INSTALLER_TEST_PAYLOAD > "$FIXTURE_DIR/package-state/$name.payload"
    done
    ;;
  *) exit 98 ;;
esac
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
for scenario in good unavailable mismatch repository architecture snapper protocol boot keyboard changed; do
  make_packages "$scenario"
  rm -f "$work/installed" "$work/pacman.log"
  status=0
  SCENARIO="$scenario" /bin/bash -c 'source "$INSTALL_HELPER"; install_prebuilt_omarchy_packages' > "$work/output" 2>&1 || status=$?
  if [[ $scenario == "good" ]]; then
    (( status == 0 )) && [[ -f $work/installed ]] || fail 'complete matching release installs' "$(cat "$work/output")"
    grep -qF -- '-U --noconfirm' "$work/pacman.log" || fail 'validated archives installed together'
    pass 'complete matching release downloads from ARM repository and installs validated archives'
  else
    (( status != 0 )) && [[ ! -f $work/installed ]] || fail "candidate rejected before core package installation: $scenario" "$(cat "$work/output")"
    pass "candidate rejected before core package installation: $scenario"
  fi
done

# Reinstalling either a source build or published release must replace custom
# content already installed under the same full version (including pkgrel).
make_packages good
mkdir -p "$work/source-tree/install/helpers" "$work/source-tree/build-output"
cp "$INSTALL_HELPER" "$work/source-tree/install/helpers/mac-install.sh"
cp "$ROOT/install/helpers/arm-package-sources.sh" "$work/source-tree/install/helpers/arm-package-sources.sh"
cp "$work/archives/"* "$work/source-tree/build-output/"
for mode in packages source; do
  for package in omarchy omarchy-settings omarchy-keyring ttf-jetbrains-mono-nerd-basic; do
    printf '4.0.2-3\n' > "$work/package-state/$package.version"
    printf 'old-custom-payload\n' > "$work/package-state/$package.payload"
  done
  if [[ $mode == "packages" ]]; then
    SCENARIO=good /bin/bash -c 'source "$INSTALL_HELPER"; install_prebuilt_omarchy_packages' > "$work/reinstall" 2>&1
  else
    /bin/bash -c 'source "$FIXTURE_DIR/source-tree/install/helpers/mac-install.sh"; install_omarchy_packages' > "$work/reinstall" 2>&1 || fail 'source archives reinstall successfully' "$(cat "$work/reinstall")"
  fi
  for package in omarchy omarchy-settings omarchy-keyring ttf-jetbrains-mono-nerd-basic; do
    [[ $(cat "$work/package-state/$package.payload") == "selected-$package" ]] ||
      fail "$mode installation replaces existing same-version $package payload"
  done
  pass "$mode installation replaces existing same-version package payloads"
done

# Exercise the actual two branches of main with external actions stubbed.
# exec is stubbed too so neither test starts an installed helper on this host.
for mode in packages source; do
  MODE="$mode" /bin/bash -c '
    source "$INSTALL_HELPER"
    check_preconditions() { :; }; ensure_utf8_locale() { :; }
    ensure_arm_package_repo() { :; }; ensure_gum() { :; }
    ensure_aur_helper() { echo aur; }
    ensure_package_sources() { echo recipes; }
    build_omarchy_packages() { echo build; }
    install_omarchy_packages() { echo local-packages; }
    install_prebuilt_omarchy_packages() { echo published-packages; selected_release=4.0.2-3; }
    pacman() { echo "omarchy 4.0.2-3"; }
    exec() { printf "handoff %s\n" "$*"; }
    if [[ $MODE == "source" ]]; then main --from-source; else main; fi
  ' > "$work/$mode"
done
grep -qxF 'published-packages' "$work/packages" || fail 'normal installation uses published packages'
if grep -qE '^(recipes|build|local-packages|aur)$' "$work/packages"; then fail 'normal bootstrap must not build'; fi
grep -qxF 'build' "$work/source" && grep -qxF 'local-packages' "$work/source" || fail 'explicit source installation builds the checkout'
for mode in packages source; do
  grep -qxF 'handoff bash /usr/share/omarchy/install/helpers/mac-install.sh --finish-install 4.0.2-3' "$work/$mode" || fail 'setup delegates to installed release'
done
pass 'normal installs use published packages; explicit source builds and both hand off to installed release'

SETUP_TOOL="$ROOT/bin/omarchy-mac-setup" /bin/bash -c '
  source "$SETUP_TOOL"
  CONF="$FIXTURE_DIR/setup.conf"
  LOG="$FIXTURE_DIR/setup.log"
  SRC="$FIXTURE_DIR/setup-source"
  mkdir -p "$SRC/.git"
  fail() { if [[ $* != "run as root" ]]; then echo "$*" >&2; exit 1; fi; }
  quiet_console() { :; }; on_exit() { :; }
  uname() { echo aarch64; }
  running_from_a_file() { return 0; }
  current_step() { echo omarchy; }
  run_step() { echo "step:$1 source:$from_source"; }
  load_conf
  username=tester hostname=testbox keymap=us
  save_conf
  main --resume --from-source
  main --resume
' > "$work/resume"
[[ $(grep -cFx 'step:omarchy source:1' "$work/resume") == 2 ]] || fail 'resume source override persists into next resume'
grep -qxF 'SETUP_FROM_SOURCE=1' "$work/setup.conf" || fail 'source mode saved in setup config'
pass 'source mode selected on resume is persisted across restarts'

for flag in --repo --ref; do
  rm -f "$work/touched"
  status=0
  SETUP_TOOL="$ROOT/bin/omarchy-mac-setup" FLAG="$flag" /bin/bash -c '
    source "$SETUP_TOOL"
    CONF="$FIXTURE_DIR/no-config"
    ensure_user() { touch "$FIXTURE_DIR/touched"; }
    ensure_source_checkout() { touch "$FIXTURE_DIR/touched"; }
    main "$FLAG" custom
  ' > "$work/custom" 2>&1 || status=$?
  (( status != 0 )) && [[ ! -f $work/touched ]] || fail "custom $flag rejected before setup"
  grep -qF 'require --from-source' "$work/custom" || fail "custom $flag explains required source option"
done
pass 'custom repositories and refs require explicit source mode before setup starts'

# The packaged helper resolves its own installed tree, rejects dev-link state,
# and stops if the repository refresh unexpectedly changes the core release.
mkdir -p "$work/installed-tree/install/helpers" "$work/installed-tree/default/bash"
cp "$INSTALL_HELPER" "$work/installed-tree/install/helpers/mac-install.sh"
cp "$ROOT/install/helpers/arm-package-sources.sh" "$work/installed-tree/install/helpers/arm-package-sources.sh"
cat > "$work/installed-tree/default/bash/env-bootstrap" <<'STUB'
OMARCHY_PATH="$FIXTURE_DIR/installed-tree"
if [[ $FINISH_CASE == "dev-link" ]]; then OMARCHY_PATH=/different/checkout; fi
STUB
for finish_case in good changed dev-link; do
  rm -f "$work/refreshed"
  status=0
  FINISH_CASE="$finish_case" /bin/bash -c '
    source "$FIXTURE_DIR/installed-tree/install/helpers/mac-install.sh"
    check_preconditions() { :; }
    pacman() {
      version=4.0.2-3
      if [[ $FINISH_CASE == "changed" && -f $FIXTURE_DIR/refreshed ]]; then version=4.0.2-4; fi
      printf "%s %s\n" "$2" "$version"
    }
    log() { :; }; ensure_gum() { :; }; ensure_aur_helper() { :; }
    install_default_package_set() { echo "packages:$checkout"; }
    seed_user_defaults() { :; }
    sudo() { echo system; }
    ensure_arm_package_repo() { touch "$FIXTURE_DIR/refreshed"; }
    omarchy-provision-user() { echo user; }
    snapshot_factory_baseline() { echo snapshot; }
    finish_install 4.0.2-3
  ' > "$work/finish" 2>&1 || status=$?
  if [[ $finish_case == "good" ]]; then
    (( status == 0 )) || fail 'installed release finishes successfully' "$(cat "$work/finish")"
    grep -qxF "packages:$work/installed-tree" "$work/finish" && grep -qxF snapshot "$work/finish" || fail 'post-install stages use installed tree'
  else
    (( status != 0 )) || fail "unsafe finalization rejected: $finish_case"
    if grep -qxF user "$work/finish"; then fail "user setup cannot run against wrong release: $finish_case"; fi
  fi
done
pass 'finalization uses the installed tree and rejects dev links or release changes before user setup'
