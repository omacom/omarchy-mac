#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/shell.d/base-test.sh"

require_command flock
require_command sha256sum
require_command git

harness="$ROOT/tools/acceptance/asahi-fresh"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# The runner reads its whole configuration from OMARCHY_VM_*; start clean.
unset "${!OMARCHY_VM_@}"

# The omarchy-mx-mac tree under test, reduced to the files the runner hands the
# guest, in a repository of its own so the run record can name its commit.
make_source_tree() {
  mkdir -p "$1/bin" "$1/install"
  echo "fresh installer $2" >"$1/bin/omarchy-install-asahi-fresh"
  echo "bundle updater $2" >"$1/bin/omarchy-update-asahi-bundle"
  echo 4.0.4-mac.1 >"$1/version"
  echo 'install.good|good' >"$1/install/optional-packages.tsv"
  echo install.good >"$1/install/optional-packages-aarch64-required"
  git -C "$1" init -q
  git -C "$1" add .
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -q -m "$2"
}
source_tree="$test_tmp/source"
make_source_tree "$source_tree" source
export OMARCHY_VM_SOURCE_DIR="$source_tree"

stub_bin="$test_tmp/bin"
state="$test_tmp/state"
evidence_root="$test_tmp/evidence"
mkdir -p "$stub_bin" "$test_tmp/home"
export TEST_STATE="$state" TEST_DOCKER_LOG="$test_tmp/docker.log" TEST_SSH_LOG="$test_tmp/ssh.log" TEST_SCP_LOG="$test_tmp/scp.log"
export TEST_BOOT_FILE="$test_tmp/boot-id" TEST_CONTAINERS="$test_tmp/containers"
# The host lock's real path is shared by everything on the machine; the test
# keeps its own so a VM run on the same host cannot interfere.
host_lock="$test_tmp/host.lock"
: >"$TEST_CONTAINERS"

# docker: the container sees the state directory as /work. A created container
# gets the ID cid-<name>, written to --cidfile and listed in TEST_CONTAINERS
# until it is removed. start-vm lays out the run directory the way the real one
# does; the monitor takes a screendump.
cat >"$stub_bin/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DOCKER_LOG"
host_path() { printf '%s\n' "${1/#\/work/$TEST_STATE}"; }
case $1 in
  ps)
    if [[ $2 == --all ]]; then
      [[ ${TEST_DOCKER_PS_FAILS:-0} == 0 ]] || exit 1
      wanted=${!#}
      grep -Fx -- "${wanted#id=}" "$TEST_CONTAINERS" || true
      exit 0
    fi
    printf '%s' "${TEST_DOCKER_PS:-}"
    ;;
  container) [[ ${3:-} == "${TEST_DOCKER_EXISTING:-}" ]] || exit 1 ;;
  rm)
    if [[ -n ${TEST_BLOCK_RM:-} ]]; then
      touch "$TEST_BLOCK_DIR/rm-blocked"
      while [[ ! -e $TEST_BLOCK_DIR/rm-release ]]; do sleep 0.05; done
    fi
    [[ ${TEST_DOCKER_RM_FAILS:-0} == 0 ]] || exit 1
    [[ ${TEST_DOCKER_RM_IGNORED:-0} == 0 ]] || exit 0
    grep -Fvx "$3" "$TEST_CONTAINERS" >"$TEST_CONTAINERS.new" || true
    mv "$TEST_CONTAINERS.new" "$TEST_CONTAINERS"
    ;;
  run)
    if [[ " $* " == *" --rm "* ]]; then
      target=${!#}
      rm -rf "$TEST_STATE/runs/${target#/runs/}"
      exit 0
    fi
    # Losing a name race creates nothing; failing to start leaves the container.
    [[ ${TEST_DOCKER_RUN_FAILS:-} != conflict ]] || exit 125
    while (( $# > 0 )); do
      case $1 in
        --cidfile) cid_file=$2; shift ;;
        --name) name=$2; shift ;;
      esac
      shift
    done
    echo "cid-$name" >"$cid_file"
    echo "cid-$name" >>"$TEST_CONTAINERS"
    [[ ${TEST_DOCKER_RUN_FAILS:-} != start ]] || exit 125
    ;;
  exec)
    shift
    run_dir=""
    while [[ $1 == -* ]]; do
      if [[ $1 == -e ]]; then
        [[ $2 != OMARCHY_VM_RUN_DIR=* ]] || run_dir=${2#*=}
        shift
      fi
      shift
    done
    shift
    case $1 in
      */start-vm)
        run_dir=$(host_path "$run_dir")
        mkdir -p "$run_dir"
        head -c 4096 /dev/zero >"$run_dir/disk.qcow2"
        echo "serial console" >"$run_dir/serial.log"
        ;;
      socat)
        command=$(cat)
        printf 'monitor %s\n' "$command" >>"$TEST_DOCKER_LOG"
        if [[ $command == "screendump "* ]]; then
          echo P6 >"$(host_path "${command#screendump }")"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH

# ssh: every guest stage prints one line and fails only when asked to.
cat >"$stub_bin/ssh" <<'SH'
#!/bin/bash
while (( $# > 0 )) && [[ $1 != root@127.0.0.1 ]]; do shift; done
shift
command="$*"
printf '%s\n' "$command" >>"$TEST_SSH_LOG"
case $command in
  true) exit 0 ;;
  "cat /proc/sys/kernel/random/boot_id") cat "$TEST_BOOT_FILE" 2>/dev/null || echo boot-1; exit 0 ;;
  "systemctl reboot --no-block") echo "boot-$EPOCHREALTIME" >"$TEST_BOOT_FILE"; exit 0 ;;
esac
stage=${!#}
stage=${stage##*/omarchy-vm-}
echo "$stage stage output"
if [[ $stage == "${TEST_BLOCK_STAGE:-}" ]]; then
  touch "$TEST_BLOCK_DIR/blocked"
  while [[ ! -e $TEST_BLOCK_DIR/release ]]; do sleep 0.05; done
fi
[[ $stage != "${TEST_FAIL_STAGE:-}" ]]
SH

cat >"$stub_bin/scp" <<'SH'
#!/bin/bash
printf '%s\n' "${@: -2:1}" >>"$TEST_SCP_LOG"
if [[ ${@: -2:1} == root@127.0.0.1:/root/optional-package-logs ]]; then
  mkdir -p "${!#}/optional-package-logs"
  echo "transaction log" >"${!#}/optional-package-logs/install-good.log"
fi
exit 0
SH

cat >"$stub_bin/ssh-keygen" <<'SH'
#!/bin/bash
while [[ $1 != -f ]]; do shift; done
echo key >"$2"
echo key.pub >"$2.pub"
SH

stable_tag=asahi-packages-stable-$(printf 'a%.0s' {1..40})
cat >"$stub_bin/curl" <<SH
#!/bin/bash
case \${!#} in
  */pointers/asahi-packages-channel) printf 'format=1\nsequence=7\ntag=asahi-packages-channel-7' ;;
  */asahi-packages-channel-7/asahi-packages-channel) printf 'format=1\nstable_tag=$stable_tag\n' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$stub_bin"/*

run_harness() {
  rm -f "$TEST_BOOT_FILE" "$TEST_DOCKER_LOG" "$TEST_SSH_LOG" "$TEST_SCP_LOG"
  : >"$TEST_DOCKER_LOG"
  set +e
  PATH="$stub_bin:$PATH" HOME="${TEST_HOME:-$test_tmp/home}" OMARCHY_VM_STATE_DIR="${TEST_STATE_DIR:-$state}" \
    OMARCHY_VM_HOST_LOCK="$host_lock" "$harness/run" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
  status=$?
  set -e
  output="$(<"$test_tmp/out")"$'\n'"$(<"$test_tmp/err")"
}

lease_is_free() {
  flock -n "$host_lock" true && flock -n "$state/lease" true
}

evidence_verifies() {
  (cd "$1" && sha256sum --check --strict --quiet SHA256SUMS)
}

# --- A passing run -----------------------------------------------------------

# A run directory from before per-run directories must survive a new run.
mkdir -p "$state/run"
echo legacy >"$state/run/disk.qcow2"

OMARCHY_VM_RUN_ID=pass-1 run_harness --optional-packages
(( status == 0 )) || fail "a passing VM run succeeds" "$output"
evidence="$test_tmp/home/vm-evidence/pass-1"
[[ -d $evidence && ! -e $evidence.partial ]] || fail "a passing run exports its evidence to ~/vm-evidence/<run-id>" "$output"
for file in install.log serial.log verify.log optional-packages.log rerun.log desktop.ppm optional-package-logs/install-good.log; do
  [[ -s $evidence/$file ]] || fail "the evidence holds $file" "$(ls -R "$evidence")"
done
[[ ! -e $evidence/candidate-repository.log ]] || fail "a run without a candidate exports no candidate log"
[[ $(grep -c . "$evidence/SHA256SUMS") == 7 ]] || fail "the checksums cover every exported file" "$(<"$evidence/SHA256SUMS")"
evidence_verifies "$evidence" || fail "the exported evidence verifies against its checksums"
grep -Fxq 'install stage output' "$evidence/install.log" || fail "the evidence holds the run's own install log"
grep -Fxq 'status=passed' "$evidence/run.txt" || fail "the run record says the run passed" "$(<"$evidence/run.txt")"
grep -Fxq "install_log_sha256=$(sha256sum "$evidence/install.log" | cut -d' ' -f1)" "$evidence/run.txt" ||
  fail "the run record carries the acceptance-record log hashes" "$(<"$evidence/run.txt")"
grep -Fxq "serial_log_sha256=$(sha256sum "$evidence/serial.log" | cut -d' ' -f1)" "$evidence/run.txt" ||
  fail "the run record carries the serial log hash"
grep -Fxq "expected_repository=$stable_tag" "$evidence/run.txt" || fail "the run record names the resolved stable set"
for key in candidate_tag candidate_sha256 runtime_manifest_sha256 runtime_source; do
  [[ $(grep -c "^$key=" "$evidence/run.txt") == 1 ]] || fail "the run record names its $key once" "$(<"$evidence/run.txt")"
done
[[ ! -e $state/runs/pass-1 ]] || fail "a passing run deletes its run directory once the evidence verifies"
[[ $(<"$state/run/disk.qcow2") == legacy ]] || fail "a run never deletes an earlier run's directory"
[[ $output == *"$state/run"* ]] || fail "a run lists the run directories still on disk" "$output"
pass "a passing run exports verified evidence, then deletes its run directory"

grep -Eq '^run -d --cidfile [^ ]+ --name omarchy-asahi-fresh-vm-pass-1 --label org.omarchy.vm-harness=asahi-fresh --label org.omarchy.vm-run-id=pass-1 ' "$TEST_DOCKER_LOG" ||
  fail "each run gets its own container" "$(<"$TEST_DOCKER_LOG")"
grep -Fxq 'rm -f cid-omarchy-asahi-fresh-vm-pass-1' "$TEST_DOCKER_LOG" || fail "a run removes its own container by its ID"
[[ $(grep -c '^rm ' "$TEST_DOCKER_LOG") == 1 ]] || fail "a run removes no other container" "$(<"$TEST_DOCKER_LOG")"
[[ ! -s $TEST_CONTAINERS ]] || fail "a finished run leaves no container behind" "$(<"$TEST_CONTAINERS")"
grep -Fq 'exec -e OMARCHY_VM_MEMORY_MB=6144 -e OMARCHY_VM_CPUS=8 -e OMARCHY_VM_RUN_DIR=/work/runs/pass-1 cid-omarchy-asahi-fresh-vm-pass-1 /usr/local/lib/omarchy-asahi-vm/start-vm' "$TEST_DOCKER_LOG" ||
  fail "the guest keeps 8 vCPUs and 6 GiB and boots from the run's own directory" "$(<"$TEST_DOCKER_LOG")"
grep -Fxq 'exec -e ARCHARM_MIRROR_URL=https://downloads.aicodelabs.com.au/mirror/alarm/20260906/$repo/os/$arch cid-omarchy-asahi-fresh-vm-pass-1 /usr/local/lib/omarchy-asahi-vm/build-base' "$TEST_DOCKER_LOG" ||
  fail "the guest takes its packages from the dated R2 snapshot by default" "$(<"$TEST_DOCKER_LOG")"
lease_is_free || fail "a finished run releases the lease"
grep -q "^run_id=pass-1 pid=[0-9]* user=$(id -un) state=$state started_at=" "$host_lock" ||
  fail "the host lock names the run that held it" "$(<"$host_lock")"
pass "each run has its own container and directory, and the defaults stay 8 vCPUs and the R2 snapshot"

for file in bin/omarchy-install-asahi-fresh bin/omarchy-update-asahi-bundle install/optional-packages.tsv install/optional-packages-aarch64-required; do
  grep -Fxq "$source_tree/$file" "$TEST_SCP_LOG" || fail "the guest gets $file from the tree under test" "$(<"$TEST_SCP_LOG")"
done
grep -Fq ' OMARCHY_VM_STABLE_VERSION=4.0.4-mac.1 ' "$TEST_SSH_LOG" || fail "the guest expects the product version of the tree under test" "$(<"$TEST_SSH_LOG")"
grep -Fxq "source_commit=$(git -C "$source_tree" rev-parse HEAD)" "$test_tmp/home/vm-evidence/pass-1/run.txt" ||
  fail "the run record names the commit of the tree under test" "$(<"$test_tmp/home/vm-evidence/pass-1/run.txt")"
grep -Fxq "harness_commit=$(git -C "$harness" rev-parse HEAD 2>/dev/null || true)" "$test_tmp/home/vm-evidence/pass-1/run.txt" ||
  fail "the run record names the harness commit" "$(<"$test_tmp/home/vm-evidence/pass-1/run.txt")"
pass "the guest runs the tree under test, and the run record names its commit and the harness's"

# Generated run IDs never repeat, so neither do container names.
run_harness
(( status == 0 )) || fail "a run with a generated ID succeeds" "$output"
first=$(sed -n 's/^run -d --cidfile [^ ]* --name \([^ ]*\) .*/\1/p' "$TEST_DOCKER_LOG")
run_harness
(( status == 0 )) || fail "a second run with a generated ID succeeds" "$output"
second=$(sed -n 's/^run -d --cidfile [^ ]* --name \([^ ]*\) .*/\1/p' "$TEST_DOCKER_LOG")
[[ $first == omarchy-asahi-fresh-vm-2* && $second == omarchy-asahi-fresh-vm-2* && $first != "$second" ]] ||
  fail "generated run IDs give distinct container names" "$first $second"
[[ -d $test_tmp/home/vm-evidence/${first#omarchy-asahi-fresh-vm-} && -d $test_tmp/home/vm-evidence/${second#omarchy-asahi-fresh-vm-} ]] ||
  fail "every run keeps its own evidence"
pass "generated run IDs give every run its own container and evidence"

OMARCHY_VM_RUN_ID=pass-1 run_harness
(( status != 0 )) && [[ $output == *'Run pass-1 already has a run or evidence directory'* ]] ||
  fail "a reused run ID is refused" "$output"
[[ ! -s $TEST_DOCKER_LOG ]] || fail "a refused run starts nothing" "$(<"$TEST_DOCKER_LOG")"
TEST_DOCKER_EXISTING=omarchy-asahi-fresh-vm-taken OMARCHY_VM_RUN_ID=taken run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *'Container omarchy-asahi-fresh-vm-taken already exists'* ]] ||
  fail "a run whose container name is taken is refused" "$output"
! grep -Eq '^(rm|run|build) ' "$TEST_DOCKER_LOG" || fail "a run never removes a container it did not create" "$(<"$TEST_DOCKER_LOG")"
pass "a reused run ID is refused before anything starts"

# Evidence inside the state directory could be deleted with the run directory,
# whichever path names it.
mkdir -p "$state/runs"
ln -s "$state/runs" "$test_tmp/runs-alias"
for destination in "$state" "$state/runs" "$state/runs/inside/evidence" "$test_tmp/runs-alias" "$test_tmp/runs-alias/../cache"; do
  OMARCHY_VM_RUN_ID=inside run_harness --evidence-dir "$destination"
  (( status != 0 )) && [[ $output == *"is inside the VM state directory $state"* ]] ||
    fail "evidence inside the state directory is refused: $destination" "$output"
  [[ ! -s $TEST_DOCKER_LOG && ! -e $state/runs/inside ]] || fail "a refused evidence directory starts nothing: $destination"
done
OMARCHY_VM_EVIDENCE_DIR="$test_tmp/runs-alias" OMARCHY_VM_RUN_ID=inside run_harness
(( status != 0 )) && [[ $output == *'is inside the VM state directory'* ]] ||
  fail "OMARCHY_VM_EVIDENCE_DIR inside the state directory is refused" "$output"
(cd "$test_tmp" && OMARCHY_VM_RUN_ID=relative run_harness --evidence-dir relative-evidence)
[[ -f $test_tmp/relative-evidence/relative/run.txt ]] || fail "a relative evidence directory resolves from the caller's directory"
pass "evidence inside the state directory is refused, symlinks included"

# A docker run that loses the name to another run creates nothing, so the run
# must not remove anything; one that created its container but could not start
# it removes exactly that container.
echo cid-omarchy-asahi-fresh-vm-race >"$TEST_CONTAINERS"
TEST_DOCKER_RUN_FAILS=conflict OMARCHY_VM_RUN_ID=race run_harness --evidence-dir "$evidence_root"
(( status != 0 )) || fail "a run whose docker run fails fails"
! grep -q '^rm ' "$TEST_DOCKER_LOG" || fail "a run that lost the name race removes no container" "$(<"$TEST_DOCKER_LOG")"
grep -Fxq cid-omarchy-asahi-fresh-vm-race "$TEST_CONTAINERS" || fail "the container that won the name race survives"
: >"$TEST_CONTAINERS"
TEST_DOCKER_RUN_FAILS=start OMARCHY_VM_RUN_ID=unstarted run_harness --evidence-dir "$evidence_root"
(( status != 0 )) || fail "a run whose container cannot start fails"
[[ $(grep '^rm ' "$TEST_DOCKER_LOG") == 'rm -f cid-omarchy-asahi-fresh-vm-unstarted' ]] ||
  fail "a run removes the container it created even when it never started" "$(<"$TEST_DOCKER_LOG")"
[[ ! -s $TEST_CONTAINERS ]] || fail "an unstarted container is not left behind"
pass "a run removes only the container it created, by the ID docker recorded"

# --- The tree under test ----------------------------------------------------

# The harness no longer lives in the tree it tests, so the tree is always named.
OMARCHY_VM_SOURCE_DIR='' OMARCHY_VM_RUN_ID=no-source run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *'Name the omarchy-mx-mac tree under test with --source DIR or OMARCHY_VM_SOURCE_DIR'* ]] ||
  fail "a run without a tree under test is refused" "$output"
[[ ! -s $TEST_DOCKER_LOG && ! -e $evidence_root/no-source ]] || fail "a run without a tree under test starts nothing"

partial_tree="$test_tmp/partial-source"
make_source_tree "$partial_tree" partial
rm "$partial_tree/bin/omarchy-update-asahi-bundle" "$partial_tree/install/optional-packages.tsv"
OMARCHY_VM_RUN_ID=partial run_harness --source "$partial_tree" --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *"The tree under test $partial_tree has no bin/omarchy-update-asahi-bundle"* ]] ||
  fail "a tree under test without the bundle updater is refused" "$output"
[[ ! -s $TEST_DOCKER_LOG && ! -e $evidence_root/partial ]] || fail "a refused tree under test starts nothing"
git -C "$partial_tree" checkout -q -- bin/omarchy-update-asahi-bundle
OMARCHY_VM_RUN_ID=partial-optional run_harness --source "$partial_tree" --optional-packages --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *"The tree under test $partial_tree has no install/optional-packages.tsv"* ]] ||
  fail "--optional-packages needs the package lists of the tree under test" "$output"
OMARCHY_VM_RUN_ID=partial-plain run_harness --source "$partial_tree" --evidence-dir "$evidence_root"
(( status == 0 )) || fail "a tree without optional package lists runs without --optional-packages" "$output"
grep -Fxq "$partial_tree/bin/omarchy-install-asahi-fresh" "$TEST_SCP_LOG" && ! grep -Fq "$source_tree/" "$TEST_SCP_LOG" ||
  fail "--source takes precedence over OMARCHY_VM_SOURCE_DIR" "$(<"$TEST_SCP_LOG")"
grep -Fxq "source_commit=$(git -C "$partial_tree" rev-parse HEAD)" "$evidence_root/partial-plain/run.txt" ||
  fail "the run record names the commit of the tree given with --source" "$(<"$evidence_root/partial-plain/run.txt")"
pass "the tree under test is named explicitly and must hold what the guest runs"

OMARCHY_VM_CANDIDATE_TAG=asahi-packages-candidate-$(printf 'b%.0s' {1..40}) \
  OMARCHY_VM_CANDIDATE_SHA256=$(printf 'c%.0s' {1..64}) \
  OMARCHY_VM_CANDIDATE_FINGERPRINT=$(printf 'D%.0s' {1..40}) \
  OMARCHY_VM_CANDIDATE_PACKAGE_COUNT=3 \
  OMARCHY_VM_RUN_ID=candidate run_harness --evidence-dir "$evidence_root"
(( status == 0 )) || fail "a candidate run succeeds" "$output"
grep -Fxq "$ROOT/tools/acceptance/keys/omarchy-arm-repository.asc" "$TEST_SCP_LOG" ||
  fail "a candidate is verified with the harness's repository key by default" "$(<"$TEST_SCP_LOG")"
grep -Fxq 'candidate-repository stage output' "$evidence_root/candidate/candidate-repository.log" ||
  fail "a candidate run exports its candidate log"
pass "a candidate is verified with the harness's own repository key"

# --- The host lock -----------------------------------------------------------

# Hold the lock with a real run parked in its install stage, then start runs as
# another identity would: another HOME (sudo, another docker-group user), with
# the same state directory and with another checkout's.
block="$test_tmp/block"
mkdir -p "$block"
PATH="$stub_bin:$PATH" HOME="$test_tmp/home-a" OMARCHY_VM_STATE_DIR="$state" OMARCHY_VM_HOST_LOCK="$host_lock" \
  OMARCHY_VM_RUN_ID=holder TEST_BLOCK_STAGE=install TEST_BLOCK_DIR="$block" \
  "$harness/run" --evidence-dir "$evidence_root" >"$test_tmp/holder.out" 2>&1 &
holder=$!
for (( i = 0; i < 200; i++ )); do
  [[ -e $block/blocked ]] && break
  sleep 0.05
done
[[ -e $block/blocked ]] || fail "the holding run reaches its install stage" "$(<"$test_tmp/holder.out")"

for other_state in "$state" "$test_tmp/other-checkout-state"; do
  TEST_HOME="$test_tmp/home-b" TEST_STATE_DIR="$other_state" OMARCHY_VM_RUN_ID=refused run_harness --evidence-dir "$evidence_root"
  (( status != 0 )) || fail "a run as another identity is refused while the lock is held ($other_state)"
  [[ $output == *"Another VM run holds the host lock $host_lock: run_id=holder pid=$holder user=$(id -un) state=$state started_at="* &&
    $output == *'--wait-for-lease'* && $output != *'no longer running'* ]] ||
    fail "a refused run names the holding run and the way to queue" "$output"
  [[ ! -s $TEST_DOCKER_LOG && ! -e $evidence_root/refused ]] || fail "a refused run touches no container and exports nothing"
done
pass "a run under any HOME and from any checkout is refused while another holds the host lock"

PATH="$stub_bin:$PATH" HOME="$test_tmp/home-b" OMARCHY_VM_STATE_DIR="$state" OMARCHY_VM_HOST_LOCK="$host_lock" \
  OMARCHY_VM_RUN_ID=queued "$harness/run" --wait-for-lease --evidence-dir "$evidence_root" \
  >"$test_tmp/queued.out" 2>"$test_tmp/queued.err" &
queued=$!
for (( i = 0; i < 100; i++ )); do
  grep -q 'Waiting for the host lock' "$test_tmp/queued.err" 2>/dev/null && break
  sleep 0.05
done
grep -Fq "Waiting for the host lock $host_lock, held by: run_id=holder pid=$holder" "$test_tmp/queued.err" ||
  fail "a queued run says whom it waits for" "$(cat "$test_tmp/queued.err" 2>/dev/null)"
[[ ! -e $evidence_root/queued ]] || fail "a queued run waits for the lock"
touch "$block/release"
set +e
wait "$holder"
holder_status=$?
wait "$queued"
status=$?
set -e
(( holder_status == 0 )) || fail "the holding run finishes" "$(<"$test_tmp/holder.out")"
(( status == 0 )) || fail "a queued run proceeds once the lock is free" "$(<"$test_tmp/queued.err")"
[[ -d $evidence_root/holder && -d $evidence_root/queued ]] || fail "the holding and the queued run both export their evidence"
pass "--wait-for-lease queues behind the running holder"

# A holder that exited while something it started keeps the descriptor is
# reported as gone rather than as the runner of record.
printf 'run_id=ghost pid=999999999 user=nobody state=/elsewhere\n' >"$host_lock"
flock "$host_lock" bash -c 'touch "$1/held"; while [[ ! -e $1/unheld ]]; do sleep 0.05; done' _ "$test_tmp" &
ghost=$!
for (( i = 0; i < 100; i++ )); do
  [[ -e $test_tmp/held ]] && break
  sleep 0.05
done
OMARCHY_VM_RUN_ID=refused run_harness --evidence-dir "$evidence_root"
[[ $output == *'run_id=ghost pid=999999999 user=nobody state=/elsewhere (no longer running; a process it started still holds the lock)'* ]] ||
  fail "a holder whose recorded process is gone is reported as such" "$output"
touch "$test_tmp/unheld"
wait "$ghost"
pass "a lock held after its recorded run exited says so"

# The first run creates the lock for its user; one user runs VM acceptance on a
# host, so a lock anyone else owns is refused, whoever can read it.
rm -f "$host_lock"
OMARCHY_VM_RUN_ID=creates-lock run_harness --evidence-dir "$evidence_root"
(( status == 0 )) && [[ $(stat -c '%a %u' "$host_lock") == "644 $EUID" ]] ||
  fail "a run creates the host lock 0644 for its own user" "$(stat -c '%a %u' "$host_lock" 2>&1) $output"
if (( EUID == 0 )); then
  foreign_lock="$test_tmp/foreign.lock"
  echo 'run_id=theirs' >"$foreign_lock"
  chown 65534 "$foreign_lock"
else
  foreign_lock=/etc/passwd
fi
foreign_before=$(sha256sum "$foreign_lock")
set +e
output=$(PATH="$stub_bin:$PATH" HOME="$test_tmp/home" OMARCHY_VM_STATE_DIR="$state" OMARCHY_VM_HOST_LOCK="$foreign_lock" \
  OMARCHY_VM_RUN_ID=foreign-lock "$harness/run" --evidence-dir "$evidence_root" 2>&1)
status=$?
set -e
(( status != 0 )) && [[ $output == *"The host VM lock $foreign_lock is another user's lock ("*"); one user runs VM acceptance on this host"* ]] ||
  fail "a lock another user owns is refused" "$output"
[[ $(sha256sum "$foreign_lock") == "$foreign_before" && ! -e $evidence_root/foreign-lock ]] ||
  fail "a refused lock is left untouched and nothing runs"
mv "$host_lock" "$host_lock.real"
ln -s "$host_lock.real" "$host_lock"
OMARCHY_VM_RUN_ID=symlinked-lock run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *"The host VM lock $host_lock is a symlink"* ]] ||
  fail "a symlinked host lock is refused" "$output"
rm "$host_lock"
mv "$host_lock.real" "$host_lock"
pass "the host lock belongs to one user and a lock anyone else owns is refused"

# A lock taken on an inode the path no longer names protects nothing. Queue a
# run behind a holder, replace the lock file under it, then release: the run
# must notice, take the new file instead, and record itself only there.
hold_lock() {
  local marker=$1
  shift

  rm -f "$test_tmp/$marker".{held,release}
  flock "$1" bash -c 'touch "$1.held"; while [[ ! -e $1.release ]]; do sleep 0.05; done' _ "$test_tmp/$marker" &
  held_pid=$!
  for (( i = 0; i < 100; i++ )); do
    [[ -e $test_tmp/$marker.held ]] && break
    sleep 0.05
  done
  [[ -e $test_tmp/$marker.held ]] || fail "the test holds $1"
}

queue_run() {
  PATH="$stub_bin:$PATH" HOME="$test_tmp/home" OMARCHY_VM_STATE_DIR="$state" OMARCHY_VM_HOST_LOCK="$host_lock" \
    OMARCHY_VM_RUN_ID="$1" "$harness/run" --wait-for-lease --evidence-dir "$evidence_root" >"$test_tmp/$1.log" 2>&1 &
  queued_pid=$!
}

wait_for_waiting() {
  for (( i = 0; i < 100; i++ )); do
    (( $(grep -c 'Waiting for the host lock' "$test_tmp/$1.log" 2>/dev/null) >= $2 )) && return
    sleep 0.05
  done
  fail "the queued run waits for the host lock ($2)" "$(cat "$test_tmp/$1.log")"
}

printf 'run_id=first-holder\n' >"$host_lock"
hold_lock first "$host_lock"
first_holder=$held_pid
ln "$host_lock" "$test_tmp/replaced-inode"
queue_run swapped
wait_for_waiting swapped 1
echo 'run_id=replacement' >"$host_lock.new"
mv -f "$host_lock.new" "$host_lock"
touch "$test_tmp/first.release"
wait "$first_holder"
set +e
wait "$queued_pid"
status=$?
set -e
(( status == 0 )) || fail "a run whose lock file was replaced while it waited takes the new one" "$(<"$test_tmp/swapped.log")"
grep -Fq "The host VM lock $host_lock changed while it was being taken; taking it again" "$test_tmp/swapped.log" ||
  fail "a run says its lock file changed" "$(<"$test_tmp/swapped.log")"
[[ $(head -n 1 "$host_lock") == "run_id=swapped pid="* ]] || fail "the run records itself in the lock file it holds" "$(<"$host_lock")"
[[ $(head -n 1 "$test_tmp/replaced-inode") == run_id=first-holder ]] ||
  fail "the run writes nothing to the replaced inode it no longer holds" "$(<"$test_tmp/replaced-inode")"
pass "a lock file replaced while a run waits is noticed and the new one taken"

# Replaced again while the run waits for the new file: something keeps
# replacing the lock, and the run refuses rather than chase it.
hold_lock first "$host_lock"
first_holder=$held_pid
queue_run swapped-twice
wait_for_waiting swapped-twice 1
echo 'run_id=second-holder' >"$host_lock.second"
hold_lock second "$host_lock.second"
second_holder=$held_pid
mv -f "$host_lock.second" "$host_lock"
touch "$test_tmp/first.release"
wait "$first_holder"
wait_for_waiting swapped-twice 2
echo 'run_id=third' >"$host_lock.third"
mv -f "$host_lock.third" "$host_lock"
touch "$test_tmp/second.release"
wait "$second_holder"
set +e
wait "$queued_pid"
status=$?
set -e
(( status != 0 )) && grep -Fq "The host VM lock $host_lock changed again while it was being taken" "$test_tmp/swapped-twice.log" ||
  fail "a run refuses a lock file that keeps changing" "$(<"$test_tmp/swapped-twice.log")"
[[ ! -e $evidence_root/swapped-twice && $(<"$host_lock") == run_id=third ]] ||
  fail "a run refused for a changing lock starts nothing and records nothing"
pass "a lock file replaced twice while a run waits is refused"

# The holder line goes through the validated descriptor, never the path: the
# record's own `date` is the last step before the write, so swap the file there.
real_date=$(command -v date)
cat >"$stub_bin/date" <<SH
#!/bin/bash
if [[ -n \${TEST_SWAP_LOCK_ON_DATE:-} && ! -e \$TEST_SWAP_LOCK_ON_DATE.done ]]; then
  touch "\$TEST_SWAP_LOCK_ON_DATE.done"
  echo 'run_id=swapped-in' >"\$TEST_SWAP_LOCK_ON_DATE.new"
  mv -f "\$TEST_SWAP_LOCK_ON_DATE.new" "\$TEST_SWAP_LOCK_ON_DATE"
fi
exec "$real_date" "\$@"
SH
chmod +x "$stub_bin/date"
rm -f "$host_lock"
: >"$host_lock"
ln "$host_lock" "$test_tmp/locked-inode"
TEST_SWAP_LOCK_ON_DATE="$host_lock" OMARCHY_VM_RUN_ID=via-descriptor run_harness --evidence-dir "$evidence_root"
rm "$stub_bin/date"
[[ -e $host_lock.done ]] || fail "the lock file was swapped before the holder record was written"
rm -f "$host_lock.done"
[[ $(head -n 1 "$test_tmp/locked-inode") == "run_id=via-descriptor pid="* ]] ||
  fail "the holder record goes to the locked inode" "$(cat "$test_tmp/locked-inode")"
[[ $(<"$host_lock") == run_id=swapped-in ]] || fail "the holder record never follows the path to another file" "$(<"$host_lock")"
pass "the holder record is written through the validated descriptor, not the path"

# A state directory belongs to one identity.
if (( EUID == 0 )); then
  foreign_state="$test_tmp/foreign-state"
  mkdir -p "$foreign_state"
  chown 65534 "$foreign_state"
else
  foreign_state=/usr
fi
TEST_STATE_DIR="$foreign_state" OMARCHY_VM_RUN_ID=foreign run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *"The VM state directory $foreign_state belongs to "*", not $(id -un)"* ]] ||
  fail "a state directory another identity owns is refused" "$output"
[[ ! -s $TEST_DOCKER_LOG ]] || fail "a refused state directory starts nothing"
flock "$state/lease" bash -c 'touch "$1/state-held"; while [[ ! -e $1/state-unheld ]]; do sleep 0.05; done' _ "$test_tmp" &
state_holder=$!
for (( i = 0; i < 100; i++ )); do
  [[ -e $test_tmp/state-held ]] && break
  sleep 0.05
done
OMARCHY_VM_RUN_ID=state-busy run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *"Another VM run is using the state directory $state"* ]] ||
  fail "a state directory in use is refused even past the host lock" "$output"
touch "$test_tmp/state-unheld"
wait "$state_holder"
pass "a state directory belongs to one identity and one run at a time"

# A --keep VM from another state directory still owns the forwarded ports.
TEST_DOCKER_PS=$'omarchy-asahi-fresh-vm-old 127.0.0.1:22222->22/tcp, 127.0.0.1:25900->5900/tcp\n' \
  OMARCHY_VM_RUN_ID=ports run_harness --evidence-dir "$evidence_root"
(( status != 0 )) && [[ $output == *'omarchy-asahi-fresh-vm-old 127.0.0.1:22222->22/tcp'* ]] ||
  fail "a run refuses ports another container forwards, naming it" "$output"
! grep -q '^build ' "$TEST_DOCKER_LOG" || fail "a run refused for its ports builds nothing"
lease_is_free || fail "a refused run releases the lease"
pass "a run refuses ports a retained VM still forwards"

# --- Failed runs -------------------------------------------------------------

TEST_FAIL_STAGE=verify OMARCHY_VM_CPUS=4 OMARCHY_VM_RUN_ID=fail-1 run_harness --evidence-dir "$evidence_root"
(( status != 0 )) || fail "a failing guest stage fails the run"
evidence="$evidence_root/fail-1"
grep -Fxq 'status=failed' "$evidence/run.txt" || fail "a failed run is recorded as failed" "$(cat "$evidence/run.txt" 2>/dev/null)"
grep -Fxq 'verify stage output' "$evidence/verify.log" || fail "a failed run exports the failing stage's log"
[[ -s $evidence/install.log && -s $evidence/serial.log ]] || fail "a failed run exports every log it produced"
evidence_verifies "$evidence" || fail "a failed run's evidence verifies"
[[ -f $state/runs/fail-1/disk.qcow2 ]] || fail "a failed run keeps its disk for debugging"
grep -Fxq 'rm -f cid-omarchy-asahi-fresh-vm-fail-1' "$TEST_DOCKER_LOG" || fail "a failed run still removes its container"
[[ $output == *"Failed run retained for debugging: $state/runs/fail-1"* ]] || fail "a failed run says where its disk is" "$output"
grep -Fq -- '-e OMARCHY_VM_CPUS=4 ' "$TEST_DOCKER_LOG" || fail "OMARCHY_VM_CPUS sets the guest's vCPUs"
lease_is_free || fail "a failed run releases the lease"
pass "a failed run keeps its evidence and, by default, its disk"

TEST_FAIL_STAGE=install OMARCHY_VM_RUN_ID=fail-2 run_harness --evidence-dir "$evidence_root" --discard-failed-run
(( status != 0 )) || fail "a failing install fails the run"
grep -Fxq 'status=failed' "$evidence_root/fail-2/run.txt" || fail "a discarded failed run still keeps its evidence"
[[ ! -e $state/runs/fail-2 ]] || fail "--discard-failed-run deletes the failed run's directory"
pass "--discard-failed-run deletes a failed run's disk after exporting its evidence"

# A copy that does not match its source must never cost the run directory.
real_cp=$(command -v cp)
cat >"$stub_bin/cp" <<SH
#!/bin/bash
"$real_cp" "\$@" || exit
[[ \${!#} != */serial.log ]] || echo corrupted >>"\${!#}"
SH
chmod +x "$stub_bin/cp"
OMARCHY_VM_RUN_ID=corrupt run_harness --evidence-dir "$evidence_root"
rm "$stub_bin/cp"
(( status != 0 )) || fail "a run whose evidence does not verify fails"
[[ $output == *'Evidence export failed'* ]] || fail "a failed export is reported" "$output"
[[ -f $state/runs/corrupt/disk.qcow2 ]] || fail "a failed export keeps the run directory"
[[ ! -e $evidence_root/corrupt && -d $evidence_root/corrupt.partial ]] ||
  fail "an unverified copy never takes the evidence directory's name"
pass "an export that does not verify keeps the run directory"

# Until the container is confirmed gone its guest may still be writing the run
# directory: export nothing, delete nothing, and fail even a passing run.
for failure in TEST_DOCKER_RM_FAILS TEST_DOCKER_RM_IGNORED TEST_DOCKER_PS_FAILS; do
  : >"$TEST_CONTAINERS"
  export "$failure=1"
  OMARCHY_VM_RUN_ID="stuck-$failure" run_harness --evidence-dir "$evidence_root"
  unset "$failure"
  (( status != 0 )) || fail "a passing run fails when its container is not confirmed gone ($failure)" "$output"
  [[ $output == *"Could not confirm that container omarchy-asahi-fresh-vm-stuck-$failure"* ]] ||
    fail "a run says it could not confirm its container is gone ($failure)" "$output"
  [[ -f $state/runs/stuck-$failure/disk.qcow2 ]] || fail "a run keeps its disk while its container may run ($failure)"
  [[ ! -e $evidence_root/stuck-$failure && ! -e $evidence_root/stuck-$failure.partial ]] ||
    fail "a run exports nothing while its container may run ($failure)"
done
pass "a run whose container is not confirmed gone keeps everything and fails"

# An interrupted run still removes its container and exports its evidence when
# further signals arrive during cleanup, as from a second Ctrl-C.
interrupt="$test_tmp/interrupt"
mkdir -p "$interrupt"
: >"$TEST_CONTAINERS"
PATH="$stub_bin:$PATH" HOME="$test_tmp/home" OMARCHY_VM_STATE_DIR="$state" OMARCHY_VM_HOST_LOCK="$host_lock" \
  OMARCHY_VM_RUN_ID=interrupted TEST_BLOCK_STAGE=install TEST_BLOCK_RM=1 TEST_BLOCK_DIR="$interrupt" \
  "$harness/run" --evidence-dir "$evidence_root" >"$test_tmp/interrupted.out" 2>&1 &
interrupted=$!
for (( i = 0; i < 200; i++ )); do
  [[ -e $interrupt/blocked ]] && break
  sleep 0.05
done
kill -TERM "$interrupted"
touch "$interrupt/release"
for (( i = 0; i < 200; i++ )); do
  [[ -e $interrupt/rm-blocked ]] && break
  sleep 0.05
done
[[ -e $interrupt/rm-blocked ]] || fail "an interrupted run starts its cleanup" "$(<"$test_tmp/interrupted.out")"
kill -TERM "$interrupted"
sleep 0.3
kill -INT "$interrupted"
sleep 0.3
touch "$interrupt/rm-release"
set +e
wait "$interrupted"
status=$?
set -e
(( status == 143 )) || fail "an interrupted run exits with the first signal's status" "$status $(<"$test_tmp/interrupted.out")"
[[ ! -s $TEST_CONTAINERS ]] || fail "an interrupted run removes its container"
grep -Fxq 'exit_status=143' "$evidence_root/interrupted/run.txt" 2>/dev/null ||
  fail "an interrupted run exports its evidence despite further signals" "$(<"$test_tmp/interrupted.out")"
[[ -d $state/runs/interrupted ]] || fail "an interrupted run keeps its disk like any failed run"
pass "further signals during cleanup do not cut a VM run's cleanup short"

# --keep leaves the VM running on its run directory and pauses it for the copy.
OMARCHY_VM_RUN_ID=kept run_harness --keep --evidence-dir "$evidence_root"
(( status == 0 )) || fail "a kept run succeeds" "$output"
! grep -q '^rm ' "$TEST_DOCKER_LOG" || fail "a kept run keeps its container"
[[ $(grep '^monitor ' "$TEST_DOCKER_LOG") == $'monitor screendump /work/runs/kept/desktop.ppm\nmonitor stop\nmonitor cont' ]] ||
  fail "a kept run pauses the guest while its evidence is copied" "$(<"$TEST_DOCKER_LOG")"
[[ -f $state/runs/kept/disk.qcow2 ]] || fail "a kept run keeps its run directory"
evidence_verifies "$evidence_root/kept" || fail "a kept run's evidence verifies"
[[ $output == *'VM retained in Docker container omarchy-asahi-fresh-vm-kept'* ]] || fail "a kept run names its container" "$output"
pass "--keep exports verified evidence and keeps the VM and its disk"

# --- The launcher ------------------------------------------------------------

# start-vm runs in the container against /work. Run a copy against a scratch
# /work with QEMU stubbed out, recording what it would create and boot.
launcher="$test_tmp/launcher"
work="$launcher/work"
mkdir -p "$work/cache" "$launcher/aavmf" "$launcher/bin"
sed -e "s|/work|$work|g" -e "s|/usr/share/AAVMF|$launcher/aavmf|g" "$harness/container/start-vm" >"$launcher/start-vm"
: >"$launcher/aavmf/AAVMF_CODE.fd"
: >"$launcher/aavmf/AAVMF_VARS.fd"
cat >"$launcher/bin/qemu-img" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$launcher/qemu-img.log"
: >"\${!#}"
SH
cat >"$launcher/bin/qemu-system-aarch64" <<SH
#!/bin/bash
printf '%s\n' "\$*" >"$launcher/qemu-system.log"
SH
chmod +x "$launcher/bin"/*
echo original-base >"$work/cache/archarm-base.qcow2"

PATH="$launcher/bin:$PATH" OMARCHY_VM_RUN_DIR="$work/runs/r1" bash "$launcher/start-vm" ||
  fail "the launcher starts a run"
[[ $(stat -c %i "$work/runs/r1/base.qcow2") == "$(stat -c %i "$work/cache/archarm-base.qcow2")" ]] ||
  fail "a run's disk is backed by its own link to the cached base"
grep -Fxq "create -f qcow2 -F qcow2 -b base.qcow2 $work/runs/r1/disk.qcow2" "$launcher/qemu-img.log" ||
  fail "a run's disk names its backing file relative to itself" "$(<"$launcher/qemu-img.log")"
grep -Fq -- "-smp 8 " "$launcher/qemu-system.log" && grep -Fq -- "-drive file=$work/runs/r1/disk.qcow2," "$launcher/qemu-system.log" ||
  fail "the guest boots the run's own disk with 8 vCPUs" "$(<"$launcher/qemu-system.log")"

# --rebuild-base removes the cached base; build-base writes a new file over it.
rm -f "$work/cache/archarm-base.qcow2"
echo rebuilt-base >"$work/cache/archarm-base.qcow2.tmp"
mv "$work/cache/archarm-base.qcow2.tmp" "$work/cache/archarm-base.qcow2"
[[ $(<"$work/runs/r1/base.qcow2") == original-base ]] ||
  fail "a retained run keeps the base its disk was written against after the base is rebuilt"

# Where the run directory cannot link to the cache, it gets its own copy.
printf '#!/bin/bash\nexit 1\n' >"$launcher/bin/ln"
chmod +x "$launcher/bin/ln"
PATH="$launcher/bin:$PATH" OMARCHY_VM_RUN_DIR="$work/runs/r2" bash "$launcher/start-vm" ||
  fail "the launcher starts a run that cannot link the base"
[[ $(<"$work/runs/r2/base.qcow2") == rebuilt-base &&
  $(stat -c %i "$work/runs/r2/base.qcow2") != "$(stat -c %i "$work/cache/archarm-base.qcow2")" ]] ||
  fail "a run that cannot link the base copies it"
pass "each run's disk is backed by its own base, which survives a base rebuild"

# --- Static guards -----------------------------------------------------------

grep -Fq 'host_lock=${OMARCHY_VM_HOST_LOCK:-/tmp/omarchy-asahi-fresh-vm.lock}' "$harness/run" ||
  fail "every real run shares one fixed host lock"
grep -Fq 'cpus=${OMARCHY_VM_CPUS:-8}' "$harness/container/start-vm" || fail "the launcher defaults to 8 vCPUs"
grep -Fq -- '-smp "$cpus"' "$harness/container/start-vm" || fail "QEMU uses the configured vCPU count"
grep -Fq 'run=${OMARCHY_VM_RUN_DIR:-/work/run}' "$harness/container/start-vm" || fail "the launcher takes the run's directory"
# The only live Arch Linux ARM URL left is the signed base rootfs, which is
# cached; every package comes from the snapshot unless a caller overrides it.
live_mirrors=$(grep -rn --exclude-dir=test-runs 'archlinuxarm\.org' "$harness" | grep -v '/container/build-base:[0-9]*:rootfs_url=' || true)
[[ -z $live_mirrors ]] || fail "nothing in the harness defaults to a live Arch Linux ARM mirror" "$live_mirrors"
pass "the launcher takes the vCPU count and run directory, and no live mirror is a default"
