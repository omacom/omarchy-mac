#!/bin/bash

# ARM package lanes use the same stable package names. A lane is reported only
# for a single, directly configured managed server; custom repositories are not
# guessed from unrelated upstream mirrors or installed package names.
omarchy_arm_channel_current() {
  local config="${1:-/etc/pacman.conf}"
  awk '
    /^[[:space:]]*\[/ { selected = ($0 ~ /^[[:space:]]*\[omarchy-aarch64\][[:space:]]*(#.*)?$/); sections += selected }
    selected && /^[[:space:]]*Include[[:space:]]*=/ { invalid = 1 }
    selected && /^[[:space:]]*Server[[:space:]]*=/ {
      servers++
      if ($0 !~ /^[[:space:]]*Server[[:space:]]*=[[:space:]]*https:\/\/github[.]com\/omarchy-mac\/omarchy-pkgs-aarch64\/releases\/download\/(stable|rc|edge)\/?[[:space:]]*(#.*)?$/) invalid = 1
      value = $0
      sub(/^.*\/download\//, "", value)
      sub(/[\/[:space:]#].*$/, "", value)
    }
    END { if (sections == 1 && servers == 1 && !invalid) print value; else exit 1 }
  ' "$config"
}

omarchy_arm_channel_render() {
  local config="$1" channel="$2" output="$3" allow_new="${4:-}"
  case "$channel" in stable | rc | edge) ;; *) echo "Invalid ARM package channel: $channel" >&2; return 1 ;; esac
  if [[ $allow_new == "fresh" ]] && ! grep -qE '^[[:space:]]*\[omarchy-aarch64\]' "$config"; then
    if pacman-conf --config "$config" --repo-list | grep -qxF omarchy-aarch64; then
      echo "A managed ARM repository is hidden in an Include; configure its lane explicitly." >&2
      return 1
    fi
    cat "$config" >"$output"
    printf '\n[omarchy-aarch64]\nSigLevel = PackageRequired DatabaseRequired TrustedOnly\nServer = https://github.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/%s\n' "$channel" >>"$output"
    return
  fi
  if ! omarchy_arm_channel_current "$config" >/dev/null; then
    echo "Cannot switch a custom or ambiguous ARM repository. Keep the current configuration and configure its lane explicitly." >&2
    return 1
  fi
  awk -v channel="$channel" '
    /^[[:space:]]*\[/ { selected = ($0 ~ /^[[:space:]]*\[omarchy-aarch64\][[:space:]]*(#.*)?$/) }
    selected && /^[[:space:]]*Server[[:space:]]*=/ { sub(/\/download\/(stable|rc|edge)/, "/download/" channel) }
    { print }
  ' "$config" >"$output"
  if [[ $allow_new == fresh ]]; then
    local strict_output="${output}.strict.$$"
    if ! omarchy_arm_signature_policy_render "$output" 'PackageRequired DatabaseRequired TrustedOnly' "$strict_output"; then
      rm -f -- "$strict_output" "$output"
      return 1
    fi
    mv -- "$strict_output" "$output"
  fi
}

omarchy_arm_signature_policy_render() {
  local config="$1" policy="$2" output="$3"
  [[ $policy == 'PackageRequired DatabaseOptional TrustedOnly' ||
    $policy == 'PackageRequired DatabaseRequired TrustedOnly' ]] || {
    echo "Invalid ARM signature policy: $policy" >&2
    return 1
  }
  omarchy_arm_channel_current "$config" >/dev/null || {
    echo "Cannot change signature policy for a custom or ambiguous ARM repository." >&2
    return 1
  }
  awk -v policy="$policy" '
    /^[[:space:]]*\[/ {
      if (selected && !wrote) print "SigLevel = " policy
      selected = ($0 ~ /^[[:space:]]*\[omarchy-aarch64\][[:space:]]*(#.*)?$/)
      wrote = 0
      print
      next
    }
    selected && /^[[:space:]]*SigLevel[[:space:]]*=/ {
      if (!wrote) print "SigLevel = " policy
      wrote = 1
      next
    }
    { print }
    END { if (selected && !wrote) print "SigLevel = " policy }
  ' "$config" >"$output"
}

omarchy_arm_signature_policy_assert() {
  local config="$1" expected="$2" actual
  actual=$(pacman-conf --config "$config" --repo omarchy-aarch64 SigLevel | LC_ALL=C sort) || return 1
  case "$expected" in
    'PackageRequired DatabaseOptional TrustedOnly')
      [[ $actual == $'DatabaseOptional\nDatabaseTrustedOnly\nPackageRequired\nPackageTrustedOnly' ]]
      ;;
    'PackageRequired DatabaseRequired TrustedOnly')
      [[ $actual == $'DatabaseRequired\nDatabaseTrustedOnly\nPackageRequired\nPackageTrustedOnly' ]]
      ;;
    *) return 1 ;;
  esac
}

omarchy_arm_signature_policy_apply() {
  local config="$1" policy="$2" rendered
  [[ -f $config && ! -L $config ]] || {
    echo "Pacman configuration must be a regular non-symlink: $config" >&2
    return 1
  }
  rendered=$(mktemp)
  if ! omarchy_arm_signature_policy_render "$config" "$policy" "$rendered" ||
    ! omarchy_arm_signature_policy_assert "$rendered" "$policy"; then
    rm -f -- "$rendered"
    return 1
  fi
  if ! sudo bash -euo pipefail -c '
    config="$1" rendered="$2" stage=""
    cleanup() { [[ -z $stage ]] || rm -f -- "$stage"; }
    trap cleanup EXIT
    [[ -f $config && ! -L $config ]] || exit 1
    stage=$(mktemp "${config}.omarchy-signature.XXXXXXXX")
    cat "$rendered" >"$stage"
    mapfile -t actual < <(pacman-conf --config "$stage" --repo omarchy-aarch64 SigLevel | LC_ALL=C sort)
    [[ ${#actual[@]} == 4 ]]
    case "$3" in
      "PackageRequired DatabaseOptional TrustedOnly")
        [[ ${actual[0]} == DatabaseOptional && ${actual[1]} == DatabaseTrustedOnly &&
          ${actual[2]} == PackageRequired && ${actual[3]} == PackageTrustedOnly ]]
        ;;
      "PackageRequired DatabaseRequired TrustedOnly")
        [[ ${actual[0]} == DatabaseRequired && ${actual[1]} == DatabaseTrustedOnly &&
          ${actual[2]} == PackageRequired && ${actual[3]} == PackageTrustedOnly ]]
        ;;
      *) exit 1 ;;
    esac
    chmod --reference="$config" "$stage"
    chown --reference="$config" "$stage"
    mv -fT -- "$stage" "$config"
    stage=""
  ' bash "$config" "$rendered" "$policy"; then
    rm -f -- "$rendered"
    return 1
  fi
  rm -f -- "$rendered"
  omarchy_arm_signature_policy_assert "$config" "$policy"
}

# DownloadUser must traverse the whole path for downloads and frozen file://
# repositories. A private HOME/cache cannot provide that contract. Allocate only
# our new child under verified root-controlled persistent parents; never loosen
# an existing directory or disable pacman's download sandbox.
omarchy_arm_channel_stage_new() {
  sudo bash -euo pipefail -c '
    owner="$1"; group="$2"; stage=""; complete=0
    [[ $owner =~ ^[0-9]+$ && $group =~ ^[0-9]+$ ]] || exit 1
    cleanup() {
      if [[ -n $stage && $complete == 0 ]]; then rmdir -- "$stage"; fi
    }
    trap cleanup EXIT
    for path in / /var /var/cache /var/cache/omarchy /var/cache/omarchy/channels; do
      if [[ ! -e $path && ! -L $path ]]; then
        case "$path" in
          /var/cache/omarchy | /var/cache/omarchy/channels) mkdir -m 755 -- "$path" ;;
          *) echo "Missing channel cache parent: $path" >&2; exit 1 ;;
        esac
      fi
      [[ -d $path && ! -L $path ]] || { echo "Unsafe channel cache parent: $path" >&2; exit 1; }
      read -r uid mode < <(stat -c "%u %a" -- "$path")
      [[ $uid == 0 && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 && (8#$mode & 0001) != 0 )) || {
        echo "Channel cache parent must be root-owned, traversable and not writable by other users: $path" >&2
        exit 1
      }
      case $(findmnt -n -o FSTYPE -T "$path") in
        "" | tmpfs | ramfs) echo "ARM channel staging needs disk-backed cache parents: $path" >&2; exit 1 ;;
      esac
    done
    stage=$(mktemp -d /var/cache/omarchy/channels/transaction.XXXXXXXX)
    chmod 755 "$stage"
    chown "$owner:$group" "$stage"
    printf "%s\n" "$stage"
    complete=1
  ' bash "$(id -u)" "$(id -g)"
}

omarchy_arm_channel_stage_remove() {
  local stage="$1"
  # A private keyring may start its own agent; never address the host agent.
  sudo gpgconf --homedir "$stage/keyring" --kill gpg-agent 2>/dev/null || true
  sudo rm -rf -- "$stage/keyring/private-keys-v1.d"
  if ! omarchy_arm_channel_restore_sync "$stage"; then
    echo "Retaining transaction recovery files in $stage" >&2
    return 1
  fi
  sudo rm -rf -- "$stage"
}

# The installing pacman must lock its real DBPath. If it fails after the
# captured sync, compensate only our sync cache, under that same lock and only
# if nobody has changed it since capture. Installed packages are not rolled back.
omarchy_arm_channel_restore_sync() {
  local stage="$1"
  [[ -f $stage/restore-sync ]] || return 0
  local dbpath
  dbpath=$(pacman-conf --config "$stage/frozen.conf" DBPath) || return
  sudo bash -euo pipefail -c '
    dbpath="$1"; stage="$2"
    if ! (set -C; : >"$dbpath/db.lck") 2>/dev/null; then
      echo "Cannot restore channel sync cache while another pacman holds its lock." >&2
      exit 1
    fi
    cleanup() { rm -f "$dbpath/db.lck"; }
    trap cleanup EXIT
    if ! diff -qr "$dbpath/sync" "$stage/applied-sync" >/dev/null; then
      echo "Sync databases changed independently; preserving them and the recovery backup." >&2
      exit 1
    fi
    rm -rf "$dbpath/sync"
    if [[ -d $stage/previous-sync ]]; then
      cp -a "$stage/previous-sync" "$dbpath/sync"
    fi
    rm "$stage/restore-sync"
  ' bash "$dbpath" "$stage"
}

omarchy_arm_channel_key_fingerprints() {
  sudo gpg --homedir "$1" --batch --with-colons --list-keys 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }' | sort
}

# Trust the pinned new primary only inside the private transaction keyring.
omarchy_arm_channel_trust_fork() {
  local keyring="$1"
  local active_key="FBD6874D423C418DDB6D143EECE19CDDE306DBD2"
  local fork_keyfile="${OMARCHY_SIGNING_SOURCE:-$OMARCHY_PATH}/default/pacman/keyrings/omarchy-mac.gpg"
  if ! sudo gpg --homedir "$keyring" --batch --list-keys "$active_key" >/dev/null 2>&1; then
    [[ -f $fork_keyfile && ! -L $fork_keyfile ]] || {
      echo "Pinned Omarchy Mac signing key is missing or unsafe: $fork_keyfile" >&2
      return 1
    }
    sudo pacman-key --gpgdir "$keyring" --add "$fork_keyfile" || return 1
  fi
  omarchy_arm_channel_key_fingerprints "$keyring" | grep -qxF "$active_key" || return 1
  sudo pacman-key --gpgdir "$keyring" --lsign-key "$active_key" || return 1
}

# Preflight has no installed-package/config/keyring side effects. The caller
# retains this directory until applying or abandoning the captured transaction.
omarchy_arm_channel_prepare() {
  local stage="$1" channel="$2" allow_new="${3:-}"
  local config="${OMARCHY_PACMAN_CONFIG:-/etc/pacman.conf}"
  local dbpath repo name version filename hash size extra pair_version=""
  local required available archive cache gpgdir keyfile
  local -a targets=() caches=()
  chmod 755 "$stage"
  mkdir -m 755 "$stage/db" "$stage/cache" "$stage/repos"
  cp "$config" "$stage/original.conf"
  omarchy_arm_channel_render "$config" "$channel" "$stage/lane.conf" "$allow_new"
  omarchy_arm_render_package_sources "$stage/lane.conf" >"$stage/source.conf"
  pacman-conf --config "$stage/source.conf" >"$stage/resolved.conf"
  dbpath=$(pacman-conf --config "$stage/source.conf" DBPath)
  sudo cp -a "$dbpath/local" "$stage/db/local"

  # Verification may import keys even during download-only. Give libalpm a
  # private copy of public trust, never the live keyring or its secret keys.
  gpgdir=$(pacman-conf --config "$stage/resolved.conf" GPGDir)
  sudo install -d -m 700 "$stage/keyring"
  for keyfile in pubring.gpg pubring.kbx trustdb.gpg gpg.conf; do
    if sudo test -f "$gpgdir/$keyfile"; then
      sudo cp -p "$gpgdir/$keyfile" "$stage/keyring/$keyfile"
    fi
  done
  # The copied ring deliberately excludes host secret keys. Give this private
  # ring its own disposable local-signing key before trusting pinned signers.
  sudo pacman-key --gpgdir "$stage/keyring" --init
  # Fresh bases may lack the declared upstream stack signer. Bootstrap only
  # that exact fingerprint into private trust, using an ephemeral local signer.
  local key="40DFB630FF42BCFFB047046CF0134EE680CAC571"
  if [[ $allow_new == "fresh" ]] && ! sudo gpg --homedir "$stage/keyring" --batch --list-keys "$key" >/dev/null 2>&1; then
    sudo pacman-key --gpgdir "$stage/keyring" --recv-keys "$key" --keyserver hkps://keys.openpgp.org
    omarchy_arm_channel_key_fingerprints "$stage/keyring" | grep -qxF "$key" || return 1
  fi
  if [[ $allow_new == "fresh" ]]; then
    sudo pacman-key --gpgdir "$stage/keyring" --lsign-key "$key"
  fi
  omarchy_arm_channel_trust_fork "$stage/keyring" || return 1
  omarchy_arm_channel_key_fingerprints "$stage/keyring" >"$stage/keys-before"
  local -a probe=(--config "$stage/resolved.conf" --dbpath "$stage/db" --cachedir "$stage/cache" --gpgdir "$stage/keyring" --logfile "$stage/preflight.log")
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman "${probe[@]}" -Sy --noconfirm
  sudo pacman "${probe[@]}" -Sl omarchy-aarch64 >"$stage/lane-packages"
  for name in omarchy omarchy-settings; do
    version=$(awk -v name="$name" '$1 == "omarchy-aarch64" && $2 == name { print $3 }' "$stage/lane-packages")
    if [[ -z $version || $version == *$'\n'* || ( -n $pair_version && $version != "$pair_version" ) ]]; then
      echo "The $channel lane does not provide one matching omarchy/omarchy-settings package pair. Current configuration is unchanged." >&2
      return 1
    fi
    pair_version=$version
    targets+=("omarchy-aarch64/$name=$version")
  done
  targets+=(--ignore omarchy,omarchy-settings)
  while read -r name; do targets+=("$name"); done < <(omarchy_arm_package_upgrade_args)

  local format='%r %n %v %f %h %s'
  sudo pacman "${probe[@]}" -Sup --needed --noconfirm --ask 4 --print-format "$format" "${targets[@]}" >"$stage/expected"
  required=$(awk '{ if ($6 !~ /^[0-9]+$/) exit 1; total += $6 } END { printf "%.0f", total + 104857600 }' "$stage/expected")
  available=$(df -B1 --output=avail "$stage" | tail -1 | tr -d '[:space:]')
  if [[ ! $available =~ ^[0-9]+$ ]] || (( available < required )); then
    echo "Insufficient disk space for channel archives ($required bytes required)." >&2
    return 1
  fi
  # Download-only verifies the configured signature policy without installing
  # a keyring or changing any installed package. Missing trust fails here.
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman "${probe[@]}" -Suw --needed --noconfirm --ask 4 "${targets[@]}"
  omarchy_arm_channel_key_fingerprints "$stage/keyring" >"$stage/keys-after"
  if ! cmp -s "$stage/keys-before" "$stage/keys-after"; then
    echo "Preflight required an undeclared signing key. Current configuration and live keyring are unchanged." >&2
    return 1
  fi
  caches=("$stage/cache")
  while read -r cache; do caches+=("$cache"); done < <(pacman-conf --config "$stage/resolved.conf" CacheDir)

  pacman-conf --config "$stage/resolved.conf" --repo-list >"$stage/repositories"
  while read -r repo; do
    [[ $repo =~ ^[[:alnum:]_.-]+$ ]] || { echo "Invalid repository name: $repo" >&2; return 1; }
    mkdir -m 755 "$stage/repos/$repo"
    sudo cp "$stage/db/sync/$repo.db" "$stage/repos/$repo/$repo.db"
    if [[ -f $stage/db/sync/$repo.db.sig ]]; then
      sudo cp "$stage/db/sync/$repo.db.sig" "$stage/repos/$repo/$repo.db.sig"
    fi
  done <"$stage/repositories"
  while read -r repo name version filename hash size extra; do
    [[ -n $repo ]] || continue
    if [[ -n $extra || ! $filename =~ ^[[:alnum:]_.+:-]+$ || ! $hash =~ ^[[:xdigit:]]{64}$ || ! $size =~ ^[0-9]+$ || ! -d $stage/repos/$repo ]]; then
      echo "Invalid package manifest entry: $name" >&2
      return 1
    fi
    archive=""
    for cache in "${caches[@]}"; do
      if [[ -f $cache/$filename ]]; then archive="$cache/$filename"; break; fi
    done
    [[ -n $archive ]] || { echo "Downloaded archive is missing: $filename" >&2; return 1; }
    printf '%s  %s\n' "$hash" "$archive" | sha256sum -c -
    if [[ -f $archive.sig ]]; then
      sudo cp "$archive.sig" "$stage/repos/$repo/$filename.sig"
    fi
    if [[ $archive == "$stage/cache/$filename" ]]; then
      sudo mv "$archive" "$stage/repos/$repo/$filename"
    else
      sudo cp "$archive" "$stage/repos/$repo/$filename"
    fi
  done <"$stage/expected"

  # Flattened options retain the real root/db/keyring, Includes have already
  # been resolved, and every repository now has exactly one local server.
  # A custom transfer command must not turn file:// back into a network fetch.
  awk -v base="$stage/repos" -v keyring="$stage/keyring" '
    /^[[:space:]]*GPGDir[[:space:]]*=/ { print "GPGDir = " keyring; next }
    /^[[:space:]]*(Server|CacheServer|XferCommand)[[:space:]]*=/ { next }
    /^\[/ {
      print
      if ($0 != "[options]") { repo = $0; gsub(/^\[|\]$/, "", repo); print "Server = file://" base "/" repo }
      next
    }
    { print }
  ' "$stage/resolved.conf" >"$stage/frozen.conf"
  printf '%s\n' "$config" >"$stage/config-path"
  printf '%s\n' "$channel" >"$stage/channel"
  printf '%s\n' "$pair_version" >"$stage/pair-version"
  printf '%s\n' "${targets[@]}" >"$stage/targets"
}

# Called within the updater's existing lock/snapshot boundary, or by a fresh
# installer after preflight. Preserve libalpm sysupgrade and replace semantics.
omarchy_arm_channel_apply_prepared() {
  local stage="$1" config channel pair_version dbpath sync_status=0
  local format='%r %n %v %f %h %s'
  local -a targets
  config=$(<"$stage/config-path")
  channel=$(<"$stage/channel")
  pair_version=$(<"$stage/pair-version")
  mapfile -t targets <"$stage/targets"
  if ! cmp -s "$config" "$stage/original.conf"; then
    echo "pacman.conf changed during channel preparation. Preserving it; retry after reviewing the change." >&2
    return 1
  fi
  # A different lane may have an equal or older database timestamp. Force the
  # captured database into the real sync cache before comparing transactions.
  dbpath=$(pacman-conf --config "$stage/frozen.conf" DBPath)
  if [[ -d $dbpath/sync ]]; then
    sudo cp -a "$dbpath/sync" "$stage/previous-sync"
  fi
  sudo env OMARCHY_UPDATE_PACMAN=1 pacman --config "$stage/frozen.conf" -Syy --noconfirm || sync_status=$?
  sudo cp -a "$dbpath/sync" "$stage/applied-sync"
  touch "$stage/restore-sync"
  (( sync_status == 0 )) || return "$sync_status"
  sudo pacman --config "$stage/frozen.conf" -Sup --needed --noconfirm --ask 4 --print-format "$format" "${targets[@]}" >"$stage/actual"
  if ! diff -u "$stage/expected" "$stage/actual"; then
    echo "Installed package state changed during channel preparation. Retry; the active configuration is unchanged." >&2
    return 1
  fi
  if ! sudo env LC_ALL=C OMARCHY_UPDATE_PACMAN=1 pacman --config "$stage/frozen.conf" -Syu --needed --noconfirm --ask 4 "${targets[@]}" 2>&1 | tee "$stage/transaction-output"; then
    echo "Channel transaction failed; no new channel configuration was committed. Package hooks may have run; installed pair:" >&2
    pacman --config "$stage/frozen.conf" -Q omarchy omarchy-settings >&2 || true
    return 1
  fi
  # libalpm may exit zero after a failed post-transaction hook.
  if grep -q '^error:' "$stage/transaction-output"; then
    echo "Packages may be installed, but pacman reported a transaction/hook error. Channel configuration was not committed; inspect the output and installed state." >&2
    return 1
  fi
  if ! cmp -s "$config" "$stage/original.conf"; then
    echo "Packages were installed, but pacman.conf changed during the transaction. Preserving it; inspect the configuration before retrying the channel switch." >&2
    return 1
  fi
  sudo cp -p "$config" "$config.bak"
  sudo install -m 644 "$stage/source.conf" "$config"
  rm "$stage/restore-sync"
  echo "ARM package channel is now $channel ($pair_version)."
  echo "The selected upstream graphics stack and distribution dependencies were resolved at transaction time."
}

omarchy_arm_channel_apply() (
  set -euo pipefail
  local stage
  stage=$(omarchy_arm_channel_stage_new)
  trap 'omarchy_arm_channel_stage_remove "$stage"' EXIT
  omarchy_arm_channel_prepare "$stage" "$1"
  omarchy_arm_channel_apply_prepared "$stage"
)
