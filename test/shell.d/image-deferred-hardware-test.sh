#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Root never reads the fixture root, so as root the build and first boot below
# would act on this machine. A skip is a pass.
if (( EUID == 0 )); then
  pass "running as root, where image setup ignores fixture roots; skipping"
  exit 0
fi

umask 022
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

unit_name=omarchy-provision-hardware.service
unit_source="$ROOT/install/provisioning/$unit_name"

# omarchy-apply-hardware refuses anyone but root, and root never reads the
# fixture root. Run a copy whose only change is that check, so a normal user
# can build an image into a fixture root.
apply_hardware="$test_tmp/omarchy-apply-hardware"
sed 's/^if (( EUID != 0 )); then$/if false; then/' "$ROOT/bin/omarchy-apply-hardware" >"$apply_hardware"
chmod +x "$apply_hardware"
grep -q '^if false; then$' "$apply_hardware" || fail "the test copy of omarchy-apply-hardware drops only its root check"

# Commands a hardware leaf would reach for. Any call means a leaf ran.
stub_bin="$test_tmp/stub-bin"
mkdir -p "$stub_bin"
for command in sudo pacman systemctl lspci omarchy-pkg-add omarchy-hw-apple-silicon omarchy-mac-setup-system modinfo; do
  cat >"$stub_bin/$command" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$LEAF_CALLS"
exit 1
SH
done
stub_rebuild() {
  cat >"$stub_bin/$1" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$REBUILDS"
SH
  chmod +x "$stub_bin/$1"
}
stub_rebuild mkinitcpio
chmod +x "$stub_bin"/*
export LEAF_CALLS="$test_tmp/leaf-calls" REBUILDS="$test_tmp/rebuilds"

fake_platform "$test_tmp/hw" apple-silicon
base_path="$test_tmp/hw/bin:$stub_bin:$ROOT/bin:/usr/local/bin:/usr/bin:/bin"

# An Omarchy tree whose hardware setup is three leaves that log their runs.
# Leaves a and b write initramfs drop-ins; b then fails while $FAIL_B exists.
fixture="$test_tmp/omarchy"
mkdir -p "$fixture/install/helpers" "$fixture/install/provisioning" "$fixture/install/hardware/apple" "$fixture/bin"
cp "$ROOT/install/helpers/logging.sh" "$ROOT/install/helpers/image-target.sh" "$fixture/install/helpers/"
cp "$unit_source" "$fixture/install/provisioning/"
cat >"$fixture/install/hardware/all.sh" <<'SH'
run_logged "$OMARCHY_INSTALL/hardware/a.sh"
run_logged "$OMARCHY_INSTALL/hardware/apple/b.sh"
run_logged "$OMARCHY_INSTALL/hardware/c.sh"
SH
cat >"$fixture/install/hardware/a.sh" <<'SH'
printf 'a user=%s path=%s\n' "${OMARCHY_INSTALL_USER-unset}" "$OMARCHY_PATH" >>"$RUNS"
mkdir -p "$OMARCHY_IMAGE_ROOT/etc/mkinitcpio.conf.d"
echo 'MODULES+=(a)' >"$OMARCHY_IMAGE_ROOT/etc/mkinitcpio.conf.d/a.conf"
SH
cat >"$fixture/install/hardware/apple/b.sh" <<'SH'
mkdir -p "$OMARCHY_IMAGE_ROOT/etc/mkinitcpio.conf.d"
echo 'MODULES+=(b)' >"$OMARCHY_IMAGE_ROOT/etc/mkinitcpio.conf.d/b.conf"
[[ ! -e $FAIL_B ]] || return 1
echo b >>"$RUNS"
SH
cat >"$fixture/install/hardware/c.sh" <<'SH'
echo c >>"$RUNS"
SH
export RUNS="$test_tmp/runs" FAIL_B="$test_tmp/fail-b"

new_root() {
  local root="$test_tmp/root-$1"
  rm -rf "$root"
  mkdir -p "$root/var/log"
  printf '%s\n' "$root"
}

write_manifest() {
  local root=$1 body=${2:-$'format=1\nplatform=apple-silicon\n'}
  mkdir -p "$root/var/lib/omarchy/image"
  chmod 0755 "$root/var/lib/omarchy/image"
  printf '%s' "$body" >"$root/var/lib/omarchy/image/target"
  chmod 0644 "$root/var/lib/omarchy/image/target"
}

build() {
  local root=$1 omarchy=${2:-$fixture}
  OMARCHY_IMAGE_ROOT="$root" OMARCHY_PATH="$omarchy" OMARCHY_INSTALL_LOG_FILE="$root/var/log/omarchy-install.log" \
    PATH="$base_path" "$apply_hardware" --defer-provisioning
}

first_boot() {
  local root=$1
  OMARCHY_IMAGE_ROOT="$root" OMARCHY_PATH="$fixture" OMARCHY_PROC_ROOT="$test_tmp/hw/proc" \
    PATH="$base_path" "$ROOT/bin/omarchy-provision-hardware"
}

reset_logs() {
  rm -f "$RUNS" "$LEAF_CALLS" "$REBUILDS" "$FAIL_B"
}

queue_of() {
  cat "$1/var/lib/omarchy/image/deferred-steps"
}

# --- The build ---------------------------------------------------------------

# The real hardware setup: every leaf is queued in order and none of them runs.
reset_logs
root=$(new_root real)
write_manifest "$root"
output=$(build "$root" "$ROOT") || fail "an image build defers the real hardware setup" "$output"
expected=$(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(hardware/[^"]*\)"$|install/\1|p' "$ROOT/install/hardware/all.sh")
[[ -n $expected && $(queue_of "$root") == "$expected" ]] ||
  fail "an image build queues every hardware leaf in order" "expected:
$expected
queued:
$(queue_of "$root")"
[[ ! -e $LEAF_CALLS ]] || fail "an image build runs no hardware leaf" "$(cat "$LEAF_CALLS")"
[[ $output == *"Image build for apple-silicon: deferred $(wc -l <<<"$expected") hardware steps to first boot"* ]] ||
  fail "an image build reports what it deferred" "$output"
pass "an image build queues every hardware leaf in order and runs none of them"

[[ $(<"$unit_source") == "$(<"$root/etc/systemd/system/$unit_name")" ]] ||
  fail "an image build installs the first-boot hardware service"
[[ $(readlink "$root/etc/systemd/system/multi-user.target.wants/$unit_name") == "/etc/systemd/system/$unit_name" ]] ||
  fail "an image build enables the first-boot hardware service"
[[ -f $root/var/lib/omarchy/image/target && ! -e $root/var/lib/omarchy/image/target.booted ]] ||
  fail "an image build leaves its manifest for the first boot"
[[ $(stat -c '%a' "$root/var/lib/omarchy/image/deferred-steps") == "644" ]] ||
  fail "the queue is readable and only its owner writes it"
pass "an image build arms the first-boot hardware service"

before=$(queue_of "$root")
build "$root" "$ROOT" >/dev/null || fail "an image build can run hardware setup again"
[[ $(queue_of "$root") == "$before" ]] || fail "running hardware setup again in the build queues the same steps"
pass "running hardware setup again in the build queues the same steps"

# Without a manifest nothing is deferred: the leaves run as they always did.
reset_logs
root=$(new_root live)
build "$root" >/dev/null || fail "hardware setup without a manifest runs"
[[ $(cat "$RUNS") == $'a user= path='"$fixture"$'\nb\nc' ]] || fail "hardware setup without a manifest runs every leaf" "$(cat "$RUNS")"
[[ ! -e $root/var/lib/omarchy/image && ! -e $root/etc/systemd/system/$unit_name ]] ||
  fail "hardware setup without a manifest queues and arms nothing"
pass "hardware setup without a manifest runs every leaf and defers nothing"

# Hardware setup that has to wait for a first boot in progress decides only
# once it has the lock: by then the manifest is retired and the leaves run here.
reset_logs
root=$(new_root race)
write_manifest "$root"
(
  exec {lock}>>"$root/var/lib/omarchy/image/lock"
  flock "$lock"
  touch "$test_tmp/locked"
  until [[ -e $test_tmp/release || ! -d $test_tmp ]]; do sleep 0.1; done
  mv "$root/var/lib/omarchy/image/target" "$root/var/lib/omarchy/image/target.booted"
) &
first_boot_pid=$!
until [[ -e $test_tmp/locked ]]; do sleep 0.1; done
build "$root" >/dev/null &
setup_pid=$!
sleep 1
kill -0 "$setup_pid" 2>/dev/null || fail "hardware setup waits while a first boot holds the lock"
touch "$test_tmp/release"
wait "$first_boot_pid"
wait "$setup_pid" || fail "hardware setup runs after waiting for a first boot"
[[ $(cat "$RUNS") == $'a user= path='"$fixture"$'\nb\nc' && ! -e $root/var/lib/omarchy/image/deferred-steps ]] ||
  fail "hardware setup that waited for a first boot runs its leaves instead of queueing them"
pass "hardware setup waits for a first boot in progress and then runs on the machine"

# A manifest that is not unambiguously root's own stops hardware setup outright.
check_refused() {
  local description=$1 root=$2
  reset_logs
  if build "$root" >/dev/null 2>&1; then
    fail "hardware setup refuses $description"
  fi
  [[ ! -e $RUNS && ! -e $root/var/lib/omarchy/image/deferred-steps && ! -e $root/etc/systemd/system/$unit_name ]] ||
    fail "hardware setup refuses $description without running, queueing or arming anything"
  pass "hardware setup refuses $description"
}

root=$(new_root format)
write_manifest "$root" $'format=2\nplatform=apple-silicon\n'
check_refused "a manifest of an unknown format" "$root"

root=$(new_root platform)
write_manifest "$root" $'format=1\nplatform=apple\n'
check_refused "a manifest naming an unknown platform" "$root"

root=$(new_root malformed)
write_manifest "$root" $'format=1\napple-silicon\n'
check_refused "a malformed manifest" "$root"

root=$(new_root writable)
write_manifest "$root"
chmod 0666 "$root/var/lib/omarchy/image/target"
check_refused "a manifest others can write" "$root"

root=$(new_root writable-dir)
write_manifest "$root"
chmod 0777 "$root/var/lib/omarchy/image"
check_refused "a manifest in a directory others can write" "$root"

root=$(new_root symlink)
write_manifest "$root"
mv "$root/var/lib/omarchy/image/target" "$root/var/lib/omarchy/image/real-target"
ln -s real-target "$root/var/lib/omarchy/image/target"
check_refused "a symlinked manifest" "$root"

# --- The first boot ----------------------------------------------------------

reset_logs
root=$(new_root fresh)
write_manifest "$root"
build "$root" >/dev/null || fail "the fixture image builds"
[[ $(queue_of "$root") == $'install/hardware/a.sh\ninstall/hardware/apple/b.sh\ninstall/hardware/c.sh' ]] ||
  fail "the fixture image queues its three leaves" "$(queue_of "$root")"

output=$(first_boot "$root") || fail "the first boot finishes the deferred hardware setup" "$output"
[[ $(cat "$RUNS") == $'a user= path='"$fixture"$'\nb\nc' ]] ||
  fail "the first boot runs each deferred leaf once, in order, with no install user" "$(cat "$RUNS")"
[[ $output == *"First boot of an image built for apple-silicon, on apple-silicon hardware"* ]] ||
  fail "the first boot reports the image target and the live platform" "$output"
[[ ! -e $root/var/lib/omarchy/image/target && -f $root/var/lib/omarchy/image/target.booted ]] ||
  fail "the first boot retires the build manifest"
[[ ! -e $root/var/lib/omarchy/image/deferred-steps ]] || fail "the first boot empties the queue"
[[ ! -L $root/etc/systemd/system/multi-user.target.wants/$unit_name && -f $root/etc/systemd/system/$unit_name ]] ||
  fail "the first boot disables its service and keeps the unit, so a start job already queued is skipped rather than failed"
[[ $(cat "$REBUILDS") == "mkinitcpio -P" ]] ||
  fail "the first boot rebuilds the initramfs once after a leaf changed it" "$(cat "$REBUILDS" 2>/dev/null)"
[[ ! -e $root/var/lib/omarchy/image/initramfs-inputs ]] || fail "the first boot clears the rebuild it owed"
grep -q 'Completed: .*/install/hardware/c.sh' "$root/var/log/omarchy-install.log" ||
  fail "the first boot logs each step to the install log"
pass "the first boot runs the deferred hardware setup with no command from the owner"

rm -f "$RUNS" "$REBUILDS"
output=$(first_boot "$root") || fail "running the first-boot hardware setup again succeeds"
[[ -z $output && ! -e $RUNS && ! -e $REBUILDS ]] ||
  fail "running the first-boot hardware setup again does nothing" "$output"
pass "running the first-boot hardware setup again does nothing"

# The live platform is asked once the manifest is retired, so it is the
# hardware's even where the detector cannot tell a booted root (this fixture
# runs no systemd): an Apple image under VM acceptance boots on generic aarch64.
fake_platform "$test_tmp/vm" generic-aarch64
reset_logs
root=$(new_root vm)
write_manifest "$root"
build "$root" >/dev/null || fail "the fixture image builds for a VM boot"
output=$(OMARCHY_IMAGE_ROOT="$root" OMARCHY_PATH="$fixture" OMARCHY_PROC_ROOT="$test_tmp/vm/proc" \
  PATH="$test_tmp/vm/bin:$stub_bin:$ROOT/bin:/usr/local/bin:/usr/bin:/bin" "$ROOT/bin/omarchy-provision-hardware") ||
  fail "the first boot on other hardware finishes" "$output"
[[ $output == *"First boot of an image built for apple-silicon, on generic-aarch64 hardware"* ]] ||
  fail "the first boot reports the hardware it runs on, not the image target" "$output"
pass "the first boot reports the hardware it runs on, not the image target"

# A failed step stays queued with everything after it; the next boot resumes there.
reset_logs
root=$(new_root resume)
write_manifest "$root"
build "$root" >/dev/null || fail "the fixture image builds"
touch "$FAIL_B"
status=0
output=$(first_boot "$root" 2>&1) || status=$?
(( status == 75 )) || fail "a failed step exits 75, so a platform first boot can tell it from a refusal" "status $status: $output"
[[ $output == *"Deferred hardware step failed: install/hardware/apple/b.sh"* ]] ||
  fail "the first boot names the failed step" "$output"
[[ $(cat "$RUNS") == "a user= path=$fixture" ]] || fail "the first boot stops at the failed step" "$(cat "$RUNS")"
[[ $(queue_of "$root") == $'install/hardware/apple/b.sh\ninstall/hardware/c.sh' ]] ||
  fail "the failed step and those after it stay queued" "$(queue_of "$root")"
[[ -f $root/var/lib/omarchy/image/target.booted && ! -e $root/var/lib/omarchy/image/target ]] ||
  fail "the machine stops being an image build once its first boot starts"
[[ -L $root/etc/systemd/system/multi-user.target.wants/$unit_name && -e $root/var/lib/omarchy/image/initramfs-inputs && ! -e $REBUILDS ]] ||
  fail "the service stays armed and the initramfs rebuild stays owed until the queue is empty"
pass "a failed step stays queued with the steps after it"

rm -f "$FAIL_B" "$RUNS"
stub_rebuild limine-mkinitcpio
output=$(first_boot "$root") || fail "the next boot finishes the deferred hardware setup" "$output"
[[ $(cat "$RUNS") == $'b\nc' ]] || fail "the next boot resumes at the failed step" "$(cat "$RUNS")"
[[ $(cat "$REBUILDS") == "limine-mkinitcpio " ]] ||
  fail "the next boot rebuilds the initramfs the earlier boot owed, through Limine when present" "$(cat "$REBUILDS" 2>/dev/null)"
[[ ! -e $root/var/lib/omarchy/image/deferred-steps && ! -L $root/etc/systemd/system/multi-user.target.wants/$unit_name ]] ||
  fail "the next boot disarms the service"
pass "the next boot resumes at the failed step and finishes"

# The step that changed the initramfs inputs is the one that failed: its rerun
# changes nothing more, and the rebuild is still owed.
reset_logs
rm -f "$stub_bin/limine-mkinitcpio"
root=$(new_root rebuild)
write_manifest "$root"
build "$root" >/dev/null || fail "the fixture image builds"
printf '%s\n' install/hardware/apple/b.sh install/hardware/c.sh >"$root/var/lib/omarchy/image/deferred-steps"
touch "$FAIL_B"
first_boot "$root" >/dev/null 2>&1 && fail "the first boot reports the failed step"
rm -f "$FAIL_B"
first_boot "$root" >/dev/null || fail "the next boot finishes the deferred hardware setup"
[[ $(cat "$RUNS") == $'b\nc' && $(cat "$REBUILDS" 2>/dev/null) == "mkinitcpio -P" ]] ||
  fail "a step that changed the initramfs and then failed still gets it rebuilt" "$(cat "$REBUILDS" 2>/dev/null)"
pass "a step that changed the initramfs and then failed still gets it rebuilt"

# Images ship no sync databases, so a step that installs a package fails until
# they are fetched. Offline the fetch fails too and the step stays queued; a
# later boot with the network fetches them once and retries the step.
if command -v pacman-conf >/dev/null; then
  sync_bin="$test_tmp/sync-bin"
  mkdir -p "$sync_bin"
  cat >"$sync_bin/pacman" <<'SH'
#!/bin/bash
sync=$OMARCHY_IMAGE_ROOT/var/lib/pacman/sync
case $1 in
  -Sy)
    echo "pacman -Sy" >>"$SYNCS"
    [[ ! -e $OFFLINE ]] || exit 1
    mkdir -p "$sync" && touch "$sync/core.db" "$sync/omarchy.db"
    ;;
  -S)
    [[ -f $sync/core.db && -f $sync/omarchy.db ]] || { echo "error: target not found: ${*: -1}" >&2; exit 1; }
    echo "installed ${*: -1}" >>"$RUNS"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$sync_bin/pacman"
  echo 'pacman -S --noconfirm --needed vulkan-asahi' >"$fixture/install/hardware/pkg.sh"
  export SYNCS="$test_tmp/syncs" OFFLINE="$test_tmp/offline"

  sync_boot() {
    OMARCHY_IMAGE_ROOT="$1" OMARCHY_PATH="$fixture" OMARCHY_PROC_ROOT="$test_tmp/hw/proc" \
      PATH="$sync_bin:$base_path" "$ROOT/bin/omarchy-provision-hardware"
  }

  reset_logs
  rm -f "$SYNCS"
  root=$(new_root sync)
  write_manifest "$root"
  build "$root" >/dev/null || fail "the fixture image builds"
  mkdir -p "$root/etc"
  printf '[options]\nArchitecture = auto\n\n[core]\nServer = https://mirror.invalid/$arch/$repo\n\n[omarchy]\nServer = https://pkgs.invalid/$arch\n' \
    >"$root/etc/pacman.conf"
  printf '%s\n' install/hardware/c.sh >"$root/var/lib/omarchy/image/deferred-steps"
  sync_boot "$root" >/dev/null || fail "a first boot whose steps need no package finishes offline"
  [[ ! -e $SYNCS ]] || fail "a first boot whose steps succeed fetches no package databases"
  pass "a first boot whose steps succeed fetches no package databases"

  rm -f "$RUNS"
  printf '%s\n' install/hardware/pkg.sh install/hardware/c.sh >"$root/var/lib/omarchy/image/deferred-steps"
  touch "$OFFLINE"
  status=0
  output=$(sync_boot "$root" 2>&1) || status=$?
  (( status == 75 )) || fail "an offline step that needs a package exits 75" "status $status: $output"
  [[ $(cat "$SYNCS") == "pacman -Sy" && ! -e $RUNS ]] ||
    fail "an offline first boot tries the package databases once and stops at the step" "$(cat "$SYNCS" "$RUNS" 2>/dev/null)"
  [[ $(queue_of "$root") == $'install/hardware/pkg.sh\ninstall/hardware/c.sh' ]] ||
    fail "the step that needs a package stays queued offline" "$(queue_of "$root")"
  pass "offline, a step that needs a package stays queued"

  rm -f "$OFFLINE"
  output=$(sync_boot "$root") || fail "a later boot with the network finishes the deferred hardware setup" "$output"
  [[ $(cat "$SYNCS") == $'pacman -Sy\npacman -Sy' && $(cat "$RUNS") == $'installed vulkan-asahi\nc' ]] ||
    fail "a later boot fetches the package databases once and retries the step" "$(cat "$SYNCS" "$RUNS" 2>/dev/null)"
  [[ $output == *"Fetching the package databases the image does not ship, then retrying install/hardware/pkg.sh"* ]] ||
    fail "a later boot says why it fetches the package databases" "$output"
  [[ ! -e $root/var/lib/omarchy/image/deferred-steps ]] || fail "a later boot with the network empties the queue"
  pass "a later boot with the network fetches the package databases once and finishes"

  rm -f "$RUNS"
  touch "$FAIL_B"
  printf '%s\n' install/hardware/apple/b.sh >"$root/var/lib/omarchy/image/deferred-steps"
  sync_boot "$root" >/dev/null 2>&1 && fail "a failing step with the package databases present still fails"
  [[ $(wc -l <"$SYNCS") == 2 ]] || fail "a step that fails with the package databases present fetches nothing" "$(cat "$SYNCS")"
  pass "a step that fails with the package databases present fetches nothing"
else
  pass "no pacman-conf here; skipping the package database fetch"
fi

# A leaf a later Omarchy no longer ships is dropped; a queue entry outside the
# hardware setup stops the run before anything runs.
reset_logs
root=$(new_root gone)
write_manifest "$root"
build "$root" >/dev/null || fail "the fixture image builds"
printf '%s\n' install/hardware/removed.sh install/hardware/c.sh >"$root/var/lib/omarchy/image/deferred-steps"
output=$(first_boot "$root") || fail "a step no longer shipped does not block the rest" "$output"
[[ $output == *"Skipping deferred hardware step install/hardware/removed.sh"* && $(cat "$RUNS") == "c" ]] ||
  fail "a step no longer shipped is skipped and the rest run" "$output"
pass "a deferred step Omarchy no longer ships is skipped"

for entry in /etc/passwd install/hardware/../../bin/x.sh install/login/sddm.sh; do
  reset_logs
  root=$(new_root unsafe)
  write_manifest "$root"
  build "$root" >/dev/null || fail "the fixture image builds"
  printf '%s\n' "$entry" install/hardware/c.sh >"$root/var/lib/omarchy/image/deferred-steps"
  status=0
  first_boot "$root" >/dev/null 2>&1 || status=$?
  (( status == 1 )) || fail "the first boot refuses the queue entry $entry with status 1, not a step failure's 75" "status $status"
  [[ ! -e $RUNS && $(head -n 1 "$root/var/lib/omarchy/image/deferred-steps") == "$entry" ]] ||
    fail "the first boot refuses the queue entry $entry before running anything"
done
pass "the first boot runs only hardware setup leaves from its queue"

reset_logs
root=$(new_root nothing)
output=$(first_boot "$root") || fail "the first-boot hardware setup succeeds with nothing deferred"
[[ -z $output && ! -e $root/var/lib/omarchy ]] || fail "the first-boot hardware setup does nothing with nothing deferred" "$output"
pass "with nothing deferred the first-boot hardware setup does nothing"

if env -u OMARCHY_IMAGE_ROOT OMARCHY_PATH="$fixture" PATH="$base_path" "$ROOT/bin/omarchy-provision-hardware" >/dev/null 2>&1; then
  fail "the first-boot hardware setup refuses a normal user"
fi
pass "the first-boot hardware setup refuses a normal user"

# The service fires on the queue this helper writes and hands the machine to
# owner setup and the login screen only after it.
grep -qx 'ConditionPathExists=/var/lib/omarchy/image/deferred-steps' "$unit_source" &&
  grep -qx 'ExecStart=/usr/bin/omarchy-provision-hardware' "$unit_source" &&
  grep -qx 'Before=omarchy-provision-owner.service display-manager.service' "$unit_source" &&
  grep -qx 'WantedBy=multi-user.target' "$unit_source" ||
  fail "the first-boot hardware service runs on the queue before owner setup and the login screen"
pass "the first-boot hardware service runs on the queue before owner setup and the login screen"

# --- Root ignores the fixture root ------------------------------------------

# As namespaced root the fixture root in the environment is ignored: the
# fixture image is not built into, and hardware setup runs as on any live system.
if [[ -e /var/lib/omarchy/image ]]; then
  pass "this machine keeps image state of its own; skipping the root override probe"
elif unshare --user --map-root-user true 2>/dev/null; then
  root_runner=(unshare --user --map-root-user)

  reset_logs
  root=$(new_root root-build)
  write_manifest "$root"
  OMARCHY_IMAGE_ROOT="$root" OMARCHY_PATH="$fixture" OMARCHY_INSTALL_LOG_FILE="$root/var/log/omarchy-install.log" \
    PATH="$base_path" "${root_runner[@]}" "$ROOT/bin/omarchy-apply-hardware" --defer-provisioning >/dev/null ||
    fail "root runs hardware setup with a fixture root in its environment"
  [[ $(cat "$RUNS") == $'a user= path='"$fixture"$'\nb\nc' && ! -e $root/var/lib/omarchy/image/deferred-steps ]] ||
    fail "root ignores a fixture manifest named by its environment"

  # Both commands take every path from the helper, which as root answers with
  # the live ones whatever the environment says.
  resolved=$(OMARCHY_IMAGE_ROOT="$root" "${root_runner[@]}" bash -c \
    'source "$1"; omarchy_image_init && printf "%s\n" "$omarchy_image_manifest" "$omarchy_image_queue" "$omarchy_image_systemd_dir"' \
    bash "$ROOT/install/helpers/image-target.sh") || fail "root resolves the image paths"
  [[ $resolved == $'/var/lib/omarchy/image/target\n/var/lib/omarchy/image/deferred-steps\n/etc/systemd/system' ]] ||
    fail "root resolves the live image paths whatever its environment names" "$resolved"
  pass "root ignores fixture roots in its environment"
else
  pass "no unprivileged user namespace; skipping the root override probe"
fi
