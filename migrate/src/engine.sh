# The journaled migration engine.
#
# It moves a Mac onto its target in thirteen ordered steps. Every step records
# its start and its end in an append-only journal synced to disk, so a power
# loss or a kill resumes at the first step that did not finish, and every step
# can run again from its start. Preflight changes nothing and freezes the plan
# the later steps follow. A cohort adapter (cohort-<cohort>.sh) decides what
# its machines need: the package targets, the packages the transaction may
# remove and the compatibility state to retire. The engine owns the order, the
# journal and every change to the system.
#
# The caller sets R (the fixture root, empty on a live system), fixture (1 when
# unprivileged tests drive it) and self (this file). Adapters read the
# target_* values.
#
# Exit status: 0 when the Mac is migrated, waits for its reboot or has nothing
# to migrate; 75 (EX_TEMPFAIL) when it stopped before anything changed (a
# preflight refusal, or any failure before the journal exists); 1 when a step
# failed, and running again resumes it.
# shellcheck disable=SC2034,SC2154

# Raised with every change to what the tool does; the journal format only when
# a journal one version writes cannot be resumed by another.
tool_version=1
journal_format=2

migrate_steps=(preflight backup keyring prefetch repositories transaction boot-chain loader defaults verify unpin reboot retire)

# pacman's download user reads the work, cache and candidate directories.
umask 022

state=$R/var/lib/omarchy-mac/migration
journal=$state/journal
plan=$state/plan
cache=$state/cache
backup=$state/backup
expected=$state/expected
start=$state/start
interrupted_marker=$state/transaction-interrupted
set_copy=$state/set
complete=$state/complete
reboot_pending=$state/reboot-pending
user_pending=$state/user-pending
tool_copy=$state/tool/omarchy-mac-migrate
lock_file=$R/run/lock/omarchy-mac-migrate.lock
pacman_conf=$R/etc/pacman.conf
pacman_db=$R/var/lib/pacman
pacman_cache=$R/var/cache/pacman/pkg
pacman_gpg=$R/etc/pacman.d/gnupg
esp=/boot/efi
limine_gate=$R/var/lib/omarchy/limine.enabled
limine_default=$R/etc/default/limine
verify_unit=omarchy-mac-migrate-verify.service
verify_unit_file=$R/etc/systemd/system/$verify_unit
first_boot_marker=$R/var/lib/omarchy/mac-first-boot/pending
legacy_first_boot_marker=$R/var/lib/omarchy/first-boot/pending
# The user units a fresh install's first run enables
# (install/user/first-run/enable-user-units.sh).
fresh_user_units="bt-agent.service owed.service omarchy-recover-internal-monitor.service omarchy-sleep-lock.service omarchy-migrate-notify.service omarchy-fcitx5.service omarchy-crash-watch.service omarchy-brightness-keyboard-auto.service"

current_step=""
check_only=0
original_args=()
target_file=""
payload_dir=""
restarted=0
restarts=0
work=""
gpgdir=""

say() {
  printf '%s\n' "$*"
}

die() {
  echo "omarchy-mac-migrate: $*" >&2
  if [[ -n $current_step && -f $journal ]]; then
    journal_write "$current_step" "fail" "$*"
  fi
  # With nothing journaled, nothing has changed: deferred, like a refusal.
  [[ -f $journal ]] || exit 75
  # Before the repository switch the system still runs as it did (only the
  # official key was trusted): the attempt is set aside and the next run starts
  # over from preflight.
  if before_boundary; then
    abort_migration "$*"
    exit 75
  fi
  exit 1
}

# The repository switch is the first change that cannot be left in place: from
# its start on, the migration only goes forward.
before_boundary() {
  [[ -f $journal ]] && ! awk '$2 == "repositories" { found = 1 } END { exit !found }' "$journal"
}

abort_migration() {
  local destination
  destination=$state/history/aborted-$(date +%s)
  install -d -m 700 "$destination"
  mv "$journal" "$plan" "$state/format" "$destination/" 2>/dev/null
  rm -rf "$cache" "$backup" "$set_copy" "$start" "$expected" "$state/installed.now" "$state/tool"
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" | durable_write "$state/deferred" 2>/dev/null || true
  say "Nothing on this Mac changed; the next run starts the migration over." >&2
}

on_exit() {
  local status=$?
  if (( status != 0 )) && [[ -n $current_step && -f $journal && $(step_state "$current_step") == "begin" ]]; then
    journal_write "$current_step" "fail" "exit $status"
  fi
  [[ -z $work ]] || rm -rf "$work"
}

# --- Journal -----------------------------------------------------------------

journal_write() {
  local detail=${3:-}
  printf '%s %s %s%s\n' "$(date +%s)" "$1" "$2" "${detail:+ ${detail//$'\n'/ }}" >>"$journal"
  sync "$journal"
}

# The last event recorded for a step: begin, done, fail, or nothing.
step_state() {
  [[ -f $journal ]] || return 0
  awk -v step="$1" '$2 == step { event = $3 } END { print event }' "$journal"
}

next_step() {
  local step
  for step in "${migrate_steps[@]}"; do
    if [[ $(step_state "$step") != "done" ]]; then
      printf '%s\n' "$step"
      return
    fi
  done
}

# Unprivileged tests kill the engine with SIGKILL part way through a step's
# work (mid), once the work is done (during) or once its end is recorded
# (after). Root never reads these.
interrupt_for_test() {
  (( fixture )) || return 0
  if [[ $1 == "mid" && ${OMARCHY_MAC_MIGRATE_KILL_MID:-} == "$2" ]] ||
    [[ $1 == "during" && ${OMARCHY_MAC_MIGRATE_KILL_DURING:-} == "$2" ]] ||
    [[ $1 == "after" && ${OMARCHY_MAC_MIGRATE_KILL_AFTER:-} == "$2" ]]; then
    kill -9 $$
  fi
}

run_step() {
  local step=$1
  current_step=$step
  restarted=0
  journal_write "$step" "begin"
  "step_${step//-/_}"
  if (( restarted )); then
    current_step=""
    return 0
  fi
  interrupt_for_test during "$step"
  journal_write "$step" "done"
  interrupt_for_test after "$step"
  current_step=""
}

# Replace a file whole: written beside it, synced, then renamed over it.
durable_write() {
  local file=$1 mode=${2:-644} tmp
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if cat >"$tmp" && chmod "$mode" "$tmp" && sync "$tmp" && mv -f "$tmp" "$file"; then
    sync "$(dirname "$file")"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- Helpers -------------------------------------------------------------------

# A root-owned (in a fixture, caller-owned) regular file or directory, not a
# symlink and not writable by group or others. Target files and sets decide
# what is installed as root.
trusted() {
  local owner mode
  [[ -e $1 && ! -L $1 ]] || return 1
  read -r owner mode < <(stat -c '%u %a' -- "$1") || return 1
  (( owner == EUID && (8#$mode & 8#022) == 0 ))
}

pacman_run() {
  env OMARCHY_UPDATE_PACMAN=1 LC_ALL=C pacman --gpgdir "${gpgdir:-$pacman_gpg}" "$@"
}

installed_packages() {
  LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Q
}

installed_version() {
  awk -v name="$1" '$1 == name { print $2; exit }' "$2"
}

# The upstream detector where the runtime has it; else the device tree, as
# Asahi's own tools read it (a quattro or mx-mac runtime predates the
# detector).
hardware_platform() {
  if command -v omarchy-hw-platform >/dev/null; then
    omarchy-hw-platform
  elif (( ! fixture )) && [[ -r /proc/device-tree/compatible ]] && tr '\0' '\n' </proc/device-tree/compatible | grep -qx 'apple,arm-platform'; then
    echo apple-silicon
  else
    echo unknown
  fi
}

boot_id() {
  cat "$R/proc/sys/kernel/random/boot_id"
}

limine_mac() {
  [[ -e $limine_gate && -f $limine_default ]]
}

# The release of the installed Apple kernel, from the pkgbase its module tree names.
kernel_release() {
  local dir
  for dir in "$R"/usr/lib/modules/*/; do
    if [[ -f $dir/pkgbase && $(<"$dir/pkgbase") == "$1" ]]; then
      basename "$dir"
      return 0
    fi
  done
  return 1
}

# What the next boot reads (kernel, initramfs, unlock, device trees, m1n1,
# U-Boot, Limine), as omarchy update's update-verify checks it.
boot_check_pending() {
  env OMARCHY_BOOT_CHECK_ALLOW_PENDING_REBOOT=1 omarchy-apple-silicon-boot-check --boot-chain "$@"
}

key_trusted() {
  local validity
  validity=$(gpg --homedir "${2:-$pacman_gpg}" --batch --no-auto-check-trustdb --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "pub" { print $2; exit }')
  [[ $validity == "f" || $validity == "u" ]]
}

key_present() {
  gpg --homedir "${2:-$pacman_gpg}" --batch --no-auto-check-trustdb --with-colons --list-keys "$1" >/dev/null 2>&1
}

# Official trust in the keyring at HOME: the keyrings installed are populated,
# and a missing Omarchy key comes from the keyserver by its full fingerprint and
# is signed locally. Fails when the key is not trusted after it.
trust_official_key() {
  local home=$1 keyrings=() name
  for name in archlinuxarm asahi-alarm omarchy; do
    [[ ! -f $R/usr/share/pacman/keyrings/$name.gpg ]] || keyrings+=("$name")
  done
  if (( ${#keyrings[@]} )); then
    pacman-key --gpgdir "$home" --populate "${keyrings[@]}" >/dev/null || return 1
  fi
  if ! key_trusted "$target_keyring" "$home"; then
    pacman-key --gpgdir "$home" --keyserver hkps://keys.openpgp.org --recv-keys "$target_keyring" >/dev/null &&
      pacman-key --gpgdir "$home" --lsign-key "$target_keyring" >/dev/null || return 1
  fi
  key_trusted "$target_keyring" "$home"
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

repositories_in() {
  awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); if (name != "options") print name }' "$1"
}

# The configuration the transaction runs with: the future one, with the
# verified candidate set as a local repository ahead of everything. It is never
# installed as /etc/pacman.conf, so candidates stay invisible afterwards.
transaction_conf() {
  local conf=$1 candidate_dir=$2
  if [[ -z $candidate_dir ]]; then
    cat "$conf"
    return
  fi
  awk -v repo="$candidate_repo" -v server="file://$candidate_dir" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ && !inserted && $0 !~ /\[options\]/ {
      print "[" repo "]"; print "SigLevel = Optional"; print "Server = " server; print ""; inserted = 1
    }
    { print }
  ' "$conf"
}

# --- Candidate sets ---------------------------------------------------------

# Prints the key that made a detached signature, or fails. A revoked or expired
# key or signature does not count. gpgv reads the set's keyring file and needs
# no agent, so nothing depends on where a gpg-agent socket could live.
signer_of() {
  local home=$1 file=$2 signature=$3 status
  status=$(gpgv --homedir "$home" --keyring "$home/key.gpg" --status-fd 1 "$signature" "$file" 2>/dev/null) || return 1
  awk '$1 != "[GNUPG:]" { next }
    $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|KEYEXPIRED|KEYREVOKED)$/ { bad = 1 }
    $2 == "GOODSIG" { good = 1 }
    $2 == "VALIDSIG" { primary = $NF; valid++ }
    END { if (!good || valid != 1 || bad) exit 1; print primary }' <<<"$status"
}

# Verifies a candidate set as tools/release/candidate-set verify does, trusting
# only the target's fingerprint. Prints why it fails.
verify_candidate_set() {
  local dir=$1 home=$2 manifest=$1/manifest.json receipt=$1/signing.json name sha digest
  rm -rf "$home"
  mkdir -m 700 "$home"
  if ! gpg --batch --homedir "$home" --dearmor <"$dir/candidate-signing-key.asc" >"$home/key.gpg" 2>/dev/null ||
    ! gpg --batch --homedir "$home" --with-colons --show-keys "$home/key.gpg" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$target_fingerprint"; then
    echo "its key is not $target_fingerprint"
    return 1
  fi
  [[ -f $receipt && -f $receipt.sig && $(signer_of "$home" "$receipt" "$receipt.sig") == "$target_fingerprint" ]] ||
    { echo "signing.json is not signed by $target_fingerprint"; return 1; }
  [[ $(jq -r '.signer.fingerprint' "$receipt") == "$target_fingerprint" &&
    $(jq -r '.manifest_sha256' "$receipt") == "$(sha256_of "$manifest")" &&
    $(jq -r '.set_sha256' "$receipt") == "$(jq -r '.set_sha256' "$manifest")" ]] ||
    { echo "signing.json does not bind this manifest"; return 1; }
  digest=$(jq -r '.packages[] | "\(.name) \(.version) \(.filename) \(.sha256)"' "$manifest" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
  [[ $digest == "$(jq -r '.set_sha256' "$manifest")" ]] || { echo "the manifest's set digest does not match its packages"; return 1; }
  [[ $(jq -r '[.signatures[].file] | sort | join(" ")' "$receipt") == "$(jq -r '[.packages[].filename] | sort | join(" ")' "$manifest")" ]] ||
    { echo "signing.json does not cover exactly the manifest's packages"; return 1; }
  while IFS=$'\t' read -r name sha; do
    [[ $name =~ ^[A-Za-z0-9@._+:-]+$ && $name != .* ]] || { echo "unsafe filename $name"; return 1; }
    [[ -f $dir/$name && $(sha256_of "$dir/$name") == "$sha" ]] || { echo "$name is missing or changed"; return 1; }
    [[ -f $dir/$name.sig && $(signer_of "$home" "$dir/$name" "$dir/$name.sig") == "$target_fingerprint" ]] ||
      { echo "$name is not signed by $target_fingerprint"; return 1; }
  done < <(jq -r '.packages[] | "\(.filename)\t\(.sha256)"' "$manifest")
}

# Copies a set into a directory only root can write, so nothing can change it
# between its verification and its use; everything later reads the copy.
copy_candidate_set() {
  local source=$1 destination=$2 name
  rm -rf "$destination"
  install -d -m 700 "$destination" || return 1
  for name in manifest.json signing.json signing.json.sig candidate-signing-key.asc; do
    [[ ! -f $source/$name ]] || cp "$source/$name" "$destination/$name" || return 1
  done
  [[ -f $destination/manifest.json ]] || { echo "the set has no manifest.json"; return 1; }
  while read -r name; do
    [[ $name =~ ^[A-Za-z0-9@._+:-]+$ && $name != .* ]] || { echo "unsafe filename $name"; return 1; }
    [[ ! -f $source/$name ]] || cp "$source/$name" "$destination/$name" || return 1
    [[ ! -f $source/$name.sig ]] || cp "$source/$name.sig" "$destination/$name.sig" || return 1
  done < <(jq -r '.packages[].filename' "$destination/manifest.json") || { echo "cannot read its manifest"; return 1; }
}

# Verifies the frozen set again, then builds a local repository of copies whose
# digests are checked again, so what pacman reads is what was verified.
# Signatures stay out of it: pacman's keyring never trusts the candidate key.
stage_candidate_repo() {
  local destination=$1 home=$2 reason name sha
  reason=$(verify_candidate_set "$target_set" "$home") || { echo "$reason" >&2; return 1; }
  rm -rf "$destination"
  install -d -m 755 "$destination" || return 1
  while IFS=$'\t' read -r name sha; do
    install -m 644 "$target_set/$name" "$destination/$name" || return 1
    [[ $(sha256_of "$destination/$name") == "$sha" ]] || { echo "the copy of $name changed" >&2; return 1; }
  done < <(jq -r '.packages[] | "\(.filename)\t\(.sha256)"' "$target_set/manifest.json")
  index_candidate_repo "$destination"
}

# Indexes the manifest's packages, and nothing else, in DIR (already holding
# copies, or given links to the set with "link"). repo-add embeds a signature
# lying beside a package, so the set's own signatures are never in DIR.
index_candidate_repo() {
  local destination=$1 mode=${2:-} files=() name
  mapfile -t files < <(jq -r '.packages[].filename' "$target_set/manifest.json")
  if [[ $mode == "link" ]]; then
    for name in "${files[@]}"; do
      ln -sfn "$target_set/$name" "$destination/$name" || return 1
    done
  fi
  (cd "$destination" && repo-add -q "$candidate_repo.db.tar.gz" "${files[@]}") >/dev/null || return 1
  chmod -R go+rX "$destination"
}

target_version() {
  jq -r --arg name "$1" '.packages[] | select(.name == $name) | .version' "$target_set/manifest.json"
}

# --- Preflight -----------------------------------------------------------------

# The cohort an Apple Silicon Mac belongs to, from what is installed. Each
# cohort needs an adapter defining <cohort>_plan and <cohort>_retire; it may
# also define <cohort>_preflight, _prefetch, _prepare and _restore, which the
# steps of those names call, and _stage and _unstage, which the loader step of
# a GRUB Mac calls before Limine is activated and after a failed activation.
# Only a cohort with a stage may have its ESP mounted at /boot or its root
# unlocked by busybox encrypt: the stage moves both. A legacy omarchy-mac
# install runs Omarchy from a checkout, trusts the rc4 fork keyring or carries
# the quattro tree, whose 3.x upgrade command quattro-upstream never had. A
# Mac on the omarchy-dev pair without the mx-mac fork's updaters, records or a
# test image's pin already runs Omarchy's own dev packages.
detect_cohort() {
  local list=$1
  if grep -Eq '^omarchy(-settings)?-dev ' "$list"; then
    if mx_mac_fork; then
      echo mx-mac
    elif [[ -n $(test_pin_block "$pacman_conf") ]]; then
      # A test image built from a dev pair candidate keeps it pinned.
      echo tester
    else
      echo official-dev
    fi
  elif ! grep -Eq '^omarchy ' "$list" || grep -Eq '^omarchy-mac-keyring ' "$list" ||
    [[ -e $R/usr/share/omarchy/bin/omarchy-upgrade-to-quattro-mac ]]; then
    echo legacy
  else
    echo tester
  fi
}

cohort_refusal() {
  echo "no adapter handles the $1 cohort"
}

# What stops a Mac running omarchy-dev from counting as a Mac on Omarchy's own
# dev channel: a retired repository or key, a repository trusted without
# signatures, or an [omarchy] served from anywhere but pkgs.omarchy.org.
official_trust_problems() {
  local conf repos repo fpr
  conf=$(cat "$1")
  repos=$(repositories_in <(printf '%s\n' "$conf"))
  for repo in "${retired_repos[@]}"; do
    ! grep -Fxq "$repo" <<<"$repos" || echo "[$repo]"
  done
  for fpr in "${retired_keys[@]}"; do
    ! key_present "$fpr" || echo "the key $fpr"
  done
  printf '%s\n' "$conf" | awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    name == "omarchy" && /^[[:space:]]*Server[[:space:]]*=/ && $0 !~ /=[[:space:]]*https:\/\/pkgs\.omarchy\.org\// { print "an [omarchy] server other than pkgs.omarchy.org" }
    /^[[:space:]]*SigLevel[[:space:]]*=/ && /TrustAll|Never/ { print "[" name "] without signature checks" }' | sort -u
}

# Runs the cohort's optional hook for a step.
adapter_hook() {
  local hook=${cohort//-/_}_$1
  shift
  if declare -F "$hook" >/dev/null; then
    "$hook" "$@"
  fi
}

# The LUKS partition beneath /, or nothing when / is not encrypted; fails when
# it cannot tell (as omarchy-drive-password decides it).
root_luks_device() {
  local source ancestry device
  source=$(findmnt -no SOURCE "$R/") && [[ -n $source ]] || return 1
  ancestry=$(lsblk -nsrpo NAME,TYPE,FSTYPE "${source%%[*}") || return 1
  device=$(awk '$3 == "crypto_LUKS" { print $1; exit }' <<<"$ancestry")
  if [[ -n $device ]]; then
    printf '%s\n' "$device"
  elif awk '$2 == "crypt" { found = 1 } END { exit !found }' <<<"$ancestry"; then
    return 1
  fi
}

free_bytes() {
  df -B1 --output=avail "$1" 2>/dev/null | tail -n 1 | tr -d ' '
}

bytes_used() {
  local bytes
  bytes=$(du -sxb "$1" 2>/dev/null | cut -f1)
  printf '%s\n' "${bytes:-0}"
}

# Running on battery below 30% is refused: the transaction and the boot switch
# must not lose power.
low_battery() {
  local supply capacity on_battery=0 low=0
  for supply in "$R"/sys/class/power_supply/*; do
    [[ -f $supply/type ]] || continue
    case $(<"$supply/type") in
      Battery)
        capacity=$(<"$supply/capacity") 2>/dev/null || capacity=100
        [[ $capacity =~ ^[0-9]+$ ]] && (( capacity < 30 )) && low=1
        on_battery=1
        ;;
      Mains | USB | USB_C | USB_PD)
        [[ $(cat "$supply/online" 2>/dev/null) == "1" ]] && return 1
        ;;
    esac
  done
  (( on_battery && low ))
}

# The configuration pacman reads: FILE with each Include replaced by the files
# it names, three levels deep.
pacman_conf_flat() {
  local file=$1 depth=${2:-0} line included
  while IFS= read -r line || [[ -n $line ]]; do
    if (( depth < 3 )) && [[ $line =~ ^[[:space:]]*Include[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
      # shellcheck disable=SC2086 # Include takes a glob
      for included in $R${BASH_REMATCH[1]}; do
        [[ ! -f $included ]] || pacman_conf_flat "$included" $(( depth + 1 ))
      done
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
}

# The administrator's repositories the switch keeps must not accept untrusted
# packages: the core configuration requires signatures.
pacman_trust_problems() {
  admin_repositories "$1" | awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    /^[[:space:]]*SigLevel[[:space:]]*=/ && /TrustAll|Never/ {
      value = $0; sub(/^[^=]*=[[:space:]]*/, "", value)
      print "[" name "] accepts untrusted packages (SigLevel = " value "); remove it or sign it first"
    }'
}

preflight() {
  local reasons=() installed boot_state kernels hooks="" check_output luks="" need esp_mount="" staged=0 channel
  local future transaction targets_file resolved name version problem official_problems="" names saved_path problems=()
  work=$(mktemp -d "$R/var/tmp/omarchy-mac-migrate.XXXXXX") || die "cannot create a work directory"
  chmod 755 "$work"
  installed=$work/installed
  installed_packages >"$installed" || die "cannot list the installed packages"
  pacman_conf_flat "$pacman_conf" >"$work/flat.conf" || die "cannot read $pacman_conf"

  [[ -d $R/run/systemd/system ]] || reasons+=("this is not a booted system (an image build or a chroot)")
  [[ ! -e $pacman_db/db.lck ]] || reasons+=("pacman is busy or was interrupted ($pacman_db/db.lck exists)")

  cohort=$(detect_cohort "$installed")
  # A Mac following Omarchy's own dev channel already runs official packages.
  # One that still trusts what the switch retires, or that an administrator
  # points at a target, is moved like a tester: its packages are named.
  if [[ $cohort == "official-dev" ]]; then
    official_problems=$(official_trust_problems "$work/flat.conf" | paste -sd, | sed 's/,/, /g')
    if [[ -z $official_problems && -z ${target_file:-} ]]; then
      say "This Mac runs Omarchy's own packages (omarchy-dev from pkgs.omarchy.org): nothing to migrate."
      exit 0
    fi
    cohort=tester
  fi
  declare -F "${cohort//-/_}_plan" >/dev/null || reasons+=("$(cohort_refusal "$cohort")")
  ! declare -F "${cohort//-/_}_stage" >/dev/null || staged=1

  kernels=$(awk '$1 == "linux-asahi" || $1 == "linux-aurora" { print $1 }' "$installed" | xargs)
  [[ $kernels == "linux-asahi" || $kernels == "linux-aurora" ]] ||
    reasons+=("expected one Apple kernel (linux-asahi or linux-aurora), found: ${kernels:-none}")

  if limine_mac; then
    boot_state=limine
  elif [[ -f $R/boot/grub/grub.cfg ]]; then
    boot_state=grub
  else
    boot_state=unknown
    reasons+=("cannot tell whether this Mac boots GRUB or Limine")
  fi
  # The Limine setup derives the kernel command line from GRUB's defaults.
  [[ -f $R/etc/default/grub ]] || reasons+=("there is no /etc/default/grub, which the Limine setup reads the kernel command line from")
  [[ -f $R/usr/share/pacman/keyrings/asahi-alarm.gpg ]] || reasons+=("asahi-alarm-keyring is not installed, so Asahi ALARM's packages cannot be verified")
  if ! luks=$(root_luks_device); then
    reasons+=("cannot tell whether the root filesystem is encrypted")
  fi
  if [[ -e $first_boot_marker || -e $legacy_first_boot_marker ]]; then
    reasons+=("first boot has not finished on this Mac")
  fi
  if low_battery; then
    reasons+=("the battery is below 30% and no charger is connected")
  fi
  while IFS= read -r problem; do
    [[ -z $problem ]] || reasons+=("$problem")
  done < <(pacman_trust_problems "$work/flat.conf"; unsupported_options "$pacman_conf")
  # The switch writes pacman.conf whole: a repository only an Include file
  # defines would be lost or doubled.
  for problem in $(comm -13 <(repositories_in "$pacman_conf" | LC_ALL=C sort -u) <(repositories_in "$work/flat.conf" | LC_ALL=C sort -u)); do
    reasons+=("[$problem] is configured through an Include, which the repository switch cannot rewrite; move it into $pacman_conf first")
  done

  # The target: the administrator's, else the channel this Mac follows.
  if [[ -z ${target_file:-} ]]; then
    if channel=$(detect_channel "$cohort" "$work/flat.conf"); then
      write_channel_target "$channel" "$work/target"
      target_file=$work/target
    else
      reasons+=("cannot tell which Omarchy channel this Mac follows (stable, rc or edge); set one in $admin_target")
    fi
  fi
  [[ -z ${target_file:-} ]] || load_target "$target_file"
  if [[ ${target_type:-} == "candidate-set" ]] && ! command -v gpgv >/dev/null; then
    reasons+=("gpgv is not installed (gnupg), so the candidate set's signatures cannot be checked")
  fi
  if (( ${#reasons[@]} )); then
    refuse "${reasons[@]}"
  fi

  # The target, read in isolation: a copy of the local database and the future
  # configuration, never the live sync databases. Signatures are checked
  # against a copy of the keyring that trusts the target's key, so preflight
  # never changes the live one.
  future=$work/pacman.conf
  future_pacman_conf "$pacman_conf" >"$future" || die "cannot compute the new pacman configuration"
  mkdir -p "$work/db"
  cp -a "$pacman_db/local" "$work/db/local" || die "cannot copy the package database"
  install -d -m 700 "$work/pacman-gnupg"
  tar -C "$pacman_gpg" --exclude='S.*' -cf - . | tar -C "$work/pacman-gnupg" -xf - || die "cannot copy the pacman keyring"
  gpgdir=$work/pacman-gnupg
  trust_official_key "$gpgdir" || refuse "cannot fetch and trust the Omarchy packaging key $target_keyring"
  # The trust the switch leaves: no retired fork key verifies anything from here.
  for name in "${retired_keys[@]}"; do
    if key_present "$name" "$gpgdir"; then
      pacman-key --gpgdir "$gpgdir" --delete "$name" >/dev/null 2>&1 || die "cannot drop $name from the keyring copy"
    fi
  done
  if [[ $target_type == "candidate-set" ]]; then
    install -d -m 755 "$work/candidate"
    if ! problem=$(copy_candidate_set "$target_set" "$work/set") || ! problem=$(verify_candidate_set "$work/set" "$work/gnupg"); then
      refuse "the candidate set does not verify: $problem"
    fi
    local loaded_id=$target_id
    target_set=$work/set
    candidate_identity "$target_set" || die "cannot read the candidate manifest"
    [[ $target_id == "$loaded_id" ]] || refuse "the candidate set changed while it was read"
    index_candidate_repo "$work/candidate" link || die "cannot index the candidate set"
  fi
  transaction=$work/transaction.conf
  transaction_conf "$future" "${target_set:+$work/candidate}" >"$transaction"
  pacman_run --config "$transaction" --dbpath "$work/db" --logfile "$work/pacman.log" -Sy --noconfirm >"$work/sync.log" 2>&1 ||
    refuse "cannot read the target repositories: $(tail -n 1 "$work/sync.log")"
  mapfile -t problems < <(presence_problems "$transaction" "$work/db")
  if (( ${#problems[@]} )); then
    say "The $target_channel channel has no Mac release yet; this Mac stays as it is until it has one."
    refuse "${problems[@]}"
  fi

  targets_file=$work/targets
  "${cohort//-/_}_plan" "$installed" "$work" "$luks" "" >"$work/adapter-targets" || die "the $cohort adapter could not plan this Mac"
  {
    cat "$work/adapter-targets"
    for name in $keyring_packages; do
      sed 's|^.*/||' "$work/adapter-targets" | grep -Fxq "$name" || printf '%s\n' "$name"
    done
  } >"$targets_file"
  names=$(sed 's|^.*/||' "$targets_file" | xargs)
  while IFS= read -r problem; do
    [[ -z $problem ]] || reasons+=("$pacman_conf holds back $problem, which the migration changes; remove it from IgnorePkg or IgnoreGroup first")
  done < <(pinned_targets "$pacman_conf" "$names $(xargs <"$work/allowed-removals")" "$work/db" "$transaction")
  (( ${#reasons[@]} == 0 )) || refuse "${reasons[@]}"
  resolved=$work/resolved
  # shellcheck disable=SC2046
  if ! pacman_run --config "$transaction" --dbpath "$work/db" --logfile "$work/pacman.log" -Sup --noconfirm --ask 4 \
    --print-format '%r/%n %v' $(plan_ignores "$work") $(cat "$targets_file") >"$resolved" 2>"$work/resolve.log"; then
    refuse "the target set does not resolve on this Mac: $(tail -n 1 "$work/resolve.log")"
  fi
  if [[ $target_type == "candidate-set" ]]; then
    while read -r name; do
      [[ $name == "$candidate_repo/"* ]] || continue
      version=$(target_version "${name#*/}")
      grep -Fxq "$name $version" "$resolved" || refuse "${name#*/} does not resolve to the candidate's $version"
    done <"$targets_file"
  fi

  mapfile -t problems < <(archive_problems "$resolved" "$transaction" "$work/db")
  if (( ${#problems[@]} )); then
    say "This Mac cannot move to the $target_channel channel's packages yet; it stays as it is."
    refuse "${problems[@]}"
  fi

  # The boot tools of the omarchy-mac-boot the transaction installs judge the
  # Mac from here on.
  payload_dir=$work/payload
  version=$(fetch_payload "$resolved" "$transaction" "$work/db" "$payload_dir") ||
    refuse "cannot take the boot tools from the target's omarchy-mac-boot: $version"
  saved_path=$PATH
  if (( fixture )); then
    PATH=$PATH:$payload_dir/usr/bin
  else
    PATH=$payload_dir/usr/bin:$PATH
  fi
  # The busybox encrypt hook matters only where it unlocks the root: legacy
  # omarchy-mac sets it on every Mac, and on an unencrypted one it does nothing.
  # Only a cohort whose stage moves that unlock (legacy) may carry it.
  if ! hooks=$(omarchy-mac-initramfs-hooks 2>/dev/null); then
    reasons+=("cannot read the initramfs HOOKS")
  elif [[ -n $luks && " $hooks " == *" encrypt "* ]] && (( ! staged )); then
    reasons+=("the root unlocks through busybox encrypt, which only the legacy omarchy-mac migration moves")
  fi
  # Installed boot files, not the running kernel: an update that just replaced
  # the kernel leaves a reboot pending, and the migration replaces it anyway.
  if ! check_output=$(boot_check_pending 2>&1); then
    reasons+=("the boot files are not coherent; repair them first: $(tail -n 1 <<<"$check_output")")
  fi
  # Limine and its UKI live on the ESP U-Boot boots, mounted at /boot/efi. A
  # cohort with a stage moves an ESP mounted at /boot there first.
  esp_mount=$(omarchy-mac-esp 2>/dev/null) || esp_mount=""
  if [[ $esp_mount == "/boot" ]] && (( staged )); then
    :
  elif [[ $esp_mount != "$esp" ]]; then
    reasons+=("the system ESP is not mounted at $esp")
  fi
  while IFS= read -r problem; do
    [[ -z $problem ]] || reasons+=("$problem")
  done < <(adapter_hook preflight "$installed" "$luks" "$hooks")
  need=$(( 4 * 1024 * 1024 * 1024 + $(bytes_used "$R/etc") + $(bytes_used "$R/boot") ))
  # An ESP mounted at /boot is also /boot: its kernel and initramfs move onto
  # the root filesystem.
  [[ $esp_mount != "/boot" ]] || need=$(( need + 512 * 1024 * 1024 ))
  (( $(free_bytes "$R/var/lib") >= need )) || reasons+=("the root filesystem needs $(( need / 1024 / 1024 )) MiB free for backups and downloads")
  (( $(free_bytes "$R${esp_mount:-$esp}") >= 64 * 1024 * 1024 )) || reasons+=("the ESP needs 64 MiB free")
  [[ $esp_mount == "/boot" ]] || (( $(free_bytes "$R/boot") >= 128 * 1024 * 1024 )) || reasons+=("/boot needs 128 MiB free")
  PATH=$saved_path
  if (( ${#reasons[@]} )); then
    refuse "${reasons[@]}"
  fi
  # The adapter's plan records the unlock its stage moves, now that the HOOKS
  # are known.
  if [[ $cohort == "legacy" ]]; then
    "${cohort//-/_}_plan" "$installed" "$work" "$luks" "$hooks" >"$work/adapter-targets" || die "the $cohort adapter could not plan this Mac"
  fi

  gpgdir=""
  if already_on_target "$installed" "$resolved" "$targets_file" "$future"; then
    say "This Mac already runs the target set ($target_id): nothing to migrate."
    exit 0
  fi
  if (( check_only )); then
    say "Ready: run moves this Mac ($cohort, $boot_state boot${luks:+, encrypted}) onto $target_id ($target_channel)."
    say "It installs: $names"
    [[ ! -s $work/allowed-removals ]] || say "It may remove: $(xargs <"$work/allowed-removals")"
    exit 0
  fi

  # Passed: freeze the plan. Nothing on the system has changed yet.
  install -d -m 755 "$(dirname "$state")" "$state"
  : >"$journal"
  printf 'journal_format=%s\n' "$journal_format" >"$state/format"
  sync "$journal" "$state/format"
  current_step=preflight
  journal_write preflight "begin" "$target_id"
  rm -rf "$plan.new"
  install -d -m 755 "$plan.new"
  cp "$installed" "$plan.new/installed"
  cp "$future" "$plan.new/pacman.conf"
  cp -a "$work/db/sync" "$plan.new/sync"
  guarded_pacman_conf "$future" "$pacman_conf" "$(printf '%s\n' $names $(xargs <"$work/allowed-removals") $guarded_boot | awk '!seen[$0]++' | xargs)" >"$plan.new/pacman.guarded.conf"
  cp "$targets_file" "$plan.new/targets"
  cp "$work/allowed-removals" "$plan.new/allowed-removals"
  cp "$work/kept" "$plan.new/kept" 2>/dev/null || : >"$plan.new/kept"
  cp "$work/removals" "$plan.new/removals" 2>/dev/null || : >"$plan.new/removals"
  [[ ! -d $work/adapter ]] || cp -r "$work/adapter" "$plan.new/adapter"
  cp "$target_file" "$plan.new/target"
  printf '%s\n' "$target_id" >"$plan.new/target-id"
  printf '%s\n' "$target_packages" >"$plan.new/target-packages"
  printf '%s\n' "$cohort" >"$plan.new/cohort"
  printf '%s\n' "$boot_state" >"$plan.new/boot"
  printf '%s\n' "$luks" >"$plan.new/luks"
  printf '%s\n' "$esp_mount" >"$plan.new/esp"
  for name in $fresh_user_units; do
    [[ ! -f $R/usr/lib/systemd/user/$name ]] || printf '%s\n' "$name"
  done >"$plan.new/user-units"
  find "$plan.new" -type f -exec sync {} +
  if [[ $target_type == "candidate-set" ]]; then
    rm -rf "$set_copy"
    mv "$work/set" "$set_copy" || die "cannot keep the verified candidate set"
    sync "$set_copy"/*
    target_set=$set_copy
  fi
  rm -rf "$plan"
  mv "$plan.new" "$plan"
  keep_tool || die "cannot keep a copy of this tool for the migration's resume"
  sync "$state"
  interrupt_for_test during preflight
  journal_write preflight "done"
  interrupt_for_test after preflight
  current_step=""
}

refuse() {
  if [[ -f $journal && $(step_state preflight) == "done" && ! -f $complete ]]; then
    die "$*"
  fi
  say "The migration was refused before anything changed:" >&2
  printf '  - %s\n' "$@" >&2
  install -d -m 755 "$state" 2>/dev/null &&
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" | durable_write "$state/deferred" 2>/dev/null || true
  exit 75
}

# Every target is installed at the version the target resolves to, the
# configuration is already the future one and no retired key is trusted.
# Ordinary upgrades of other packages are omarchy update's business.
already_on_target() {
  local installed=$1 resolved=$2 targets=$3 future=$4 target name version fpr
  cmp -s "$future" "$pacman_conf" || return 1
  while read -r target; do
    name=${target#*/}
    version=$(awk -v name="$name" '{ sub(/^[^\/]*\//, "", $1) } $1 == name { print $2; exit }' "$resolved")
    [[ -n $version && $(installed_version "$name" "$installed") == "$version" ]] || return 1
  done <"$targets"
  for fpr in "${retired_keys[@]}"; do
    ! key_present "$fpr" || return 1
  done
}

# --- Steps -------------------------------------------------------------------

# The frozen plan: the target as preflight read it, the candidate set as it
# verified it. Nothing is read from the original set again.
load_plan() {
  target_file=$plan/target
  load_target "$target_file" frozen
  target_id=$(<"$plan/target-id")
  target_packages=$(<"$plan/target-packages")
  cohort=$(<"$plan/cohort")
}

plan_targets() {
  cat "$plan/targets"
}

# Where the ESP was mounted at preflight: /boot/efi, or /boot where the
# cohort's stage moves it.
plan_esp() {
  if [[ -s $plan/esp ]]; then
    cat "$plan/esp"
  else
    printf '%s\n' "$esp"
  fi
}

# Unqualified names of every package the transaction replaces or may remove.
plan_package_names() {
  { sed 's|^.*/||' "$plan/targets"; cat "$plan/allowed-removals"; } | sort -u
}

step_backup() {
  local partial=$state/backup.partial name version file found luks esp_mount
  esp_mount=$(plan_esp)
  rm -rf "$partial"
  install -d -m 700 "$partial" "$partial/packages"
  cp "$plan/installed" "$partial/installed"
  : >"$partial/packages.missing"
  while read -r name; do
    version=$(installed_version "$name" "$plan/installed")
    [[ -n $version ]] || continue
    found=0
    for file in "$pacman_cache/$name-$version"-*.pkg.tar.*; do
      [[ -f $file ]] || continue
      cp -p "$file" "$partial/packages/" || die "cannot copy $file into the backup"
      found=1
    done
    (( found )) || printf '%s %s\n' "$name" "$version" >>"$partial/packages.missing"
  done < <(plan_package_names)
  tar -C "$R/" --xattrs --acls -cpf "$partial/etc.tar" etc 2>"$partial/etc.log" || die "cannot back up /etc"
  interrupt_for_test mid backup
  # An ESP mounted at /boot is /boot: esp.tar holds it.
  if [[ $esp_mount != "/boot" ]]; then
    tar -C "$R/boot" --one-file-system -cpf "$partial/boot.tar" . || die "cannot back up /boot"
  fi
  tar -C "$R$esp_mount" -cpf "$partial/esp.tar" . || die "cannot back up the ESP"
  luks=$(<"$plan/luks")
  if [[ -n $luks ]]; then
    cryptsetup luksHeaderBackup "$luks" --header-backup-file "$partial/luks-header.img" ||
      die "cannot back up the LUKS header of $luks"
  fi
  (cd "$partial" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS) ||
    die "cannot record the backup's digests"
  find "$partial" -type f -exec sync {} + || die "cannot sync the backup"
  rm -rf "$backup"
  mv "$partial" "$backup" || die "cannot finish the backup"
  sync "$state"
  if [[ -s $backup/packages.missing ]]; then
    say "Not in the package cache, so not backed up: $(awk '{ print $1 }' "$backup/packages.missing" | xargs)"
  fi
}

# Official trust, bootstrapped without any repository the switch retires: the
# keyrings already installed are populated, and a missing Omarchy key comes
# from the keyserver by its full fingerprint and is signed locally. A candidate
# set's key never enters pacman's keyring.
step_keyring() {
  local keyrings=() name
  for name in archlinuxarm asahi-alarm omarchy; do
    [[ ! -f $R/usr/share/pacman/keyrings/$name.gpg ]] || keyrings+=("$name")
  done
  if (( ${#keyrings[@]} )); then
    pacman-key --gpgdir "$pacman_gpg" --populate "${keyrings[@]}" >/dev/null || die "cannot populate the keyrings: ${keyrings[*]}"
  fi
  interrupt_for_test mid keyring
  if ! key_trusted "$target_keyring"; then
    pacman-key --gpgdir "$pacman_gpg" --keyserver hkps://keys.openpgp.org --recv-keys "$target_keyring" >/dev/null &&
      pacman-key --gpgdir "$pacman_gpg" --lsign-key "$target_keyring" >/dev/null ||
      die "cannot fetch and trust the Omarchy key $target_keyring"
  fi
  key_trusted "$target_keyring" || die "the Omarchy key $target_keyring is not trusted after the bootstrap"
}

# What the transaction may remove stays out of the upgrade: an official build
# of the same name that conflicts with a target (stock omarchy, which the
# omarchy-dev pair replaces on edge) would otherwise join the transaction, and
# pacman drops one of the two. Left alone, it leaves through the target's
# conflict, or by name after the transaction.
plan_ignores() {
  local dir=${1:-$plan} names
  names=$(cat "$dir/removals" "$dir/allowed-removals" 2>/dev/null | awk 'NF' | LC_ALL=C sort -u | paste -sd,)
  [[ -z $names ]] || printf -- '--ignore=%s\n' "$names"
  return 0
}

# Packages the transaction removes by name once it has installed the targets,
# as far as DB still has them. By exact name: pacman -Q NAME also answers with
# a package that provides NAME (mise-bin for mise), which pacman -R refuses.
plan_removals() {
  local db=$1 name installed
  [[ -f $plan/removals ]] || return 0
  installed=$(LC_ALL=C pacman --config "$pacman_conf" --dbpath "$db" -Qq) || return 1
  while read -r name; do
    [[ -n $name ]] && grep -Fxq -- "$name" <<<"$installed" && printf '%s\n' "$name"
  done <"$plan/removals"
  return 0
}

# Paths the installed package NAME owns in DB that another package there owns
# too. pacman -R deletes every file of the package it removes, whoever else
# owns it, so a planned removal that hands files over (omarchy-dev's commands
# to omarchy-mac-boot) must leave inside the transaction, through the conflict
# of the package that replaces it, never in the removals after it.
shared_files() {
  local db=$1 name=$2
  LC_ALL=C pacman --config "$pacman_conf" --dbpath "$db" -Ql 2>/dev/null | awk -v name="$name" '
    { owner = $1; path = $0; sub(/^[^ ]+ /, "", path) }
    path ~ /\/$/ { next }
    owner == name { mine[path] = 1; next }
    { other[path] = 1 }
    END { for (path in mine) if (path in other) print path }' | LC_ALL=C sort
}

# Downloads and verifies every package the transaction needs, then rehearses the
# transaction on a copy of the package database (--dbonly: no files, scripts or
# hooks) to learn exactly what it installs and removes. Signatures are checked
# against the trust the switch leaves, a copy of the keyring without the
# retired keys, so nothing that needs a fork key gets this far.
step_prefetch() {
  local db=$cache/db rehearsal=$cache/rehearsal conf=$cache/transaction.conf removed name version bad=() fpr removals shared
  install -d -m 755 "$cache" "$cache/pkg"
  rm -rf "$db" "$rehearsal" "$cache/candidate" "$cache/trust"
  mkdir -p "$db"
  cp -a "$pacman_db/local" "$db/local" || die "cannot copy the package database"
  LC_ALL=C pacman --config "$pacman_conf" --dbpath "$db" -Q >"$cache/start" || die "cannot read the package database copy"
  if [[ $target_type == "candidate-set" ]]; then
    stage_candidate_repo "$cache/candidate" "$cache/gnupg" || die "the candidate set does not verify"
  fi
  install -d -m 700 "$cache/trust"
  tar -C "$pacman_gpg" --exclude='S.*' -cf - . | tar -C "$cache/trust" -xf - || die "cannot copy the pacman keyring"
  for fpr in "${retired_keys[@]}"; do
    if key_present "$fpr"; then
      pacman-key --gpgdir "$cache/trust" --delete "$fpr" >/dev/null 2>&1 || die "cannot drop $fpr from the keyring copy"
    fi
  done
  gpgdir=$cache/trust
  transaction_conf "$plan/pacman.conf" "${target_set:+$cache/candidate}" >"$conf"
  # The databases preflight qualified, never a newer sync: the transaction
  # installs exactly the set preflight checked.
  cp -a "$plan/sync" "$db/sync" || die "cannot copy the frozen package databases"
  # shellcheck disable=SC2046
  pacman_run --config "$conf" --dbpath "$db" --cachedir "$cache/pkg" --cachedir "$pacman_cache" --logfile "$cache/pacman.log" \
    -Suw --noconfirm --ask 4 $(plan_ignores) $(plan_targets) || die "cannot download and verify the target set"
  interrupt_for_test mid prefetch
  cp -a "$db" "$rehearsal"
  # shellcheck disable=SC2046
  pacman_run --config "$conf" --dbpath "$rehearsal" --cachedir "$cache/pkg" --cachedir "$pacman_cache" --logfile "$cache/pacman.log" \
    --dbonly -Su --noconfirm --ask 4 $(plan_ignores) $(plan_targets) >"$cache/rehearsal.log" 2>&1 ||
    die "the rehearsed transaction failed: $(tail -n 1 "$cache/rehearsal.log")"
  removals=$(plan_removals "$rehearsal" | xargs)
  for name in $removals; do
    shared=$(shared_files "$rehearsal" "$name" | head -n 3 | xargs)
    [[ -z $shared ]] ||
      die "the transaction would leave $name to be removed after it, but the packages it installs also own $shared; nothing was changed"
  done
  if [[ -n $removals ]]; then
    # shellcheck disable=SC2086
    pacman_run --config "$conf" --dbpath "$rehearsal" --logfile "$cache/pacman.log" --dbonly -R --noconfirm $removals \
      >>"$cache/rehearsal.log" 2>&1 || die "the rehearsed removal of $removals failed: $(tail -n 1 "$cache/rehearsal.log")"
  fi
  gpgdir=""
  gpgconf --homedir "$cache/trust" --kill all >/dev/null 2>&1 || true
  LC_ALL=C pacman --config "$conf" --dbpath "$rehearsal" -Q >"$cache/expected" || die "cannot read the rehearsed result"
  removed=$(comm -23 <(awk '{ print $1 }' "$cache/start" | LC_ALL=C sort) <(awk '{ print $1 }' "$cache/expected" | LC_ALL=C sort))
  for name in $removed; do
    grep -Fxq "$name" "$plan/allowed-removals" || bad+=("$name")
  done
  (( ${#bad[@]} == 0 )) || die "the transaction would also remove ${bad[*]}; nothing was changed"
  # pacman can drop a named target that conflicts with another package of the
  # transaction; every target must end installed.
  while read -r name; do
    [[ -n $(installed_version "${name#*/}" "$cache/expected") ]] ||
      die "the rehearsed transaction would not install ${name#*/}; nothing was changed"
  done < <(plan_targets)
  if [[ $target_type == "candidate-set" ]]; then
    while read -r name; do
      [[ $name == "$candidate_repo/"* ]] || continue
      version=$(target_version "${name#*/}")
      [[ $(installed_version "${name#*/}" "$cache/expected") == "$version" ]] || die "${name#*/} would not end at the candidate's $version"
    done < <(plan_targets)
  fi
  adapter_hook prefetch || die "the $cohort adapter refused the rehearsed transaction; nothing was changed"
  durable_write "$start" <"$cache/start" && durable_write "$expected" <"$cache/expected" ||
    die "cannot record the rehearsed transaction"
}

# The installed packages no longer match what the rehearsal started from: an
# omarchy update ran in between, or a transaction was cut short. The
# transaction is rehearsed again from what is installed now.
system_moved() {
  installed_packages >"$state/installed.now" || die "cannot list the installed packages"
  ! cmp -s "$state/installed.now" "$start"
}

restart_from_prefetch() {
  local step
  (( ++restarts <= 3 )) || die "the system keeps changing under the migration ($1); run it again when nothing else updates"
  say "The system changed since the transaction was rehearsed ($1); rehearsing it again"
  for step in prefetch repositories transaction; do
    journal_write "$step" "reset" "$1"
  done
  restarted=1
}

# The sync databases the rehearsal resolved against, over any a later sync left.
# A signature the rehearsal has none of belongs to the database it replaces
# (a fork's signed [omarchy]), and pacman rejects a database beside a
# signature that does not match it.
install_rehearsed_databases() {
  local repo extension
  for repo in $(repositories_in "$cache/transaction.conf"); do
    for extension in db db.sig; do
      if [[ ! -f $cache/db/sync/$repo.$extension ]]; then
        [[ $extension != "db.sig" || ! -f $cache/db/sync/$repo.db ]] || rm -f "$pacman_db/sync/$repo.db.sig"
        continue
      fi
      cmp -s "$cache/db/sync/$repo.$extension" "$pacman_db/sync/$repo.$extension" && continue
      durable_write "$pacman_db/sync/$repo.$extension" 644 <"$cache/db/sync/$repo.$extension" ||
        die "cannot install the $repo database"
    done
  done
}

# The process holding pacman's lock: libalpm keeps it open while it works.
lock_holder() {
  local fd
  for fd in "$R"/proc/[0-9]*/fd/*; do
    if [[ $(readlink "$fd" 2>/dev/null) == "$pacman_db/db.lck" ]]; then
      fd=${fd#"$R/proc/"}
      printf '%s\n' "${fd%%/*}"
      return 0
    fi
  done
  return 1
}

# Official repository precedence and no legacy trust: the frozen
# configuration, the sync databases the rehearsal used, no retired database or
# fork key. Until the transaction is done the configuration carries the
# migration's guard (and a test image keeps its pin), so a plain pacman -Syu in
# between moves none of the packages the transaction is about to change.
step_repositories() {
  local repo extension fpr
  if system_moved; then
    restart_from_prefetch "before the repository switch"
    return 0
  fi
  # From here on the fork's own update may be gone with its packages: a boot
  # resumes whatever is left.
  keep_tool && write_verify_unit && systemctl enable "$verify_unit" >/dev/null 2>&1 ||
    die "cannot install $verify_unit, which resumes the migration at boot"
  if ! cmp -s "$plan/pacman.guarded.conf" "$pacman_conf"; then
    durable_write "$pacman_conf" 644 <"$plan/pacman.guarded.conf" || die "cannot write $pacman_conf"
  fi
  interrupt_for_test mid repositories
  install_rehearsed_databases
  for repo in "${retired_repos[@]}"; do
    rm -f "$pacman_db/sync/$repo".{db,db.sig,files,files.sig}
  done
  for fpr in "${retired_keys[@]}"; do
    if key_present "$fpr"; then
      pacman-key --gpgdir "$pacman_gpg" --delete "$fpr" >/dev/null || die "cannot remove the retired key $fpr"
    fi
  done
}

# Something rewrote pacman.conf or trusted a retired key again since the
# switch: on an mx-mac Mac, the fork's own omarchy update, whose channel
# updaters stay until the transaction removes them.
switch_undone() {
  local fpr
  cmp -s "$plan/pacman.guarded.conf" "$pacman_conf" || return 0
  for fpr in "${retired_keys[@]}"; do
    ! key_present "$fpr" || return 0
  done
  return 1
}

# The installed packages with the planned removals left out.
without_removals() {
  awk 'NR == FNR { drop[$1]; next } !($1 in drop)' "$plan/removals" "$1"
}

# The targets are installed and only the planned removals are left.
removals_pending() {
  [[ -f $plan/removals ]] && ! cmp -s "$state/installed.now" "$expected" &&
    cmp -s <(without_removals "$state/installed.now") "$expected"
}

# A path as a pacman --overwrite glob that matches only itself.
overwrite_glob() {
  sed 's/[][*?\\]/\\&/g' <<<"$1"
}

# One transaction from the prefetched cache and databases, without a new sync:
# it installs exactly what was verified and rehearsed. Same-name packages are
# named explicitly, so a higher installed version is replaced too. A lock left
# by a transaction that was killed means its hooks may not have run, so the
# transaction runs again even when the packages are all in place. The adapter
# prepares the system for it first and may list, in $state/overwrite, files no
# package owns that it may replace; when pacman fails, the adapter restores
# what it prepared. Planned removals run after it, by name.
step_transaction() {
  local holder interrupted=0 overwrite=() remove=() path removal shared
  if [[ -e $pacman_db/db.lck ]]; then
    if holder=$(lock_holder); then
      die "pacman is running (process $holder); run the migration again when it has finished"
    fi
    say "Removing the pacman lock an interrupted transaction left behind"
    : | durable_write "$interrupted_marker" || die "cannot record the interrupted transaction"
    rm -f "$pacman_db/db.lck"
  fi
  # Kept across a new rehearsal until a transaction has run to its end.
  [[ ! -e $interrupted_marker ]] || interrupted=1
  if switch_undone; then
    restart_from_prefetch "pacman.conf or a retired key came back after the repository switch"
    return 0
  fi
  if system_moved && ! cmp -s "$state/installed.now" "$expected" && ! removals_pending; then
    restart_from_prefetch "before the transaction"
    return 0
  fi
  if (( interrupted )) || ! cmp -s "$state/installed.now" "$expected"; then
    install_rehearsed_databases
    if (( interrupted )) || ! removals_pending; then
      rm -f "$state/overwrite"
      if ! adapter_hook prepare; then
        adapter_hook restore
        die "the $cohort adapter could not prepare the transaction"
      fi
      if [[ -f $state/overwrite ]]; then
        while IFS= read -r path; do
          [[ -z $path ]] || overwrite+=(--overwrite "$(overwrite_glob "$path")")
        done <"$state/overwrite"
      fi
      # shellcheck disable=SC2046
      if ! pacman_run --config "$cache/transaction.conf" --dbpath "$pacman_db" --cachedir "$cache/pkg" --cachedir "$pacman_cache" \
        -Su --noconfirm --ask 4 "${overwrite[@]}" $(plan_ignores) $(plan_targets); then
        adapter_hook restore
        die "the package transaction failed"
      fi
    fi
    interrupt_for_test mid removals
    mapfile -t remove < <(plan_removals "$pacman_db")
    for removal in "${remove[@]}"; do
      shared=$(shared_files "$pacman_db" "$removal" | head -n 3 | xargs)
      [[ -z $shared ]] || die "cannot remove $removal: other packages also own $shared, which pacman -R would delete"
    done
    if (( ${#remove[@]} )); then
      pacman_run --config "$cache/transaction.conf" --dbpath "$pacman_db" -R --noconfirm "${remove[@]}" ||
        die "cannot remove ${remove[*]}"
    fi
    installed_packages >"$state/installed.now" || die "cannot list the installed packages"
    cmp -s "$state/installed.now" "$expected" ||
      die "the installed packages differ from the rehearsed transaction: $(diff "$expected" "$state/installed.now" | grep '^[<>]' | head -n 3 | xargs)"
    rm -f "$interrupted_marker"
  fi
  rm -f "$pacman_db/sync/$candidate_repo".{db,db.sig}
  # Fresh-image provisioning is never armed on an existing machine (preflight
  # refuses one whose first boot is unfinished).
  if [[ -e $first_boot_marker || -e $legacy_first_boot_marker ]]; then
    say "Disarming the first-boot setup the transaction left on this installed Mac"
    rm -f "$first_boot_marker" "$legacy_first_boot_marker"
  fi
}

# The new packages are installed, set up and verified: the configuration loses
# the migration's guard and a test image's pin, and is the core one from here
# on.
step_unpin() {
  if ! cmp -s "$plan/pacman.conf" "$pacman_conf"; then
    durable_write "$pacman_conf" 644 <"$plan/pacman.conf" || die "cannot write $pacman_conf"
  fi
  interrupt_for_test mid unpin
  pacman-key --gpgdir "$pacman_gpg" --populate $(installed_keyrings) >/dev/null || die "cannot populate the installed keyrings"
}

# The keyrings pacman-key can populate from what is installed now.
installed_keyrings() {
  local name
  for name in archlinuxarm asahi-alarm omarchy; do
    [[ ! -f $R/usr/share/pacman/keyrings/$name.gpg ]] || printf '%s\n' "$name"
  done
}

# Aurora, m1n1 and U-Boot came with the transaction; their stage-two image
# (m1n1, the device trees and U-Boot) and the kernel's menu are rebuilt and
# checked. The loader U-Boot starts is not touched here.
step_boot_chain() {
  local output
  update-m1n1 >/dev/null || die "update-m1n1 could not rebuild m1n1, the device trees and U-Boot"
  interrupt_for_test mid boot-chain
  if [[ $(<"$plan/boot") == "limine" ]]; then
    omarchy-mac-limine-cmdline && limine-update >/dev/null || die "cannot rebuild the Limine menu and UKI"
  else
    update-grub >/dev/null || die "cannot rebuild the GRUB menu"
  fi
  output=$(boot_check_pending linux-aurora 2>&1) || die "the rebuilt boot files do not check: $(tail -n 1 <<<"$output")"
}

# The installed omarchy-mac-boot's setup-boot, through the new runtime's
# dispatcher, activates Limine (or refreshes it on a Limine Mac): it stages and
# verifies Limine before it takes U-Boot's EFI slot and restores every file it
# touched when anything fails, so a failed activation leaves the previous
# loader booting. On a GRUB Mac the cohort's stage runs first, while GRUB still
# boots the Mac, and is undone when it or the activation fails. A switch cut
# short is run again from its start.
step_loader() {
  local output uki=$R$esp/EFI/Linux/omarchy_linux-aurora.efi
  if [[ $(<"$plan/boot") == "limine" ]]; then
    interrupt_for_test mid loader
    omarchy-lifecycle-dispatch setup-boot >/dev/null || die "setup-boot could not refresh Limine; the previous loader stays"
  else
    if ! adapter_hook stage; then
      adapter_hook unstage || die "the $cohort adapter could not stage the boot switch, nor undo it; GRUB is still the loader"
      die "the $cohort adapter could not stage the boot switch; GRUB is still the loader"
    fi
    install -D -m 644 /dev/null "$limine_gate" || die "cannot mark this Mac for Limine"
    interrupt_for_test mid loader
    if ! omarchy-lifecycle-dispatch setup-boot >/dev/null; then
      rm -f "$limine_gate"
      adapter_hook unstage || die "Limine could not be activated, and the $cohort adapter could not undo its stage; GRUB is still the loader"
      die "Limine could not be activated; GRUB is still the loader"
    fi
  fi
  [[ -s $uki ]] && grep -Fq "boot():/EFI/Linux/omarchy_linux-aurora.efi" "$R$esp/limine.conf" ||
    die "Limine has no linux-aurora UKI entry after setup-boot"
  cmp -s "$R/usr/share/limine/BOOTAA64.EFI" "$R$esp/EFI/BOOT/BOOTAA64.EFI" || die "the ESP loader is not the packaged Limine"
  output=$(boot_check_pending linux-aurora 2>&1) || die "the staged boot chain does not check: $(tail -n 1 <<<"$output")"
}

# Runs a command as USER, whose home is HOME, in a clean environment, so
# nothing root does follows a link the user controls.
as_user() {
  local user=$1 home=$2
  shift 2
  if (( fixture )); then
    env HOME="$home" "$@"
  else
    runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" PATH="$PATH" "$@"
  fi
}

# Accounts that have used Omarchy: a regular UID and Omarchy's state in the home.
omarchy_users() {
  local user home
  awk -F: '$3 >= 1000 && $3 < 60000 { print $1, $6 }' "$R/etc/passwd" 2>/dev/null |
    while read -r user home; do
      [[ ! -d $R$home/.local/state/omarchy ]] || printf '%s %s\n' "$user" "$home"
    done
}

# Enables a user unit by the links its [Install] WantedBy names, as
# systemctl --user enable writes them for these units. A mask, an override or any enablement, the user's
# or the administrator's, stays as it is.
enable_user_unit() {
  local user=$1 home=$2 unit=$3 config=$R$2/.config/systemd/user target path
  [[ -f $R/usr/lib/systemd/user/$unit ]] || return 0
  for path in "$config/$unit" "$R/etc/systemd/user/$unit" "$config"/*.wants/"$unit" "$R/etc/systemd/user"/*.wants/"$unit"; do
    [[ ! -e $path && ! -L $path ]] || return 0
  done
  for target in $(awk -F= '/^\[/ { install = ($0 == "[Install]") } install && $1 == "WantedBy" { print $2 }' "$R/usr/lib/systemd/user/$unit"); do
    as_user "$user" "$R$home" mkdir -p "$config/$target.wants" &&
      as_user "$user" "$R$home" ln -s "/usr/lib/systemd/user/$unit" "$config/$target.wants/$unit" || return 1
  done
}

# What omarchy update checks before it offers a reboot, through the new
# runtime's dispatcher: the boot files the next boot reads.
update_verify() {
  local output
  output=$(omarchy-lifecycle-dispatch update-verify 2>&1) || die "update-verify does not pass: $(grep -v '^[[:space:]]*$' <<<"$output" | head -n 2 | xargs)"
}

step_verify() {
  update_verify
}

# The unit that finishes the migration after its reboot runs the copy of this
# tool the migration keeps, so it works whatever else is installed.
write_verify_unit() {
  local unit
  unit="[Unit]
Description=Finish the Omarchy Mac migration after its reboot
# Either condition starts it: a migration past its repository switch and not
# complete, or user setup a migration left pending, retried at every boot until
# it succeeds.
ConditionPathExists=|/var/lib/omarchy-mac/migration/journal
ConditionPathExists=|/var/lib/omarchy-mac/migration/user-pending
Wants=network-online.target
After=local-fs.target network-online.target

[Service]
Type=oneshot
ExecStart=${tool_copy#"$R"} verify

[Install]
WantedBy=multi-user.target"
  [[ -f $verify_unit_file && $(<"$verify_unit_file") == "$unit" ]] && return 0
  install -d -m 755 "$(dirname "$verify_unit_file")" &&
    printf '%s\n' "$unit" | durable_write "$verify_unit_file" 644 &&
    { systemctl daemon-reload >/dev/null 2>&1 || true; }
}

# Waits for a reboot; after it, the new chain must have booted Aurora through
# Limine with every boot file coherent. The boot waited for stays recorded
# until retire, so a verification cut short is repeated on the same boot.
step_reboot() {
  local staged current release output
  current=$(boot_id)
  if [[ ! -s $reboot_pending ]]; then
    printf '%s\n' "$current" | durable_write "$reboot_pending" || die "cannot record the boot to wait for"
  fi
  interrupt_for_test mid reboot
  keep_tool && write_verify_unit || die "cannot install $verify_unit, which verifies the next boot"
  systemctl enable "$verify_unit" >/dev/null 2>&1 || die "cannot enable $verify_unit, which verifies the next boot"
  staged=$(<"$reboot_pending")
  if [[ $current == "$staged" ]]; then
    say "Reboot to finish the migration to $target_id. The next boot verifies the new boot chain."
    current_step=""
    exit 0
  fi
  release=$(kernel_release linux-aurora) || die "linux-aurora has no module tree"
  [[ $(<"$R/proc/sys/kernel/osrelease") == "$release" ]] ||
    die "this boot runs $(<"$R/proc/sys/kernel/osrelease"), not linux-aurora $release; the backups are in $backup"
  limine_mac && cmp -s "$R/usr/share/limine/BOOTAA64.EFI" "$R$esp/EFI/BOOT/BOOTAA64.EFI" ||
    die "this Mac did not boot through the packaged Limine"
  output=$(omarchy-apple-silicon-boot-check --boot-chain linux-aurora 2>&1) || die "the boot check failed after the reboot: $(tail -n 1 <<<"$output")"
  update_verify
}

# The completion record comes first: what is left after it is only cleanup,
# which every later run repeats until it is done.
step_retire() {
  "${cohort//-/_}_retire" || die "the $cohort adapter could not retire its compatibility state"
  printf 'target=%s\ncompleted=%s\n' "$target_id" "$(date +%Y-%m-%dT%H:%M:%S%z)" | durable_write "$complete" ||
    die "cannot record the completed migration"
  interrupt_for_test mid retire
  tidy_completed
}

# The post-reboot unit is released once the working state is gone and no user
# setup is pending; while some is, it stays enabled to retry at every boot.
tidy_completed() {
  local working=0 release=0
  if [[ -e $reboot_pending || -d $cache || -d $set_copy ]]; then
    working=1
    release=1
  fi
  if [[ -s $user_pending ]]; then
    if retry_user_pending; then
      release=1
    else
      release=0
    fi
  fi
  if (( release )); then
    release_verify_unit
  fi
  if (( working )); then
    rm -rf "$cache" "$set_copy" "$state/installed.now" "$state/overwrite"
    rm -f "$reboot_pending"
  fi
}

# The post-reboot unit goes once nothing is left for it to do, and with it,
# outside a migration in progress, the copy of the tool it runs.
release_verify_unit() {
  systemctl disable "$verify_unit" >/dev/null 2>&1 || say "Could not disable $verify_unit; it does nothing from now on."
  if [[ -f $verify_unit_file ]]; then
    rm -f "$verify_unit_file"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [[ -f $complete || ! -f $journal ]]; then
    rm -rf "$state/tool"
  fi
}

# A copy of this tool beside the journal: the post-reboot unit runs it, and a
# migration in progress resumes with it (see hand_over).
keep_tool() {
  [[ $self != "$tool_copy" ]] || return 0
  cmp -s "$self" "$tool_copy" && return 0
  install -d -m 755 "$(dirname "$tool_copy")" &&
    install -m 755 "$self" "$tool_copy.new" && sync "$tool_copy.new" && mv -f "$tool_copy.new" "$tool_copy"
}

# The tool_version and journal_format a copy of the tool declares.
tool_field() {
  sed -n "s/^$1=\([0-9][0-9]*\)$/\1/p" "$2" | head -n 1
}

# A migration in progress continues with the tool that started it, unless this
# one resumes the same journal format and is at least as new: then this one
# takes over and becomes the kept copy.
hand_over() {
  local version format
  [[ -f $tool_copy && $self != "$tool_copy" ]] || return 0
  version=$(tool_field tool_version "$tool_copy")
  format=$(tool_field journal_format "$tool_copy")
  if [[ $format == "$journal_format" ]] && (( tool_version >= ${version:-0} )); then
    keep_tool || die "cannot update the kept copy of this tool"
    return 0
  fi
  say "Resuming with the tool this migration started with (version ${version:-unknown})"
  exec "$tool_copy" "$@"
}

# --- Commands ----------------------------------------------------------------

# Another run holding the lock owns the migration's state: this one leaves it
# alone, failing once the migration is past its switch and deferring before.
# A copy of the tool handed the migration keeps the lock it inherited.
take_lock() {
  install -d -m 755 "$(dirname "$lock_file")"
  if [[ $(readlink "/proc/$$/fd/9" 2>/dev/null) != "$(realpath -m "$lock_file")" ]]; then
    exec 9>"$lock_file"
  fi
  if ! flock -n 9; then
    echo "omarchy-mac-migrate: another migration run is in progress" >&2
    if past_boundary; then
      exit 1
    fi
    exit 75
  fi
}

resume_steps() {
  local step event
  while step=$(next_step) && [[ -n $step ]]; do
    [[ $step != "preflight" ]] || die "the migration has no finished preflight"
    event=$(step_state "$step")
    [[ -z $event || $event == "reset" || $step == "reboot" ]] || say "Resuming the migration at $step"
    run_step "$step"
  done
  say "This Mac now runs $target_id. Backups stay in $backup."
}

migrate_run() {
  local target_arg="" candidate
  while (( $# )); do
    case $1 in
      --target) target_arg=${2:?--target needs a file}; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done

  platform=$(hardware_platform) || die "cannot determine the hardware platform"
  if [[ $platform != "apple-silicon" ]]; then
    say "Not an Apple Silicon Mac: nothing to migrate."
    return 0
  fi
  take_lock
  if [[ -f $journal && $(step_state preflight) == "done" && ! -f $complete ]]; then
    hand_over "${original_args[@]}"
  fi
  trap on_exit EXIT

  if [[ -f $complete && -f $plan/target-id ]]; then
    tidy_completed
    candidate=$(find_target "$target_arg")
    if [[ -n $candidate ]]; then
      load_target "$candidate"
    fi
    if [[ -z $candidate || $target_id == "$(<"$plan/target-id")" ]]; then
      say "Already migrated to $(<"$plan/target-id")."
      return 0
    fi
    (( check_only )) || archive_state
  else
    # User setup an earlier migration left pending runs first, whatever this
    # run does next.
    (( check_only )) || retry_user_pending_now
  fi

  if [[ -f $journal && $(step_state preflight) == "done" && ! -f $complete ]]; then
    if [[ -n $target_arg ]] && ! cmp -s "$target_arg" "$plan/target"; then
      die "a migration to $(<"$plan/target-id") is in progress; finish it before choosing another target"
    fi
    if (( check_only )); then
      migrate_status
      return 0
    fi
    load_plan
    resume_steps
    return 0
  fi

  target_file=$(find_target "$target_arg")
  preflight
  resume_steps
}

# Keeps a finished migration's record and backups beside the next one.
archive_state() {
  local destination
  destination=$state/history/$(date +%s)
  install -d -m 700 "$destination"
  mv "$journal" "$plan" "$start" "$expected" "$complete" "$destination/" 2>/dev/null
  [[ ! -f $repaired ]] || mv "$repaired" "$destination/"
  [[ ! -d $backup ]] || mv "$backup" "$destination/"
}

# Run by omarchy-mac-migrate-verify.service at boot: continues a migration that
# is waiting for, or past, its reboot, and does nothing otherwise.
migrate_verify() {
  platform=$(hardware_platform) || die "cannot determine the hardware platform"
  [[ $platform == "apple-silicon" ]] || return 0
  past_boundary || [[ -s $user_pending ]] || return 0
  take_lock
  if past_boundary; then
    hand_over "${original_args[@]}"
  fi
  trap on_exit EXIT
  if [[ -f $complete ]]; then
    tidy_completed
    return 0
  fi
  retry_user_pending_now
  past_boundary || return 0
  load_plan
  resume_steps
}

# A migration that has started its repository switch and is not complete.
past_boundary() {
  [[ -f $journal && ! -f $complete ]] && ! before_boundary
}

migrate_status() {
  local step event
  if [[ -s $user_pending ]]; then
    say "User setup pending, retried at the next run or boot: $(pending_summary)"
  fi
  if [[ ! -f $journal || $(step_state preflight) != "done" ]]; then
    if [[ -s $state/deferred ]]; then
      say "No migration has started on this Mac. The last run deferred: $(cut -d' ' -f2- "$state/deferred")"
    else
      say "No migration has started on this Mac."
    fi
    return 0
  fi
  say "Target: $(<"$plan/target-id")"
  if [[ -f $complete ]]; then
    say "State: complete ($(awk -F= '$1 == "completed" { print $2 }' "$complete"))"
    return 0
  fi
  step=$(next_step)
  event=$(step_state "$step")
  if [[ $step == "reboot" && -s $reboot_pending && $event == "begin" ]]; then
    if [[ $(boot_id) == "$(<"$reboot_pending")" ]]; then
      say "State: waiting for a reboot"
    else
      say "State: rebooted; the new boot chain is not verified yet (sudo omarchy-mac-migrate verify)"
    fi
  elif [[ $event == "fail" ]]; then
    say "State: failed at $step: $(awk -v step="$step" '$2 == step && $3 == "fail" { $1 = $2 = $3 = ""; line = $0 } END { sub(/^ +/, "", line); print line }' "$journal")"
  else
    say "State: in progress, next step $step"
  fi
}

usage() {
  cat >&2 <<'USAGE'
Usage: omarchy-mac-migrate status
       omarchy-mac-migrate check [--target FILE]
       omarchy-mac-migrate run [--target FILE]
       omarchy-mac-migrate verify
       omarchy-mac-migrate version
USAGE
}

migrate_main() {
  local command=${1:-status}
  original_args=("$@")
  (( $# == 0 )) || shift
  case $command in
    status) migrate_status ;;
    check) check_only=1; migrate_run "$@" ;;
    run) migrate_run "$@" ;;
    verify) migrate_verify ;;
    version) say "omarchy-mac-migrate $tool_version (journal format $journal_format)" ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
  esac
}
