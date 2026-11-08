# The target: which channel this Mac moves to, the packages and pacman
# configuration it ends with, and whether that channel is ready for Macs.
# shellcheck disable=SC2034,SC2154

# The Omarchy packaging key omarchy-keyring carries.
official_key=40DFB630FF42BCFFB047046CF0134EE680CAC571
# Trust the converged system never keeps: the forks' repositories and keys
# (omarchy-mac's rc4 channel key and mx-mac's). Adapters add their own.
retired_repos=(omarchy-aarch64)
retired_keys=(FBD6874D423C418DDB6D143EECE19CDDE306DBD2 C81AC3E2A99556F9B21D5FEA3DD49BC9F8360BDC)
# The repositories the core configuration defines; any other one is the
# administrator's and is kept.
core_repos="omarchy asahi-alarm core extra alarm aur"
candidate_repo=omarchy-mac-candidate
admin_target=$R/etc/omarchy-mac/migration-target
# The image builder's test-image pin (omarchy-mac-installer
# image-builder/builder/test_image_pin.py): its first line, a reason line and
# the IgnorePkg line.
test_pin_mark="# Test image only (omarchy-mac-installer image-builder)"
guard_mark="# omarchy-mac-migrate: a migration to Omarchy's packages is in progress."

# The runtime pair a channel's Macs run: Omarchy's edge builds its runtime from
# the development branch as omarchy-dev.
channel_pair() {
  if [[ $1 == "edge" ]]; then
    echo "omarchy-dev omarchy-settings-dev"
  else
    echo "omarchy omarchy-settings"
  fi
}

# Every package a migrated Mac takes from its channel's [omarchy].
channel_packages() {
  echo "$(channel_pair "$1") omarchy-mac omarchy-mac-boot linux-aurora linux-aurora-headers m1n1-aurora uboot-asahi limine-mkinitcpio-hook"
}

# Installed or refreshed in the same transaction, from whichever repository
# carries them: the keyrings official trust comes from.
keyring_packages="asahi-alarm-keyring omarchy-keyring"

# Held back with the transaction's packages while the migration is in
# progress: the rest of the boot chain they build on.
guarded_boot="limine limine-snapper-sync asahi-scripts mkinitcpio"

# key=value lines, comments and blank lines ignored, anything else refused.
#   format=1
#   type=repository | candidate-set
#   channel=stable | rc | edge          the [omarchy] channel after the switch
#   server=URL                          optional; https://pkgs.omarchy.org/<channel>/$arch
#   keyring=FINGERPRINT                 optional; the Omarchy packaging key
#   packages=NAME...                    repository only; optional
#   set=DIR                             candidate-set: the set's files, manifest.json and signing.json
#   fingerprint=FINGERPRINT             candidate-set: the only key its signatures may carry
load_target() {
  local file=$1 frozen=${2:-} line key value format="" packages=""
  target_type="" target_channel="" target_server="" target_keyring=$official_key
  target_set="" target_fingerprint="" target_repo=omarchy
  trusted "$file" || refuse "refusing the target $file: it must be a regular file owned by root and writable only by root"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line && $line != \#* ]] || continue
    [[ $line == *=* ]] || refuse "the target $file is malformed: $line"
    key=${line%%=*}
    value=${line#*=}
    case $key in
      format) format=$value ;;
      type) target_type=$value ;;
      channel) target_channel=$value ;;
      server) target_server=$value ;;
      keyring) target_keyring=${value^^} ;;
      packages) packages=$value ;;
      set) target_set=${value%/} ;;
      fingerprint) target_fingerprint=${value^^} ;;
      *) refuse "the target $file has an unknown key: $key" ;;
    esac
  done <"$file"
  [[ $format == "1" ]] || refuse "the target $file is not format=1"
  [[ $target_channel =~ ^(stable|rc|edge)$ ]] || refuse "the target $file names no channel (stable, rc or edge)"
  if [[ -z $target_server ]]; then
    target_server="https://pkgs.omarchy.org/$target_channel/\$arch"
    # Unprivileged tests serve the channels themselves.
    if (( fixture )) && [[ -n ${OMARCHY_MAC_MIGRATE_SERVER:-} ]]; then
      target_server=${OMARCHY_MAC_MIGRATE_SERVER//@channel@/$target_channel}
    fi
  fi
  [[ $target_server =~ ^(https|file):// ]] || refuse "the target server must be https:// or file://: $target_server"
  [[ $target_keyring =~ ^[0-9A-F]{40}$ ]] || refuse "the target keyring must be a 40-digit fingerprint"
  target_packages=${packages:-$(channel_packages "$target_channel")}
  case $target_type in
    repository)
      target_id="repository $target_server"
      ;;
    candidate-set)
      [[ $target_fingerprint =~ ^[0-9A-F]{40}$ ]] || refuse "a candidate-set target needs its signer's 40-digit fingerprint"
      target_repo=$candidate_repo
      if [[ -n $frozen ]]; then
        # After preflight only the verified copy counts; the original may be gone.
        target_set=$set_copy
      else
        [[ $target_set == /* ]] && trusted "$target_set" || refuse "the candidate set $target_set must be a root-owned directory writable only by root"
        [[ -f $target_set/manifest.json ]] || refuse "the candidate set has no manifest.json"
      fi
      candidate_identity "$target_set" || refuse "cannot read the candidate manifest"
      ;;
    *)
      refuse "the target $file has no type (repository or candidate-set)"
      ;;
  esac
}

# A candidate set's packages join the channel's: what the set carries comes
# from it, the rest of the Mac set from the channel's [omarchy].
candidate_identity() {
  local names
  names=$(jq -r '.packages[].name' "$1/manifest.json") || return 1
  target_packages=$( { printf '%s\n' $(channel_packages "$target_channel"); printf '%s\n' "$names"; } | awk '!seen[$0]++' | xargs) &&
    target_id="candidate-set $(jq -r '.set' "$1/manifest.json") $(jq -r '.set_sha256' "$1/manifest.json")"
}

# How the transaction names NAME: from the candidate set when it carries it,
# else from [omarchy].
target_spec() {
  if [[ $target_type == "candidate-set" ]] && jq -e --arg name "$1" '.packages[] | select(.name == $name)' "$target_set/manifest.json" >/dev/null; then
    printf '%s/%s\n' "$candidate_repo" "$1"
  else
    printf 'omarchy/%s\n' "$1"
  fi
}

# --target, else the administrator's target.
find_target() {
  local candidate
  for candidate in "$@" "$admin_target"; do
    if [[ -n $candidate && -e $candidate ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

# The channel this Mac's own configuration follows: an omarchy-mac lane
# ([omarchy-aarch64] on omarchy-mac/omarchy-pkgs-aarch64's releases, which
# quattro names after the channel), else an official [omarchy]. Anything else
# is unknown.
config_channel() {
  local conf=$1 lane official
  lane=$(section_servers "$conf" omarchy-aarch64 | sed -nE 's#^https://github\.com/omarchy-mac/omarchy-pkgs-aarch64/releases/download/(stable|rc|edge)/?$#\1#p' | sort -u)
  official=$(section_servers "$conf" omarchy | sed -nE 's#^https://pkgs\.omarchy\.org/(stable|rc|edge)/(\$arch|aarch64)/?$#\1#p' | sort -u)
  if [[ -n $(section_servers "$conf" omarchy-aarch64) ]]; then
    [[ -n $lane && $lane != *$'\n'* ]] && printf '%s\n' "$lane"
  elif [[ -n $official && $official != *$'\n'* ]]; then
    printf '%s\n' "$official"
  else
    return 1
  fi
}

# The Server values of SECTION in CONF.
section_servers() {
  awk -v want="$2" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    name == want && /^[[:space:]]*Server[[:space:]]*=/ { value = $0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value); print value }' "$1"
}

# The channel this Mac follows, or nothing when it cannot be told. An mx-mac
# Mac follows the fork's channel record; the rest follow their configuration.
detect_channel() {
  local cohort=$1 conf=$2 channel=""
  if [[ $cohort == "mx-mac" ]]; then
    if command -v omarchy-apple-silicon-channel >/dev/null; then
      channel=$(omarchy-apple-silicon-channel current 2>/dev/null) || channel=""
    fi
  else
    channel=$(config_channel "$conf") || channel=""
  fi
  [[ $channel =~ ^(stable|rc|edge)$ ]] && printf '%s\n' "$channel"
}

# A repository target for CHANNEL, written to FILE: what a Mac with no
# administrator's target moves to.
write_channel_target() {
  printf 'format=1\ntype=repository\nchannel=%s\n' "$1" >"$2"
  chmod 644 "$2"
}

# The core Apple Silicon configuration (omacom/omarchy #13362,
# default/pacman/apple-silicon/pacman-edge.conf), with SERVER for [omarchy].
# Unprivileged tests name their own Asahi ALARM server.
core_pacman_conf() {
  local asahi=https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64
  (( ! fixture )) || asahi=${OMARCHY_MAC_MIGRATE_ASAHI_SERVER:-$asahi}
  cat <<CONF
# See the pacman.conf(5) manpage for option and repository directives

[options]
Color
ILoveCandy
VerbosePkgLists
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
DownloadUser = alpm

# By default, pacman accepts packages signed by keys that its local keyring
# trusts (see pacman-key and its man page), as well as unsigned packages.
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

# pacman searches repositories in the order defined here. Omarchy comes first on
# Apple Silicon, so its builds for the Mac (the Aurora kernel, m1n1, U-Boot and
# the Hyprland stack) win over the same names in Asahi ALARM and Arch Linux ARM.
[omarchy]
Server = $1

[asahi-alarm]
Server = $asahi

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist

[aur]
Include = /etc/pacman.d/mirrorlist
CONF
}

# The administrator's own [options] lines of CONF: every option the core
# configuration does not set, without the test-image pin and this migration's
# guard. Comments and blank lines go.
admin_options() {
  awk -v pin="$test_pin_mark" -v guard="$guard_mark" '
    BEGIN { split("Color ILoveCandy VerbosePkgLists HoldPkg Architecture CheckSpace ParallelDownloads DownloadUser SigLevel LocalFileSigLevel RemoteFileSigLevel", list, " "); for (i in list) core[list[i]] = 1 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    name != "options" { next }
    index($0, pin) == 1 || index($0, guard) == 1 { skip = 2; next }
    skip > 0 && /^#/ { skip--; next }
    skip > 0 && /^[[:space:]]*IgnorePkg[[:space:]]*=/ { skip = 0; next }
    { skip = 0 }
    /^[[:space:]]*(#|$)/ { next }
    { key = $0; sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*=.*$/, "", key); sub(/[[:space:]]+$/, "", key); if (!(key in core)) print }' "$1"
}

# The test-image pin block of CONF, as it is written.
test_pin_block() {
  awk -v pin="$test_pin_mark" '
    index($0, pin) == 1 { keep = 3 }
    keep > 0 { print; keep-- }' "$1"
}

# CONF's repositories that are neither the core ones nor retired, whole.
admin_repositories() {
  local drop
  drop="$core_repos ${retired_repos[*]} $candidate_repo"
  awk -v drop="$drop" '
    BEGIN { n = split(drop, list, " "); for (i = 1; i <= n; i++) skip[list[i]] = 1; skip["options"] = 1 }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); keep = !(name in skip) }
    keep { print }' "$1"
}

# The configuration after the switch: the core one for the target, with the
# administrator's own options and repositories kept. Applying it to its own
# output changes nothing.
future_pacman_conf() {
  local conf=$1 options repositories
  options=$(admin_options "$conf")
  repositories=$(admin_repositories "$conf")
  core_pacman_conf "$target_server" | awk -v options="$options" '
    { print }
    /^LocalFileSigLevel/ && options != "" { print ""; print "# Kept from this Mac'"'"'s configuration"; print options }'
  if [[ -n $repositories ]]; then
    printf '\n%s\n' "$repositories"
  fi
}

# CONF with this migration's guard as the first lines of [options], and the
# test-image pin of OLD kept below it: until the package transaction is done,
# a plain pacman -Syu leaves every package the migration changes alone.
guarded_pacman_conf() {
  local conf=$1 old=$2 names=$3 pin
  pin=$(test_pin_block "$old")
  awk -v guard="$guard_mark" -v names="$names" -v pin="$pin" '
    { print }
    /^\[options\][[:space:]]*$/ && !done {
      print guard " It removes these lines when its package transaction is done; sudo omarchy-mac-migrate run finishes it."
      print "IgnorePkg = " names
      if (pin != "") print pin
      done = 1
    }' "$conf"
}

# Administrator IgnorePkg entries (globs, as pacman reads them) matching a
# package this migration installs or removes, and IgnoreGroup entries holding
# one, one per line.
pinned_targets() {
  local conf=$1 names=$2 db=$3 pattern name group member
  for pattern in $(admin_options "$conf" | sed -nE 's/^[[:space:]]*IgnorePkg[[:space:]]*=//p'); do
    for name in $names; do
      # shellcheck disable=SC2053 # IgnorePkg takes globs
      [[ $name != $pattern ]] || printf '%s\n' "$name"
    done
  done
  for group in $(admin_options "$conf" | sed -nE 's/^[[:space:]]*IgnoreGroup[[:space:]]*=//p'); do
    for member in $(LC_ALL=C pacman --config "$4" --dbpath "$db" -Sgq "$group" 2>/dev/null); do
      [[ " $names " != *" $member "* ]] || printf '%s (group %s)\n' "$member" "$group"
    done
  done
}

# An Include in [options] or an option the switch cannot keep as it is.
unsupported_options() {
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); next }
    name == "options" && /^[[:space:]]*Include[[:space:]]*=/ { print "an Include in [options] (" $0 ")" }' "$1"
}

# --- Whether the channel is ready for Macs -----------------------------------
#
# A channel takes Macs once its [omarchy] carries the Mac packages built from
# omacom/omarchy-mac-pkgs with a runtime that drives them. That is read from
# the signed archives the transaction would install, not from repository
# metadata: the runtime ships the lifecycle dispatcher, and omarchy-mac-boot
# ships its setup-boot and update-verify operations and no migration engine of
# its own. Until then every Mac on the channel defers.

# The Mac packages the channel's repositories lack, one reason a line.
presence_problems() {
  local listing name
  listing=$(LC_ALL=C pacman --config "$1" --dbpath "$2" -Sl 2>/dev/null | awk '{ print $2 }' | LC_ALL=C sort -u)
  for name in $(channel_pair "$target_channel") omarchy-mac omarchy-mac-boot linux-aurora m1n1-aurora uboot-asahi; do
    grep -Fxq "$name" <<<"$listing" || echo "the $target_channel channel has no $name for Apple Silicon yet"
  done
}

# What the verified archives of the resolved runtime and omarchy-mac-boot
# lack, one reason a line.
archive_problems() {
  local resolved=$1 conf=$2 db=$3 runtime listing
  runtime=$(channel_pair "$target_channel")
  runtime=${runtime%% *}
  if listing=$(fetch_archive "$resolved" "$runtime" "$conf" "$db"); then
    listing=$(bsdtar -tf "$listing" 2>/dev/null | sed 's|^\./||')
    grep -qx 'usr/bin/omarchy-lifecycle-dispatch' <<<"$listing" ||
      echo "the $target_channel channel's $runtime has no omarchy-lifecycle-dispatch to drive the Mac packages yet"
    excluded_files "$listing"
  else
    echo "$listing"
  fi
  if listing=$(fetch_archive "$resolved" omarchy-mac-boot "$conf" "$db"); then
    listing=$(bsdtar -tf "$listing" 2>/dev/null | sed 's|^\./||')
    grep -qx 'usr/lib/omarchy/mac-boot/setup-boot' <<<"$listing" && grep -qx 'usr/lib/omarchy/mac-boot/update-verify' <<<"$listing" ||
      echo "the $target_channel channel's omarchy-mac-boot has no setup-boot and update-verify operations yet"
    ! grep -qx 'usr/lib/omarchy-mac/boot/migrate-engine.sh' <<<"$listing" ||
      echo "the $target_channel channel's omarchy-mac-boot is not built from omacom/omarchy-mac-pkgs yet"
    excluded_files "$listing"
  else
    echo "$listing"
  fi
}

# The administrator's NoExtract and NoUpgrade globs that keep a file of the
# migration's runtime or boot package (LISTING) from being installed as built.
excluded_files() {
  local listing=$1 pattern path
  while read -r pattern; do
    [[ -n $pattern && $pattern != !* ]] || continue
    while IFS= read -r path; do
      [[ -n $path && $path != */ ]] || continue
      # shellcheck disable=SC2053 # NoExtract and NoUpgrade take globs
      if [[ $path == $pattern ]]; then
        echo "NoExtract or NoUpgrade ($pattern) in $pacman_conf keeps $path from the packages the migration installs; remove it first"
        break
      fi
    done <<<"$listing"
  done < <(admin_options "$pacman_conf" | sed -nE 's/^[[:space:]]*(NoExtract|NoUpgrade)[[:space:]]*=[[:space:]]*//p' | tr ' ' '\n')
}
