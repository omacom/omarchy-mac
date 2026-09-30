# Sourced by omarchy-mac-migrate: the journaled transition engine.
#
# It moves a Mac onto a target package set in eleven ordered steps. Every step
# records its start and its end in an append-only journal synced to disk, so a
# power loss or a kill resumes at the first step that did not finish, and every
# step can run again from its start. Preflight changes nothing and freezes the
# plan the later steps follow. A cohort adapter (migrate-<cohort>.sh) decides
# what its machines need: the package targets, the packages the transaction may
# remove and the compatibility state to retire. The engine owns the order, the
# journal and every change to the system.
#
# The caller sets R (the fixture root, empty on a live system), fixture (1 when
# unprivileged tests drive it), boot_lib and payload_version (the version of the
# unpacked omarchy-mac-boot it runs from, or nothing when it runs installed).
# Adapters read the target_* values.
#
# Exit status: 0 when the Mac is migrated, waits for its reboot or has nothing
# to migrate; 75 (EX_TEMPFAIL) when it stopped before anything changed (a
# preflight refusal, or any failure before the journal exists), which
# omarchy-migrate treats as deferred; 1 when a step failed, and running again
# resumes it.
# shellcheck disable=SC2034,SC2154

migrate_steps=(preflight backup keyring prefetch repositories transaction boot-chain loader defaults reboot retire)

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
lock_file=$R/run/lock/omarchy-mac-migrate.lock
pacman_conf=$R/etc/pacman.conf
pacman_db=$R/var/lib/pacman
pacman_cache=$R/var/cache/pacman/pkg
pacman_gpg=$R/etc/pacman.d/gnupg
esp=/boot/efi
limine_gate=$R/var/lib/omarchy/limine.enabled
limine_default=$R/etc/default/limine
verify_unit=omarchy-mac-migrate-verify.service
first_boot_marker=$R/var/lib/omarchy/mac-first-boot/pending
legacy_first_boot_marker=$R/var/lib/omarchy/first-boot/pending
candidate_repo=omarchy-mac-candidate
# The user units a fresh install's first run enables
# (install/user/first-run/enable-user-units.sh).
fresh_user_units="bt-agent.service omarchy-recover-internal-monitor.service omarchy-sleep-lock.service omarchy-migrate-notify.service omarchy-fcitx5.service omarchy-crash-watch.service omarchy-brightness-keyboard-auto.service"

# The Omarchy packaging key omarchy-keyring carries (as in omarchy-upgrade-to-quattro).
official_key=40DFB630FF42BCFFB047046CF0134EE680CAC571
# Trust the converged system never keeps: the unsigned collaboration repository,
# and the fork keys of omarchy-mac's rc4 channel and of mx-mac.
retired_repos=(omarchy-aarch64)
retired_keys=(FBD6874D423C418DDB6D143EECE19CDDE306DBD2 C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC)

current_step=""
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
  exit 1
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

# The upstream detector; a runtime from before it (the candidate set's, today's
# testers') has only the Apple predicate, which the detector's wrappers replace.
hardware_platform() {
  if command -v omarchy-hw-platform >/dev/null; then
    omarchy-hw-platform
  elif omarchy-hw-apple-silicon; then
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
  validity=$(gpg --homedir "$pacman_gpg" --batch --no-auto-check-trustdb --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "pub" { print $2; exit }')
  [[ $validity == "f" || $validity == "u" ]]
}

key_present() {
  gpg --homedir "$pacman_gpg" --batch --no-auto-check-trustdb --with-colons --list-keys "$1" >/dev/null 2>&1
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

repositories_in() {
  awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); if (name != "options") print name }' "$1"
}

# The configuration after the switch: the retired repositories and [omarchy]
# are dropped wherever they are, and [omarchy] comes back first, pointing at the
# target, with no SigLevel of its own. Everything else is kept as written.
# Applying it to its own output changes nothing.
future_pacman_conf() {
  local retired
  retired=$(IFS=,; echo "${retired_repos[*]}")
  awk -v server="$target_server" -v retired="$retired" '
    BEGIN { n = split(retired, list, ","); for (i = 1; i <= n; i++) drop[list[i]] = 1; drop["omarchy"] = 1 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      if (name != "options" && !inserted) { print "[omarchy]"; print "Server = " server; print ""; inserted = 1 }
      skipping = (name in drop)
      if (skipping) next
    }
    skipping && ($0 ~ /^[[:space:]]*$/ || $0 !~ /^[[:space:]]*#/) { next }
    { print }
    END { if (!inserted) { print ""; print "[omarchy]"; print "Server = " server } }
  ' "$1"
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

# --- Target ------------------------------------------------------------------

default_packages="omarchy omarchy-settings omarchy-mac omarchy-mac-boot linux-aurora linux-aurora-headers m1n1-aurora uboot-asahi limine-mkinitcpio-hook"

# The target, in the image manifest's format: key=value lines, comments and
# blank lines ignored, anything else refused.
#   format=1
#   type=repository | candidate-set
#   channel=stable | rc | edge          the [omarchy] channel after the switch
#   server=URL                          optional; https://pkgs.omarchy.org/<channel>/$arch
#   keyring=FINGERPRINT                 optional; the Omarchy packaging key
#   packages=NAME...                    repository only; optional
#   set=DIR                             candidate-set: the set's files, manifest.json and signing.json
#   fingerprint=FINGERPRINT             candidate-set: the only key its signatures may carry
load_target() {
  local file=$1 frozen=${2:-} line key value format=""
  target_type="" target_channel="" target_server="" target_keyring=$official_key
  target_set="" target_fingerprint="" target_packages=$default_packages target_repo=omarchy
  trusted "$file" || die "refusing the target $file: it must be a regular file owned by root and writable only by root"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line && $line != \#* ]] || continue
    [[ $line == *=* ]] || die "the target $file is malformed: $line"
    key=${line%%=*}
    value=${line#*=}
    case $key in
      format) format=$value ;;
      type) target_type=$value ;;
      channel) target_channel=$value ;;
      server) target_server=$value ;;
      keyring) target_keyring=${value^^} ;;
      packages) target_packages=$value ;;
      set) target_set=${value%/} ;;
      fingerprint) target_fingerprint=${value^^} ;;
      *) die "the target $file has an unknown key: $key" ;;
    esac
  done <"$file"
  [[ $format == "1" ]] || die "the target $file is not format=1"
  [[ $target_channel =~ ^(stable|rc|edge)$ ]] || die "the target $file names no channel (stable, rc or edge)"
  [[ -n $target_server ]] || target_server="https://pkgs.omarchy.org/$target_channel/\$arch"
  [[ $target_server =~ ^(https|file):// ]] || die "the target server must be https:// or file://: $target_server"
  [[ $target_keyring =~ ^[0-9A-F]{40}$ ]] || die "the target keyring must be a 40-digit fingerprint"
  case $target_type in
    repository)
      target_id="repository $target_server"
      ;;
    candidate-set)
      [[ $target_fingerprint =~ ^[0-9A-F]{40}$ ]] || die "a candidate-set target needs its signer's 40-digit fingerprint"
      target_repo=$candidate_repo
      if [[ -n $frozen ]]; then
        # After preflight only the verified copy counts; the original may be gone.
        target_set=$set_copy
      else
        [[ $target_set == /* ]] && trusted "$target_set" || die "the candidate set $target_set must be a root-owned directory writable only by root"
        [[ -f $target_set/manifest.json ]] || die "the candidate set has no manifest.json"
        candidate_identity "$target_set" || die "cannot read the candidate manifest"
      fi
      ;;
    *)
      die "the target $file has no type (repository or candidate-set)"
      ;;
  esac
}

candidate_identity() {
  target_packages=$(jq -r '[.packages[].name] | join(" ")' "$1/manifest.json") &&
    target_id="candidate-set $(jq -r '.set' "$1/manifest.json") $(jq -r '.set_sha256' "$1/manifest.json")"
}

find_target() {
  local candidate
  for candidate in "$@" "$R/etc/omarchy-mac/migration-target" "$boot_lib/migration-target"; do
    if [[ -n $candidate && -e $candidate ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

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
# the quattro tree, whose 3.x upgrade command quattro-upstream never had.
detect_cohort() {
  local list=$1
  if grep -Eq '^omarchy(-settings)?-dev ' "$list"; then
    if mx_mac_fork; then
      echo mx-mac
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
  case $1 in
    official-dev) echo "omarchy-dev is installed without the omarchy-mx-mac fork's updaters or records, but this Mac still trusts what the switch retires (${official_problems:-a retired repository or key}): no adapter handles it" ;;
    *) echo "no adapter handles the $1 cohort" ;;
  esac
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

pacman_trust_problems() {
  local conf=$1 retired
  retired=$(IFS=,; echo "${retired_repos[*]}")
  awk -v retired="$retired" '
    BEGIN { n = split(retired, list, ","); for (i = 1; i <= n; i++) drop[list[i]] = 1; drop["omarchy"] = 1 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    /^[[:space:]]*SigLevel[[:space:]]*=/ {
      value = $0; sub(/^[^=]*=[[:space:]]*/, "", value)
      if (name == "options") {
        if (value ~ /TrustAll|Never/ || value ~ /^Optional/) print "the global SigLevel accepts unsigned or untrusted packages (" value ")"
      } else if (!(name in drop) && value ~ /TrustAll|Never/) {
        print "[" name "] accepts untrusted packages (SigLevel = " value "); remove it or sign it first"
      }
    }
  ' "$conf"
}

preflight() {
  local reasons=() installed boot_state kernels hooks="" check_output luks="" need esp_mount staged=0
  local future transaction targets_file resolved name version problem official_problems=""
  work=$(mktemp -d "$R/var/tmp/omarchy-mac-migrate.XXXXXX") || die "cannot create a work directory"
  chmod 755 "$work"
  installed=$work/installed
  installed_packages >"$installed" || die "cannot list the installed packages"

  [[ -d $R/run/systemd/system ]] || reasons+=("this is not a booted system (an image build or a chroot)")
  [[ ! -e $pacman_db/db.lck ]] || reasons+=("pacman is busy or was interrupted ($pacman_db/db.lck exists)")

  cohort=$(detect_cohort "$installed")
  # omacom's repositories carry an omarchy-dev of their own: a Mac following
  # Omarchy's dev channel already runs official packages.
  if [[ $cohort == "official-dev" ]]; then
    official_problems=$(official_trust_problems <(pacman_conf_flat "$pacman_conf") | paste -sd, | sed 's/,/, /g')
    if [[ -z $official_problems ]]; then
      say "This Mac runs Omarchy's own dev channel (omarchy-dev from pkgs.omarchy.org): nothing to migrate."
      exit 0
    fi
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
  if ! luks=$(root_luks_device); then
    reasons+=("cannot tell whether the root filesystem is encrypted")
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
  if [[ -e $first_boot_marker || -e $legacy_first_boot_marker ]]; then
    reasons+=("first boot has not finished on this Mac")
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

  while IFS= read -r problem; do
    [[ -z $problem ]] || reasons+=("$problem")
  done < <(pacman_trust_problems <(pacman_conf_flat "$pacman_conf"))
  # The switch rewrites only pacman.conf itself: a repository it drops that an
  # Include file defines would stay.
  for problem in $(comm -13 <(repositories_in "$pacman_conf" | LC_ALL=C sort -u) <(repositories_in <(pacman_conf_flat "$pacman_conf") | LC_ALL=C sort -u)); do
    [[ $problem != "omarchy" && " ${retired_repos[*]} " != *" $problem "* ]] ||
      reasons+=("[$problem] is configured through an Include, which the repository switch cannot rewrite; move it into $pacman_conf first")
  done

  if [[ $target_type == "candidate-set" ]] && ! command -v gpgv >/dev/null; then
    reasons+=("gpgv is not installed (gnupg), so the candidate set's signatures cannot be checked")
  fi
  if low_battery; then
    reasons+=("the battery is below 30% and no charger is connected")
  fi
  need=$(( 4 * 1024 * 1024 * 1024 + $(bytes_used "$R/etc") + $(bytes_used "$R/boot") ))
  # An ESP mounted at /boot is also /boot: its kernel and initramfs move onto
  # the root filesystem.
  [[ $esp_mount != "/boot" ]] || need=$(( need + 512 * 1024 * 1024 ))
  (( $(free_bytes "$R/var/lib") >= need )) || reasons+=("the root filesystem needs $(( need / 1024 / 1024 )) MiB free for backups and downloads")
  (( $(free_bytes "$R${esp_mount:-$esp}") >= 64 * 1024 * 1024 )) || reasons+=("the ESP needs 64 MiB free")
  [[ $esp_mount == "/boot" ]] || (( $(free_bytes "$R/boot") >= 128 * 1024 * 1024 )) || reasons+=("/boot needs 128 MiB free")

  if (( ${#reasons[@]} )); then
    refuse "${reasons[@]}"
  fi

  # The target, read in isolation: a copy of the local database and the future
  # configuration, never the live sync databases.
  # Signed databases are checked against a copy of the keyring, so preflight
  # never imports a key into the live one.
  future=$work/pacman.conf
  future_pacman_conf "$pacman_conf" >"$future" || die "cannot compute the new pacman configuration"
  mkdir -p "$work/db"
  cp -a "$pacman_db/local" "$work/db/local" || die "cannot copy the package database"
  install -d -m 700 "$work/pacman-gnupg"
  tar -C "$pacman_gpg" --exclude='S.*' -cf - . | tar -C "$work/pacman-gnupg" -xf - || die "cannot copy the pacman keyring"
  gpgdir=$work/pacman-gnupg
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

  targets_file=$work/targets
  "${cohort//-/_}_plan" "$installed" "$work" "$luks" "$hooks" >"$targets_file" || die "the $cohort adapter could not plan this Mac"
  resolved=$work/resolved
  # shellcheck disable=SC2046
  if ! pacman_run --config "$transaction" --dbpath "$work/db" --logfile "$work/pacman.log" -Sup --noconfirm --ask 4 \
    --print-format '%r/%n %v' $(plan_ignores "$work/removals") $(cat "$targets_file") >"$resolved" 2>"$work/resolve.log"; then
    refuse "the target set does not resolve on this Mac: $(tail -n 1 "$work/resolve.log")"
  fi
  if [[ $target_type == "candidate-set" ]]; then
    while read -r name; do
      [[ $name == "$candidate_repo/"* ]] || continue
      version=$(target_version "${name#*/}")
      grep -Fxq "$name $version" "$resolved" || refuse "${name#*/} does not resolve to the candidate's $version"
    done <"$targets_file"
  fi
  # Run from a download, the engine is the omarchy-mac-boot the transaction
  # installs, or it stops: the next run fetches the current one.
  if [[ -n ${payload_version:-} ]]; then
    version=$(awk '{ name = $1; sub(/^[^\/]*\//, "", name) } name == "omarchy-mac-boot" { print $2; exit }' "$resolved")
    [[ $version == "$payload_version" ]] ||
      refuse "this migration runs from omarchy-mac-boot $payload_version, but the target installs ${version:-no omarchy-mac-boot}"
  fi

  gpgdir=""
  if already_on_target "$installed" "$resolved" "$targets_file" "$future"; then
    say "This Mac already runs the target set ($target_id): nothing to migrate."
    exit 0
  fi

  # Passed: freeze the plan. Nothing on the system has changed yet.
  install -d -m 755 "$(dirname "$state")" "$state"
  : >"$journal"
  sync "$journal"
  current_step=preflight
  journal_write preflight "begin" "$target_id"
  rm -rf "$plan.new"
  install -d -m 755 "$plan.new"
  cp "$installed" "$plan.new/installed"
  cp "$future" "$plan.new/pacman.conf"
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
  sync "$plan.new"/*
  if [[ $target_type == "candidate-set" ]]; then
    rm -rf "$set_copy"
    mv "$work/set" "$set_copy" || die "cannot keep the verified candidate set"
    sync "$set_copy"/*
    target_set=$set_copy
  fi
  rm -rf "$plan"
  mv "$plan.new" "$plan"
  sync "$state"
  interrupt_for_test during preflight
  journal_write preflight "done"
  interrupt_for_test after preflight
  current_step=""
}

refuse() {
  say "The migration was refused before anything changed:" >&2
  printf '  - %s\n' "$@" >&2
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

# The planned removals stay out of the upgrade: an official build of the same
# name that provides a target (omacom's omarchy-dev provides omarchy) would
# otherwise join the transaction, and pacman drops the target it conflicts with.
plan_ignores() {
  local removals=${1:-$plan/removals}
  [[ -s $removals ]] && printf -- '--ignore=%s\n' "$(paste -sd, "$removals")"
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
  # shellcheck disable=SC2046
  pacman_run --config "$conf" --dbpath "$db" --cachedir "$cache/pkg" --cachedir "$pacman_cache" --logfile "$cache/pacman.log" \
    -Syuw --noconfirm --ask 4 $(plan_ignores) $(plan_targets) || die "cannot download and verify the target set"
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

# Official repository precedence and no legacy trust: the frozen configuration,
# the sync databases the rehearsal used, no retired database or fork key.
step_repositories() {
  local repo extension fpr
  if system_moved; then
    restart_from_prefetch "before the repository switch"
    return 0
  fi
  if ! cmp -s "$plan/pacman.conf" "$pacman_conf"; then
    durable_write "$pacman_conf" 644 <"$plan/pacman.conf" || die "cannot write $pacman_conf"
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
  cmp -s "$plan/pacman.conf" "$pacman_conf" || return 0
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

# Limine is staged and verified before it takes U-Boot's EFI slot. A GRUB Mac,
# as preflight found it, is switched by the package's own activation, which
# restores every file it touched when anything fails, so a failed stage leaves
# GRUB booting. The cohort's stage runs first, while GRUB still boots the Mac,
# and is undone when it or the activation fails. A switch cut short is run
# again from its start.
step_loader() {
  local output uki=$R$esp/EFI/Linux/omarchy_linux-aurora.efi
  if [[ $(<"$plan/boot") == "limine" ]]; then
    [[ -s $uki ]] && grep -Fq "boot():/EFI/Linux/omarchy_linux-aurora.efi" "$R$esp/limine.conf" ||
      die "Limine has no linux-aurora UKI entry; the active loader was left alone"
    interrupt_for_test mid loader
    omarchy-mac-limine-deploy || die "cannot put Limine on the ESP"
  else
    if ! adapter_hook stage; then
      adapter_hook unstage || die "the $cohort adapter could not stage the boot switch, nor undo it; GRUB is still the loader"
      die "the $cohort adapter could not stage the boot switch; GRUB is still the loader"
    fi
    install -D -m 644 /dev/null "$limine_gate" || die "cannot mark this Mac for Limine"
    interrupt_for_test mid loader
    if ! (export OMARCHY_PATH=/usr/share/omarchy; source "$boot_lib/setup/limine-boot.sh"); then
      rm -f "$limine_gate"
      adapter_hook unstage || die "Limine could not be activated, and the $cohort adapter could not undo its stage; GRUB is still the loader"
      die "Limine could not be activated; GRUB is still the loader"
    fi
  fi
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

# The default packages the aarch64 and Apple lists add, where they are missing
# and a repository carries them (the base list's applications stay the owner's
# choice). Firmware among them rebuilds the initramfs and the UKI through
# pacman's hooks, so the boot files are checked again.
install_defaults() {
  local generic apple available name missing=() absent=() output
  if ! command -v omarchy-pkg-defaults >/dev/null; then
    say "This Omarchy has no omarchy-pkg-defaults: the default packages were not checked"
    return 0
  fi
  generic=$(env OMARCHY_PATH="$R/usr/share/omarchy" omarchy-pkg-defaults generic) &&
    apple=$(env OMARCHY_PATH="$R/usr/share/omarchy" omarchy-pkg-defaults apple-silicon) ||
    die "cannot read the Apple Silicon default packages"
  available=$(LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Sl | awk '{ print $2 }') ||
    die "cannot read the repositories' packages"
  while read -r name; do
    [[ -n $name ]] && ! grep -Fxq -- "$name" <<<"$generic" || continue
    LC_ALL=C pacman --config "$pacman_conf" --dbpath "$pacman_db" -Qq "$name" >/dev/null 2>&1 && continue
    if grep -Fxq -- "$name" <<<"$available"; then
      missing+=("$name")
    else
      absent+=("$name")
    fi
  done <<<"$apple"
  (( ${#absent[@]} == 0 )) || say "No repository carries these default packages, so they stay missing: ${absent[*]}"
  (( ${#missing[@]} )) || return 0
  say "Installing the default packages a fresh install has: ${missing[*]}"
  pacman_run --config "$pacman_conf" --dbpath "$pacman_db" -S --noconfirm "${missing[@]}" ||
    die "cannot install the default packages: ${missing[*]}"
  output=$(boot_check_pending linux-aurora 2>&1) || die "the boot files do not check after the default packages: $(tail -n 1 <<<"$output")"
}

# Official migrations a migrated Mac records as done instead of running them,
# as a fresh Mac image has them (reviewed for ticket 53): initramfs and
# boot-chain repairs for the x86 Limine, T2, NVIDIA and linux-omarchy paths,
# whose Mac counterparts are this package's; the Intel Mac Broadcom quirk, which breaks
# Apple Silicon Wi-Fi; systemd-oomd, which stays off on Macs; and the platform
# migration, which handed the Mac to this engine. Every other official
# migration still pending runs on the next omarchy update, as on any install
# that upgraded. An adapter adds what its cohort already applied, and each
# repair below adds the Mac migration whose work it did.
settled_migrations="1784476564 1784917531 1785273276 1785424256 1785944594 1786137597 1786391100 1786482992 1786605598 1789325478 1789444024 1790347292"
platform_migration=1790347292
repaired=$state/repaired
repaired_migrations=()

# The migrations USER records as done: the common ones, the repairs this
# migration made and the cohort's, comma-separated.
settled_for() {
  local dir=$R$2/.local/state/omarchy/migrations
  { printf '%s\n' $settled_migrations; cat "$repaired" 2>/dev/null; adapter_hook settled "$dir"; } | awk 'NF' | paste -sd,
}

# Records the migrations NAMES lists (comma-separated) as done for USER, as
# the user, where they are not recorded yet.
settle_migrations() {
  local user=$1 home=$2 names=$3 dir=$R$2/.local/state/omarchy/migrations name
  as_user "$user" "$R$home" mkdir -p "$dir" || return 1
  for name in ${names//,/ }; do
    [[ -e $dir/$name.sh ]] || as_user "$user" "$R$home" touch "$dir/$name.sh" || return 1
  done
}

# --- Repairs a fresh image does not need ----------------------------------------
#
# Macs set up before the runtime or its images carried a fix got it from a
# migration of the runtime they ran. Upstream Omarchy carries none of those
# migrations, so the engine does their work here, as root, for every cohort.
# Each repair can run again from its start and fails the step when it cannot
# finish; a later run repeats it. One that did its work, or found none to do,
# records its migration as done for every user. The target's runtime carries
# the leaves they run (install/config/snapper.sh and locale.sh) and its
# omarchy-mac the keyboard handover; a target
# without one is reported, and that migration is left to the runtime.

runtime_leaf_present() {
  [[ -f $R/usr/share/omarchy/$1 ]]
}

# A runtime leaf, run whole in a strict shell as the runtime's migrations run them.
run_runtime_leaf() {
  local leaf=$R/usr/share/omarchy/$1
  shift
  env OMARCHY_PATH="$R/usr/share/omarchy" "$@" bash -euo pipefail "$leaf"
}

# Snapper's root configuration (migration 1789148088): the asahi-overlay
# install skipped it. The leaf skips a root that is not btrfs; 3 means it
# found a layout it will not touch, left for manual repair, which is final.
repair_snapper() {
  local status=0
  if ! runtime_leaf_present install/config/snapper.sh; then
    say "This Omarchy has no Snapper setup leaf: the root's Snapper configuration was not checked"
    return 0
  fi
  run_runtime_leaf install/config/snapper.sh >/dev/null || status=$?
  case $status in
    0) repaired_migrations+=(1789148088) ;;
    3)
      say "The existing Snapper configuration was left for manual repair"
      repaired_migrations+=(1789148088)
      ;;
    *) die "cannot set up Snapper for the root filesystem" ;;
  esac
}

# Asahi ALARM's bootstrap administrator (migration 1789158179): polkit asks
# for alarm's password while it stays in wheel. It leaves wheel only when
# another existing account is in wheel. Where alarm is itself an Omarchy user,
# the engine leaves the decision to that migration, which skips only alarm's
# own run.
repair_bootstrap_admin() {
  local members member others=0
  members=$(awk -F: '$1 == "wheel" { print $4 }' "$R/etc/group" 2>/dev/null) || members=""
  if omarchy_users | awk '{ print $1 }' | grep -Fxq alarm; then
    say "alarm uses Omarchy here: its wheel membership is left to the runtime's migration"
  else
    if [[ ,$members, == *,alarm,* ]]; then
      IFS=, read -ra members <<<"$members"
      for member in "${members[@]}"; do
        if [[ -n $member && $member != "alarm" ]] && awk -F: -v user="$member" '$1 == user { found = 1 } END { exit !found }' "$R/etc/passwd"; then
          others=1
        fi
      done
      if (( others )); then
        say "Removing Asahi's bootstrap account alarm from wheel"
        gpasswd -d alarm wheel >/dev/null || die "cannot remove alarm from wheel"
      fi
    fi
    repaired_migrations+=(1789158179)
  fi
}

# The Intel Mac Broadcom quirk (migration 1789172112): an older runtime wrote
# it on Apple Silicon too, where it breaks the WPA handshake. Only the exact
# block it wrote goes, and what the file held before it stays. The migration
# also required the Wi-Fi chip's PCI ID; on Apple Silicon the block does harm
# whichever chip carries it, so the engine does not. The rebuild it owes is
# recorded first, under the migration's own marker, so an interrupted run of
# either finishes it.
repair_broadcom_block() {
  local conf=$R/etc/modprobe.d/brcmfmac.conf pending=$R/var/lib/omarchy/migrations/1789172112-initramfs-pending
  local block content rest file
  block="# Broadcom's firmware supplicant and authenticator fail the WPA four-way
# handshake on Apple hardware, which surfaces as a rejected password. Disable
# both so wpa_supplicant performs the handshake instead.
options brcmfmac feature_disable=0x82000"
  if [[ -f $conf ]]; then
    content=$(<"$conf")
    if [[ $content == "$block" || $content == *$'\n'"$block" ]]; then
      say "Removing the Intel Mac Broadcom quirk from $conf"
      install -D -m 644 /dev/null "$pending" && sync "$pending" "$(dirname "$pending")" ||
        die "cannot record the initramfs rebuild the Broadcom repair needs"
      interrupt_for_test mid broadcom
      rest=${content%"$block"}
      rest=${rest%$'\n'}
      if [[ -z $rest && ! -L $conf ]]; then
        rm -f -- "$conf" && sync "$(dirname "$conf")"
      else
        # A link keeps pointing where it did: its target is rewritten.
        file=$(readlink -f -- "$conf") || die "cannot resolve $conf"
        if [[ -n $rest ]]; then
          printf '%s\n' "$rest"
        fi | durable_write "$file"
      fi || die "cannot remove the Broadcom quirk from $conf"
    fi
  fi
  interrupt_for_test mid broadcom-rebuild
  if [[ -f $pending ]]; then
    omarchy-mac-boot-update >/dev/null || die "cannot rebuild the boot image without the Broadcom quirk"
    rm -f "$pending"
  fi
  repaired_migrations+=(1789172112)
}

# A UTF-8 locale (migration 1789146110): Asahi ALARM ships LANG=C. The leaf
# changes only an unset LANG, C or POSIX.
repair_locale() {
  if ! runtime_leaf_present install/config/locale.sh; then
    say "This Omarchy has no locale setup leaf: the locale was not checked"
    return 0
  fi
  run_runtime_leaf install/config/locale.sh OMARCHY_LOCALE_CONF="$R/etc/locale.conf" OMARCHY_LOCALE_GEN="$R/etc/locale.gen" >/dev/null ||
    die "cannot set up the UTF-8 locale"
  repaired_migrations+=(1789146110)
}

# The keyboard's function-key mode (migration 1790327324), handed to
# omarchy-mac. The line Omarchy generated here depends on the fork the Mac
# came from: fnmode=2 from the install leaf, replaced once by mx-mac
# (1790305681, fnmode=3) or quattro-upstream (1789132067, fnmode=1), as any
# of its users' migration records say, mx-mac first as in that migration.
# omarchy-mac-setup-keyboard decides once, and a fork rebuild still owed
# overrides this.
repair_keyboard_mode() {
  local generated=2 user home dir
  if ! command -v omarchy-mac-setup-keyboard >/dev/null; then
    say "This omarchy-mac has no omarchy-mac-setup-keyboard: the keyboard mode was not handed over"
    return 0
  fi
  while read -r user home; do
    [[ -n $user ]] || continue
    dir=$R$home/.local/state/omarchy/migrations
    if [[ -f $dir/1790305681.sh ]]; then
      generated=3
    elif [[ -f $dir/1789132067.sh && $generated == 2 ]]; then
      generated=1
    fi
  done < <(omarchy_users)
  env OMARCHY_MAC_FIXTURE_ROOT="$R" omarchy-mac-setup-keyboard "$generated" >/dev/null ||
    die "cannot hand the keyboard's function-key mode to omarchy-mac"
  repaired_migrations+=(1790327324)
}

repair_system() {
  local output
  repaired_migrations=()
  repair_snapper
  repair_bootstrap_admin
  repair_broadcom_block
  repair_locale
  repair_keyboard_mode
  # The Broadcom and keyboard repairs can rebuild the UKI.
  output=$(boot_check_pending linux-aurora 2>&1) || die "the boot files do not check after the repairs: $(tail -n 1 <<<"$output")"
  printf '%s\n' "${repaired_migrations[@]}" | durable_write "$repaired" || die "cannot record the repairs made"
}

# --- User setup ------------------------------------------------------------------
#
# Each Omarchy user gets the settled migrations, the units first run enables
# and the Mac user setup. What fails for one user (a broken home, a setup that
# exits nonzero) never stops the migration: it is kept in user-pending, a
# "user item" line each, and runs again at every later run and boot until it
# succeeds. The post-reboot unit stays enabled for that.

# One item of a user's setup: settle:NAMES, a unit first run enables, or
# setup-user. A pending settle keeps the names it was given, so a retry after
# the plan moved on records the same ones.
apply_user_item() {
  local user=$1 home=$2 item=$3
  case $item in
    settle:*) settle_migrations "$user" "$home" "${item#settle:}" ;;
    setup-user) as_user "$user" "$R$home" omarchy-mac-setup-user >/dev/null ;;
    *) enable_user_unit "$user" "$home" "$item" ;;
  esac
}

# The user's setup; prints what failed, one item a line.
setup_user() {
  local user=$1 home=$2 item items=("settle:$(settled_for "$user" "$home")")
  if [[ -f $plan/user-units ]]; then
    for item in $fresh_user_units; do
      grep -Fxq "$item" "$plan/user-units" || items+=("$item")
    done
  fi
  for item in "${items[@]}" setup-user; do
    apply_user_item "$user" "$home" "$item" || printf '%s\n' "$item"
  done
}

# Replaces the pending record with FILE's lines, or removes it when FILE is empty.
record_user_pending() {
  if [[ -s $1 ]]; then
    LC_ALL=C sort -u "$1" | durable_write "$user_pending" || die "cannot record the pending user setup"
  else
    rm -f "$user_pending"
  fi
}

# "user item; ..." for messages, a settle item without its names.
pending_summary() {
  awk '{ item = $2; sub(/:.*/, "", item); print $1 " " item }' "$user_pending" | paste -sd';' | sed 's/;/; /g'
}

# Runs the pending items again, only those, so nothing a user turned off since
# comes back. An account that is gone or no longer uses Omarchy is dropped.
# Fails while any item is still pending.
retry_user_pending() {
  local user home item left
  [[ -s $user_pending ]] || return 0
  rm -f "$state"/user-pending.??????
  left=$(mktemp "$state/user-pending.XXXXXX") || die "cannot record the pending user setup"
  while read -r user item; do
    home=$(omarchy_users | awk -v user="$user" '$1 == user { print $2; exit }')
    [[ -n $home && -n $item ]] || continue
    apply_user_item "$user" "$home" "$item" </dev/null || printf '%s %s\n' "$user" "$item" >>"$left"
  done <"$user_pending"
  record_user_pending "$left"
  rm -f "$left"
  if [[ -s $user_pending ]]; then
    say "User setup still pending, retried at the next run or boot: $(pending_summary)"
    return 1
  fi
  say "The pending user setup is done"
}

# Outside a completed migration's cleanup: pending user setup runs again, and
# once none is left the post-reboot unit is released unless a migration is
# waiting for its reboot.
retry_user_pending_now() {
  [[ -s $user_pending ]] || return 0
  if retry_user_pending && [[ ! -e $reboot_pending ]]; then
    systemctl disable "$verify_unit" >/dev/null 2>&1 || say "Could not disable $verify_unit; it does nothing from now on."
  fi
}

# A migrated Mac ends as a fresh install does: with its default packages, the
# Mac services the image's hardware setup enables, the repairs above and, for
# every Omarchy user, the migrations a fresh image records as done, the units
# first run enables and the Mac user setup. A unit the Mac already had before
# the migration is taken to be off by choice and stays off; a plan frozen
# before that was recorded enables none. The reboot that follows brings up
# what probes only at boot, such as the video decoder.
step_defaults() {
  local user home item pending
  install_defaults
  interrupt_for_test mid defaults
  omarchy-mac-setup-system >/dev/null || die "omarchy-mac-setup-system could not set up the Mac's services"
  [[ -e $R/var/lib/omarchy/migrations/$platform_migration ]] ||
    install -D -m 644 /dev/null "$R/var/lib/omarchy/migrations/$platform_migration" ||
    die "cannot record the platform migration as done"
  repair_system
  interrupt_for_test mid user-setup
  # What an earlier migration left pending stays pending until it succeeds.
  retry_user_pending || :
  rm -f "$state"/user-pending.??????
  pending=$(mktemp "$state/user-pending.XXXXXX") || die "cannot record the pending user setup"
  [[ ! -f $user_pending ]] || cat "$user_pending" >"$pending"
  while read -r user home; do
    [[ -n $user ]] || continue
    while read -r item; do
      [[ -n $item ]] || continue
      say "Could not apply $item for $user; it runs again after the reboot"
      printf '%s %s\n' "$user" "$item" >>"$pending"
    done < <(setup_user "$user" "$home" </dev/null)
  done < <(omarchy_users)
  record_user_pending "$pending"
  rm -f "$pending"
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
    systemctl disable "$verify_unit" >/dev/null 2>&1 || say "Could not disable $verify_unit; it does nothing from now on."
  fi
  if (( working )); then
    rm -rf "$cache" "$set_copy" "$state/installed.now" "$state/overwrite"
    rm -f "$reboot_pending"
  fi
  # omarchy-mac-migrate-bootstrap's download, now installed, unless this runs from it.
  [[ -n ${payload_version:-} ]] || rm -rf "$R/var/lib/omarchy-mac/bootstrap"
}

# --- Commands ----------------------------------------------------------------

take_lock() {
  install -d -m 755 "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  flock -n 9 || die "another migration is running"
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
  local target_arg="" candidate retried=0
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
  trap on_exit EXIT

  if [[ -f $complete && -f $plan/target-id ]]; then
    tidy_completed
    retried=1
    candidate=$(find_target "$target_arg")
    if [[ -z $candidate ]]; then
      say "Already migrated to $(<"$plan/target-id")."
      return 0
    fi
    load_target "$candidate"
    if [[ $target_id == "$(<"$plan/target-id")" ]]; then
      say "Already migrated to $target_id."
      return 0
    fi
    archive_state
  fi

  # User setup an earlier migration left pending runs first, whatever this
  # run does next.
  (( retried )) || retry_user_pending_now
  if [[ -f $journal && $(step_state preflight) == "done" ]]; then
    if [[ -n $target_arg ]] && ! cmp -s "$target_arg" "$plan/target"; then
      die "a migration to $(<"$plan/target-id") is in progress; finish it before choosing another target"
    fi
    load_plan
    resume_steps
    return 0
  fi

  target_file=$(find_target "$target_arg")
  if [[ -z $target_file ]]; then
    say "No migration target is set on this Mac: nothing to do."
    return 0
  fi
  load_target "$target_file"
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
  [[ -f $journal && -n $(step_state reboot) ]] || [[ -s $user_pending ]] || return 0
  take_lock
  trap on_exit EXIT
  if [[ -f $complete ]]; then
    tidy_completed
    return 0
  fi
  retry_user_pending_now
  [[ -f $journal && -n $(step_state reboot) ]] || return 0
  load_plan
  resume_steps
}

migrate_status() {
  local step event
  if [[ -s $user_pending ]]; then
    say "User setup pending, retried at the next run or boot: $(pending_summary)"
  fi
  if [[ ! -f $journal || $(step_state preflight) != "done" ]]; then
    say "No migration has started on this Mac."
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
       omarchy-mac-migrate run [--target FILE]
       omarchy-mac-migrate verify
USAGE
}

migrate_main() {
  local command=${1:-status}
  (( $# == 0 )) || shift
  case $command in
    status) migrate_status ;;
    run) migrate_run "$@" ;;
    verify) migrate_verify ;;
    -h | --help | help) usage ;;
    *) usage; exit 2 ;;
  esac
}
