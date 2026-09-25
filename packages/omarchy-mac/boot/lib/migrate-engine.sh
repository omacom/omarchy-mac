# Sourced by omarchy-mac-migrate: the journaled transition engine.
#
# It moves a Mac onto a target package set in ten ordered steps. Every step
# records its start and its end in an append-only journal synced to disk, so a
# power loss or a kill resumes at the first step that did not finish, and every
# step can run again from its start. Preflight changes nothing and freezes the
# plan the later steps follow. A cohort adapter (migrate-<cohort>.sh) decides
# what its machines need: the package targets, the packages the transaction may
# remove and the compatibility state to retire. The engine owns the order, the
# journal and every change to the system.
#
# The caller sets R (the fixture root, empty on a live system), fixture (1 when
# unprivileged tests drive it) and boot_lib. Adapters read the target_* values.
# shellcheck disable=SC2034,SC2154

migrate_steps=(preflight backup keyring prefetch repositories transaction boot-chain loader reboot retire)

state=$R/var/lib/omarchy-mac/migration
journal=$state/journal
plan=$state/plan
cache=$state/cache
backup=$state/backup
expected=$state/expected
complete=$state/complete
reboot_pending=$state/reboot-pending
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
candidate_repo=omarchy-mac-candidate

# The Omarchy packaging key omarchy-keyring carries (as in omarchy-upgrade-to-quattro).
official_key=40DFB630FF42BCFFB047046CF0134EE680CAC571
# Trust the converged system never keeps: the unsigned collaboration repository,
# and the fork keys of omarchy-mac's rc4 channel and of mx-mac.
retired_repos=(omarchy-aarch64)
retired_keys=(FBD6874D423C418DDB6D143EECE19CDDE306DBD2 C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC)

current_step=""
work=""

say() {
  printf '%s\n' "$*"
}

die() {
  echo "omarchy-mac-migrate: $*" >&2
  if [[ -n $current_step && -f $journal ]]; then
    journal_write "$current_step" "fail" "$*"
  fi
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

# Unprivileged tests kill the engine with SIGKILL once a step's work is done
# (during) or once its end is recorded (after). Root never reads these.
interrupt_for_test() {
  (( fixture )) || return 0
  if [[ $1 == "during" && ${OMARCHY_MAC_MIGRATE_KILL_DURING:-} == "$2" ]] ||
    [[ $1 == "after" && ${OMARCHY_MAC_MIGRATE_KILL_AFTER:-} == "$2" ]]; then
    kill -9 $$
  fi
}

run_step() {
  local step=$1
  current_step=$step
  journal_write "$step" "begin"
  "step_${step//-/_}"
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
  env OMARCHY_UPDATE_PACMAN=1 LC_ALL=C pacman --gpgdir "$pacman_gpg" "$@"
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

boot_check_pending() {
  env OMARCHY_BOOT_CHECK_ALLOW_PENDING_REBOOT=1 omarchy-apple-silicon-boot-check "$1"
}

key_trusted() {
  local validity
  validity=$(gpg --homedir "$pacman_gpg" --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "pub" { print $2; exit }')
  [[ $validity == "f" || $validity == "u" ]]
}

key_present() {
  gpg --homedir "$pacman_gpg" --batch --with-colons --list-keys "$1" >/dev/null 2>&1
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
  local file=$1 line key value format=""
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
      [[ $target_set == /* ]] && trusted "$target_set" || die "the candidate set $target_set must be a root-owned directory writable only by root"
      [[ $target_fingerprint =~ ^[0-9A-F]{40}$ ]] || die "a candidate-set target needs its signer's 40-digit fingerprint"
      [[ -f $target_set/manifest.json ]] || die "the candidate set has no manifest.json"
      target_packages=$(jq -r '[.packages[].name] | join(" ")' "$target_set/manifest.json") || die "cannot read the candidate manifest"
      target_id="candidate-set $(jq -r '.set' "$target_set/manifest.json") $(jq -r '.set_sha256' "$target_set/manifest.json")"
      target_repo=$candidate_repo
      ;;
    *)
      die "the target $file has no type (repository or candidate-set)"
      ;;
  esac
}

find_target() {
  local candidate
  for candidate in "$@" "$R/etc/omarchy-mac/migration-target" "$R/usr/lib/omarchy-mac/boot/migration-target"; do
    if [[ -n $candidate && -e $candidate ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

# Prints the key that made a detached signature, or fails. A revoked or expired
# key or signature does not count.
signer_of() {
  local home=$1 file=$2 signature=$3 status
  status=$(gpg --batch --homedir "$home" --status-fd 1 --verify "$signature" "$file" 2>/dev/null) || return 1
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
  if ! gpg --batch --homedir "$home" --import "$dir/candidate-signing-key.asc" >/dev/null 2>&1 ||
    ! gpg --batch --homedir "$home" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$target_fingerprint"; then
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

# Verifies the set, then builds a local repository of copies whose digests are
# checked again, so what pacman reads is what was verified. Signatures stay
# out of it: pacman's keyring never trusts the candidate key.
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
# cohort needs an adapter defining <cohort>_plan and <cohort>_retire.
detect_cohort() {
  local list=$1
  if grep -Eq '^omarchy(-settings)?-dev ' "$list"; then
    echo mx-mac
  elif ! grep -Eq '^omarchy ' "$list"; then
    echo legacy-checkout
  elif grep -Eq '^omarchy-mac-keyring ' "$list"; then
    echo legacy-channel
  else
    echo tester
  fi
}

cohort_refusal() {
  case $1 in
    mx-mac) echo "this is an mx-mac install (omarchy-dev): its adapter (ticket 43) is not available yet" ;;
    legacy-checkout) echo "Omarchy is not installed as a package here (a legacy omarchy-mac checkout): its adapter (ticket 44) is not available yet" ;;
    legacy-channel) echo "this Mac follows omarchy-mac's rc4 channel (omarchy-mac-keyring): its adapter (ticket 44) is not available yet" ;;
    *) echo "no adapter handles the $1 cohort" ;;
  esac
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
  local reasons=() installed boot_state kernels hooks check_output luks="" need
  local future transaction targets_file resolved name version problem
  work=$(mktemp -d "$R/var/tmp/omarchy-mac-migrate.XXXXXX") || die "cannot create a work directory"
  chmod 755 "$work"
  installed=$work/installed
  installed_packages >"$installed" || die "cannot list the installed packages"

  [[ -d $R/run/systemd/system ]] || reasons+=("this is not a booted system (an image build or a chroot)")
  [[ ! -e $pacman_db/db.lck ]] || reasons+=("pacman is busy or was interrupted ($pacman_db/db.lck exists)")

  cohort=$(detect_cohort "$installed")
  declare -F "${cohort//-/_}_plan" >/dev/null || reasons+=("$(cohort_refusal "$cohort")")

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
  if ! hooks=$(omarchy-mac-initramfs-hooks 2>/dev/null); then
    reasons+=("cannot read the initramfs HOOKS")
  elif [[ " $hooks " == *" encrypt "* ]]; then
    reasons+=("the root unlocks through busybox encrypt: its boot switch is the legacy adapter's (ticket 45)")
  fi
  if ! check_output=$(omarchy-apple-silicon-boot-check 2>&1); then
    reasons+=("the boot files do not match the running system; reboot or repair first: $(tail -n 1 <<<"$check_output")")
  fi
  findmnt -rno TARGET --mountpoint "$R$esp" >/dev/null 2>&1 || reasons+=("the ESP is not mounted at $esp")
  if ! luks=$(root_luks_device); then
    reasons+=("cannot tell whether the root filesystem is encrypted")
  fi

  while IFS= read -r problem; do
    [[ -z $problem ]] || reasons+=("$problem")
  done < <(pacman_trust_problems "$pacman_conf")

  if low_battery; then
    reasons+=("the battery is below 30% and no charger is connected")
  fi
  need=$(( 4 * 1024 * 1024 * 1024 + $(bytes_used "$R/etc") + $(bytes_used "$R/boot") ))
  (( $(free_bytes "$R/var/lib") >= need )) || reasons+=("the root filesystem needs $(( need / 1024 / 1024 )) MiB free for backups and downloads")
  (( $(free_bytes "$R$esp") >= 64 * 1024 * 1024 )) || reasons+=("the ESP needs 64 MiB free")
  (( $(free_bytes "$R/boot") >= 128 * 1024 * 1024 )) || reasons+=("/boot needs 128 MiB free")

  if (( ${#reasons[@]} )); then
    refuse "${reasons[@]}"
  fi

  # The target, read in isolation: a copy of the local database and the future
  # configuration, never the live sync databases.
  future=$work/pacman.conf
  future_pacman_conf "$pacman_conf" >"$future" || die "cannot compute the new pacman configuration"
  mkdir -p "$work/db"
  cp -a "$pacman_db/local" "$work/db/local" || die "cannot copy the package database"
  if [[ $target_type == "candidate-set" ]]; then
    install -d -m 755 "$work/candidate"
    if ! problem=$(verify_candidate_set "$target_set" "$work/gnupg"); then
      refuse "the candidate set does not verify: $problem"
    fi
    index_candidate_repo "$work/candidate" link || die "cannot index the candidate set"
  fi
  transaction=$work/transaction.conf
  transaction_conf "$future" "${target_set:+$work/candidate}" >"$transaction"
  pacman_run --config "$transaction" --dbpath "$work/db" --logfile "$work/pacman.log" -Sy --noconfirm >"$work/sync.log" 2>&1 ||
    refuse "cannot read the target repositories: $(tail -n 1 "$work/sync.log")"

  targets_file=$work/targets
  "${cohort//-/_}_plan" "$installed" "$work" >"$targets_file" || die "the $cohort adapter could not plan this Mac"
  resolved=$work/resolved
  # shellcheck disable=SC2046
  if ! pacman_run --config "$transaction" --dbpath "$work/db" --logfile "$work/pacman.log" -Sup --noconfirm --ask 4 \
    --print-format '%r/%n %v' $(cat "$targets_file") >"$resolved" 2>"$work/resolve.log"; then
    refuse "the target set does not resolve on this Mac: $(tail -n 1 "$work/resolve.log")"
  fi
  if [[ $target_type == "candidate-set" ]]; then
    while read -r name; do
      [[ $name == "$candidate_repo/"* ]] || continue
      version=$(target_version "${name#*/}")
      grep -Fxq "$name $version" "$resolved" || refuse "${name#*/} does not resolve to the candidate's $version"
    done <"$targets_file"
  fi

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
  cp "$target_file" "$plan.new/target"
  printf '%s\n' "$target_id" >"$plan.new/target-id"
  printf '%s\n' "$cohort" >"$plan.new/cohort"
  printf '%s\n' "$boot_state" >"$plan.new/boot"
  printf '%s\n' "$luks" >"$plan.new/luks"
  find "$first_boot_marker" "$R/var/lib/omarchy/first-boot/pending" -maxdepth 0 2>/dev/null >"$plan.new/first-boot" || true
  sync "$plan.new"/*
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
  exit 2
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

load_plan() {
  target_file=$plan/target
  load_target "$target_file"
  cohort=$(<"$plan/cohort")
  [[ $(<"$plan/target-id") == "$target_id" ]] || die "the frozen target no longer matches its plan"
}

plan_targets() {
  cat "$plan/targets"
}

# Unqualified names of every package the transaction replaces or may remove.
plan_package_names() {
  { sed 's|^.*/||' "$plan/targets"; cat "$plan/allowed-removals"; } | sort -u
}

step_backup() {
  local partial=$state/backup.partial name version file found luks
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
  tar -C "$R/boot" --one-file-system -cpf "$partial/boot.tar" . || die "cannot back up /boot"
  tar -C "$R$esp" -cpf "$partial/esp.tar" . || die "cannot back up the ESP"
  luks=$(<"$plan/luks")
  if [[ -n $luks ]]; then
    cryptsetup luksHeaderBackup "$luks" --header-backup-file "$partial/luks-header.img" ||
      die "cannot back up the LUKS header of $luks"
  fi
  (cd "$partial" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS) ||
    die "cannot record the backup's digests"
  sync "$partial"/* "$partial/packages"
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
  if ! key_trusted "$target_keyring"; then
    pacman-key --gpgdir "$pacman_gpg" --keyserver hkps://keys.openpgp.org --recv-keys "$target_keyring" >/dev/null &&
      pacman-key --gpgdir "$pacman_gpg" --lsign-key "$target_keyring" >/dev/null ||
      die "cannot fetch and trust the Omarchy key $target_keyring"
  fi
  key_trusted "$target_keyring" || die "the Omarchy key $target_keyring is not trusted after the bootstrap"
}

# Downloads and verifies every package the transaction needs, then rehearses the
# transaction on a copy of the package database (--dbonly: no files, scripts or
# hooks) to learn exactly what it installs and removes.
step_prefetch() {
  local db=$cache/db rehearsal=$cache/rehearsal conf=$cache/transaction.conf removed name version bad=()
  install -d -m 755 "$cache" "$cache/pkg"
  rm -rf "$db" "$rehearsal" "$cache/candidate"
  mkdir -p "$db"
  cp -a "$pacman_db/local" "$db/local" || die "cannot copy the package database"
  if [[ $target_type == "candidate-set" ]]; then
    stage_candidate_repo "$cache/candidate" "$cache/gnupg" || die "the candidate set does not verify"
  fi
  transaction_conf "$plan/pacman.conf" "${target_set:+$cache/candidate}" >"$conf"
  # shellcheck disable=SC2046
  pacman_run --config "$conf" --dbpath "$db" --cachedir "$cache/pkg" --cachedir "$pacman_cache" --logfile "$cache/pacman.log" \
    -Syuw --noconfirm --ask 4 $(plan_targets) || die "cannot download and verify the target set"
  cp -a "$db" "$rehearsal"
  # shellcheck disable=SC2046
  pacman_run --config "$conf" --dbpath "$rehearsal" --cachedir "$cache/pkg" --cachedir "$pacman_cache" --logfile "$cache/pacman.log" \
    --dbonly -Su --noconfirm --ask 4 $(plan_targets) >"$cache/rehearsal.log" 2>&1 ||
    die "the rehearsed transaction failed: $(tail -n 1 "$cache/rehearsal.log")"
  LC_ALL=C pacman --config "$conf" --dbpath "$rehearsal" -Q >"$cache/expected" || die "cannot read the rehearsed result"
  removed=$(comm -23 <(awk '{ print $1 }' "$plan/installed" | LC_ALL=C sort) <(awk '{ print $1 }' "$cache/expected" | LC_ALL=C sort))
  for name in $removed; do
    grep -Fxq "$name" "$plan/allowed-removals" || bad+=("$name")
  done
  (( ${#bad[@]} == 0 )) || die "the transaction would also remove ${bad[*]}; nothing was changed"
  if [[ $target_type == "candidate-set" ]]; then
    while read -r name; do
      [[ $name == "$candidate_repo/"* ]] || continue
      version=$(target_version "${name#*/}")
      [[ $(installed_version "${name#*/}" "$cache/expected") == "$version" ]] || die "${name#*/} would not end at the candidate's $version"
    done < <(plan_targets)
  fi
  durable_write "$expected" <"$cache/expected" || die "cannot record the rehearsed result"
}

# Official repository precedence and no legacy trust: the frozen configuration,
# the sync databases the rehearsal used, no retired database or fork key.
step_repositories() {
  local repo extension fpr
  if ! cmp -s "$plan/pacman.conf" "$pacman_conf"; then
    durable_write "$pacman_conf" 644 <"$plan/pacman.conf" || die "cannot write $pacman_conf"
  fi
  for repo in $(repositories_in "$cache/transaction.conf"); do
    for extension in db db.sig; do
      [[ -f $cache/db/sync/$repo.$extension ]] || continue
      durable_write "$pacman_db/sync/$repo.$extension" 644 <"$cache/db/sync/$repo.$extension" ||
        die "cannot install the $repo database"
    done
  done
  for repo in "${retired_repos[@]}"; do
    rm -f "$pacman_db/sync/$repo".{db,db.sig,files,files.sig}
  done
  for fpr in "${retired_keys[@]}"; do
    if key_present "$fpr"; then
      pacman-key --gpgdir "$pacman_gpg" --delete "$fpr" >/dev/null || die "cannot remove the retired key $fpr"
    fi
  done
}

# One transaction from the prefetched cache and databases, without a new sync:
# it installs exactly what was verified and rehearsed. Same-name packages are
# named explicitly, so a higher installed version is replaced too.
step_transaction() {
  local now=$cache/installed.now
  installed_packages >"$now" || die "cannot list the installed packages"
  if ! cmp -s "$now" "$expected"; then
    if [[ -e $pacman_db/db.lck ]]; then
      pgrep -x pacman >/dev/null && die "pacman is running; run the migration again when it has finished"
      say "Removing the pacman lock an interrupted transaction left behind"
      rm -f "$pacman_db/db.lck"
    fi
    # shellcheck disable=SC2046
    pacman_run --config "$cache/transaction.conf" --dbpath "$pacman_db" --cachedir "$cache/pkg" --cachedir "$pacman_cache" \
      -Su --noconfirm --ask 4 $(plan_targets) || die "the package transaction failed"
    installed_packages >"$now" || die "cannot list the installed packages"
    cmp -s "$now" "$expected" ||
      die "the installed packages differ from the rehearsed transaction: $(diff "$expected" "$now" | grep '^[<>]' | head -n 3 | xargs)"
  fi
  rm -f "$pacman_db/sync/$candidate_repo".{db,db.sig}
  # Fresh-image provisioning is never armed on an existing machine; a package
  # may only carry over a marker the machine already had.
  if [[ -e $first_boot_marker && ! -s $plan/first-boot ]]; then
    say "Disarming the first-boot setup the transaction left on this installed Mac"
    rm -f "$first_boot_marker"
  fi
}

# Aurora, m1n1 and U-Boot came with the transaction; their stage-two image
# (m1n1, the device trees and U-Boot) and the kernel's menu are rebuilt and
# checked. The loader U-Boot starts is not touched here.
step_boot_chain() {
  local output
  update-m1n1 >/dev/null || die "update-m1n1 could not rebuild m1n1, the device trees and U-Boot"
  if limine_mac; then
    omarchy-mac-limine-cmdline && limine-update >/dev/null || die "cannot rebuild the Limine menu and UKI"
  else
    update-grub >/dev/null || die "cannot rebuild the GRUB menu"
  fi
  output=$(boot_check_pending linux-aurora 2>&1) || die "the rebuilt boot files do not check: $(tail -n 1 <<<"$output")"
}

# Limine is staged and verified before it takes U-Boot's EFI slot. A GRUB Mac
# is switched by the package's own activation, which restores every file it
# touched when anything fails, so a failed stage leaves GRUB booting.
step_loader() {
  local output uki=$R$esp/EFI/Linux/omarchy_linux-aurora.efi
  if limine_mac; then
    [[ -s $uki ]] && grep -Fq "boot():/EFI/Linux/omarchy_linux-aurora.efi" "$R$esp/limine.conf" ||
      die "Limine has no linux-aurora UKI entry; the active loader was left alone"
    omarchy-mac-limine-deploy || die "cannot put Limine on the ESP"
  else
    install -D -m 644 /dev/null "$limine_gate" || die "cannot mark this Mac for Limine"
    if ! (export OMARCHY_PATH=/usr/share/omarchy; source "$boot_lib/setup/limine-boot.sh"); then
      rm -f "$limine_gate"
      die "Limine could not be activated; GRUB is still the loader"
    fi
  fi
  cmp -s "$R/usr/share/limine/BOOTAA64.EFI" "$R$esp/EFI/BOOT/BOOTAA64.EFI" || die "the ESP loader is not the packaged Limine"
  output=$(boot_check_pending linux-aurora 2>&1) || die "the staged boot chain does not check: $(tail -n 1 <<<"$output")"
}

# Waits for a reboot; after it, the new chain must have booted Aurora through
# Limine with every boot file coherent. The boot waited for stays recorded
# until retire, so a verification cut short is repeated on the same boot.
step_reboot() {
  local staged current release output
  current=$(boot_id)
  if [[ ! -s $reboot_pending ]]; then
    printf '%s\n' "$current" | durable_write "$reboot_pending" || die "cannot record the boot to wait for"
    systemctl enable "$verify_unit" >/dev/null 2>&1 ||
      say "Could not enable $verify_unit; run 'sudo omarchy-mac-migrate verify' after the reboot."
  fi
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
  output=$(omarchy-apple-silicon-boot-check linux-aurora 2>&1) || die "the boot check failed after the reboot: $(tail -n 1 <<<"$output")"
}

step_retire() {
  "${cohort//-/_}_retire" || die "the $cohort adapter could not retire its compatibility state"
  systemctl disable "$verify_unit" >/dev/null 2>&1 || true
  rm -rf "$cache" "$reboot_pending"
  printf 'target=%s\ncompleted=%s\n' "$target_id" "$(date +%Y-%m-%dT%H:%M:%S%z)" | durable_write "$complete" ||
    die "cannot record the completed migration"
}

# --- Commands ----------------------------------------------------------------

take_lock() {
  install -d -m 755 "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  flock -n 9 || die "another migration is running"
}

resume_steps() {
  local step event
  for step in "${migrate_steps[@]:1}"; do
    event=$(step_state "$step")
    [[ $event != "done" ]] || continue
    [[ -z $event || $step == "reboot" ]] || say "Resuming the migration at $step"
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
  trap on_exit EXIT

  if [[ -f $complete && -f $plan/target-id ]]; then
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

  if [[ -f $journal && $(step_state preflight) == "done" ]]; then
    if [[ -n $target_arg ]]; then
      load_target "$target_arg"
      [[ $target_id == "$(<"$plan/target-id")" ]] ||
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
  mv "$journal" "$plan" "$expected" "$complete" "$destination/" 2>/dev/null
  [[ ! -d $backup ]] || mv "$backup" "$destination/"
}

# Run by omarchy-mac-migrate-verify.service at boot: continues a migration that
# is waiting for, or past, its reboot, and does nothing otherwise.
migrate_verify() {
  platform=$(hardware_platform) || die "cannot determine the hardware platform"
  [[ $platform == "apple-silicon" && -f $journal && ! -f $complete && -n $(step_state reboot) ]] || return 0
  take_lock
  trap on_exit EXIT
  load_plan
  resume_steps
}

migrate_status() {
  local step event
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
