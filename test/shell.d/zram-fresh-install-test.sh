#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export OMARCHY_PATH="${OMARCHY_ZRAM_PACKAGE_ROOT:-$ROOT}"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export OMARCHY_FIRST_INSTALL=1 OMARCHY_UPGRADE=0
export TEST_ZRAM_INSTALLED="$work/installed" TEST_ZRAM_CALLS="$work/calls"
touch "$TEST_ZRAM_INSTALLED" "$TEST_ZRAM_CALLS"
cat >"$work/bin/uname" <<'STUB'
#!/bin/bash
printf '%s\n' "${TEST_ARCH:-aarch64}"
STUB
cat >"$work/bin/omarchy-pkg-missing" <<'STUB'
#!/bin/bash
printf 'package %s\n' "$*" >>"$TEST_ZRAM_CALLS"
[[ ! -e $TEST_ZRAM_INSTALLED ]]
STUB
cat >"$work/bin/install" <<'STUB'
#!/bin/bash
if [[ ${TEST_COPY_FAIL:-0} == 1 ]]; then
  printf partial >"${@: -1}"
  exit 1
fi
exec /usr/bin/install "$@"
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'unexpected systemctl %s\n' "$*" >>"$TEST_ZRAM_CALLS"
exit 99
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# Use the actual dispatcher and logging runner. Intercept unrelated hardware
# leaves so this fixture cannot configure the developer's machine.
source "$OMARCHY_INSTALL/helpers/logging.sh"
eval "$(declare -f run_logged | sed '1s/run_logged/zram_run_logged/')"
run_logged() {
  if [[ $1 == "$OMARCHY_INSTALL/hardware/zram.sh" ]]; then
    zram_run_logged "$1"
  fi
}
export -f run_logged zram_run_logged omarchy_log_line omarchy_log_to_stdout
run_setup() {
  # A separate interpreter retains errexit when the test expects a failure.
  bash -euo pipefail -c 'source "$OMARCHY_INSTALL/hardware/all.sh"' >"$work/setup.log" 2>&1
}
new_root() {
  export OMARCHY_ZRAM_ROOT="$work/$1"
  mkdir -p "$OMARCHY_ZRAM_ROOT"
  : >"$TEST_ZRAM_CALLS"
}

new_root fresh
run_setup
config="$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf"
cmp "$OMARCHY_PATH/default/systemd/zram-generator.conf.d/90-omarchy.conf" "$config" || fail 'fresh hardware setup installs the shipped default'
[[ $(stat -c %a "$config") == 644 ]] || fail 'fresh default is readable by the generator'
: >"$TEST_ZRAM_CALLS"
run_setup
[[ ! -s $TEST_ZRAM_CALLS ]] || fail 'repeated setup preserves configuration without package or service actions'
pass 'fresh and repeated ARM hardware setup delivers persistent configuration'

for context in ordinary upgrade x86; do
  new_root "$context"
  case "$context" in
    ordinary) OMARCHY_FIRST_INSTALL=0 run_setup ;;
    upgrade) OMARCHY_UPGRADE=1 run_setup ;;
    x86) TEST_ARCH=x86_64 run_setup ;;
  esac
  [[ ! -e $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf && ! -s $TEST_ZRAM_CALLS ]] || fail "$context setup must not preempt migration or change x86 policy"
done
pass 'non-fresh, upgrade, and x86 paths remain unchanged'

for directory in etc run usr/local/lib usr/lib; do
  for layout in main drop-in; do
    for kind in custom empty mask dangling-mask; do
      new_root "preserve-$directory-$layout-$kind"
      config="$OMARCHY_ZRAM_ROOT/$directory/systemd/zram-generator.conf"
      [[ $layout == main ]] || config="$config.d/99-local.conf"
      mkdir -p "$(dirname "$config")"
      case "$kind" in
        custom) printf '[zram0]\nzram-size = ram / 4\n' >"$config" ;;
        empty) touch "$config" ;;
        mask) ln -s /dev/null "$config" ;;
        dangling-mask) ln -s "$work/missing" "$config" ;;
      esac
      cp -P "$config" "$work/expected"
      run_setup
      [[ ! -s $TEST_ZRAM_CALLS ]] || fail "preserve $directory/$layout/$kind without activation"
      if [[ -L $config ]]; then
        [[ $(readlink "$config") == "$(readlink "$work/expected")" ]] || fail 'preserve symlink target'
      else
        cmp "$config" "$work/expected" || fail 'preserve administrator bytes'
      fi
      rm "$work/expected"
      if [[ $config != "$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf" ]]; then
        [[ ! -e $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]] || fail 'do not supplement existing generator configuration'
      fi
    done
  done
done
pass 'all main/drop-in locations preserve custom, empty, and masked configurations'

new_root package-failure
rm "$TEST_ZRAM_INSTALLED"
if run_setup; then fail 'missing required package must fail first installation'; fi
[[ ! -e $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]] || fail 'missing generator must not publish a config'
touch "$TEST_ZRAM_INSTALLED"
run_setup
[[ -f $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]] || fail 'retry after package installation must configure swap'

new_root copy-failure
if TEST_COPY_FAIL=1 run_setup; then fail 'copy failure must fail first installation'; fi
[[ ! -e $OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf ]] || fail 'partial default must never become live configuration'
[[ -z $(find "$OMARCHY_ZRAM_ROOT" -name '.omarchy-zram-*' -print) ]] || fail 'failed staging must clean its temporary file'
run_setup
cmp "$OMARCHY_PATH/default/systemd/zram-generator.conf.d/90-omarchy.conf" "$OMARCHY_ZRAM_ROOT/etc/systemd/zram-generator.conf" || fail 'copy retry must publish the complete default'
! grep -q 'systemctl' "$TEST_ZRAM_CALLS" || fail 'fresh setup must not control the running manager'
pass 'package and partial-copy failures propagate and remain retryable'

generator=/usr/lib/systemd/system-generators/zram-generator
if [[ -x $generator ]]; then
  new_root generator
  mkdir -p "$OMARCHY_ZRAM_ROOT/proc" "$work/generated"
  printf 'MemTotal: 8388608 kB\n' >"$OMARCHY_ZRAM_ROOT/proc/meminfo"
  : >"$OMARCHY_ZRAM_ROOT/proc/cmdline"
  ZRAM_GENERATOR_ROOT="$OMARCHY_ZRAM_ROOT" "$generator" "$work/generated"
  [[ ! -e $work/generated/dev-zram0.swap ]] || fail 'unconfigured generator should have no device'
  run_setup
  ZRAM_GENERATOR_ROOT="$OMARCHY_ZRAM_ROOT" "$generator" "$work/generated"
  [[ -f $work/generated/dev-zram0.swap && -L $work/generated/swap.target.wants/dev-zram0.swap ]] || fail 'fresh setup must produce a swap.target device on next boot'
  grep -Fx 'Requires=systemd-zram-setup@zram0.service' "$work/generated/dev-zram0.swap" >/dev/null || fail 'generated swap must depend on device setup'
  pass 'real native generator consumes the fresh-install configuration'
else
  pass 'zram-generator unavailable; native generator coverage skipped'
fi
