# Official migrations a migrated Mac records as done, and the repairs a fresh
# image does not need.
# shellcheck disable=SC2154

# Official migrations a migrated Mac records as done instead of running them,
# as a fresh Mac image has them (reviewed for ticket 53): initramfs and
# boot-chain repairs for the x86 Limine, T2, NVIDIA and linux-omarchy paths,
# whose Mac counterparts are this package's; the Intel Mac Broadcom quirk, which breaks
# Apple Silicon Wi-Fi; and systemd-oomd, which stays off on Macs. Every other official
# migration still pending runs on the next omarchy update, as on any install
# that upgraded. An adapter adds what its cohort already applied, and each
# repair below adds the Mac migration whose work it did.
settled_migrations="1784476564 1784917531 1785273276 1785424256 1785944594 1786137597 1786391100 1786482992 1786605598 1789325478 1789444024"
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

# --- Fork leftovers --------------------------------------------------------------
#
# Earlier Apple installs and omarchy-mx-mac wrote these files, which the Mac
# packages now ship as vendor defaults (omarchy-mac retired them itself until
# omacom/omarchy-mac-pkgs da8279b handed that to this migration). A copy that
# is byte for byte the one they wrote goes, kept beside itself as
# NAME.omarchy-mac-retired; an edited copy, a link (a mask included) or a
# different backup stays as it is.

# The bytes a fork wrote as NAME.
leftover() {
  case $1 in
    wifi_backend.conf)
      cat <<'LEFTOVER'
[device]
wifi.backend=iwd
LEFTOVER
      ;;
    asahi-notch.conf)
      cat <<'LEFTOVER'
options appledrm show_notch=1
LEFTOVER
      ;;
    omarchy-wifi-resume-fix.service)
      cat <<'LEFTOVER'
[Unit]
Description=Reload brcmfmac if Wi-Fi does not return after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/omarchy-wifi-resume-fix
TimeoutStartSec=120

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
LEFTOVER
      ;;
    asahi-headset-mic.conf)
      cat <<'LEFTOVER'
# The 3.5mm headset mic stays in the source list with nothing plugged in.
# Apps often pick it over the built-in array because it advertises a MONO map.
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "alsa_input.platform-sound.HiFi__Headset__source" }
    ]
    actions = {
      update-props = {
        priority.session = 1
      }
    }
  }
]
LEFTOVER
      ;;
    asahi-audio-no-suspend.conf)
      cat <<'LEFTOVER'
## Keep the Apple Silicon speaker and headphone outputs open between streams.
##
## PipeWire suspends an idle sink after five seconds. On Apple Silicon Macs that
## closes the ALSA device and powers down the TAS2764 speaker amplifiers (and
## the headphone codec); the next stream reopens the device and the amplifiers
## power back up with an audible pop, so every start and stop of playback
## clicks. A zero timeout keeps that node open so the amplifiers stay powered.
##
## Matched by api.alsa.path rather than node.name because the Asahi rules in
## /usr/share/wireplumber/wireplumber.conf.d/99-asahi.conf rename the speaker
## node and hide it behind the per-model filter chain. Device 1 is the speaker
## array and device 0 the headphone jack on every AppleJ model.

monitor.alsa.rules = [
  {
    matches = [
      {
        api.alsa.path = "~hw:AppleJ[0-9][0-9][0-9],[01]"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
LEFTOVER
      ;;
    asahi-audio-no-suspend-overlay.conf)
      cat <<'LEFTOVER'
## Keep the Apple Silicon speaker and headphone outputs open between streams.
##
## PipeWire suspends an idle sink after five seconds. On Apple Silicon Macs that
## closes the ALSA device and powers down the TAS2764 speaker amplifiers (and
## the headphone codec); the next stream reopens the device and the amplifiers
## power back up with an audible pop, so every start and stop of playback
## clicks. A zero timeout keeps that node open so the amplifiers stay powered.
## The companion software-dsp.lua overlay also stops the asahi-audio convolver
## graph from pausing when a client (Chromium, mpv, ...) closes its stream.
##
## Matched by api.alsa.path rather than node.name because the Asahi rules in
## /usr/share/wireplumber/wireplumber.conf.d/99-asahi.conf rename the speaker
## node and hide it behind the per-model filter chain. Device 1 is the speaker
## array and device 0 the headphone jack on every AppleJ model.

monitor.alsa.rules = [
  {
    matches = [
      {
        api.alsa.path = "~hw:AppleJ[0-9][0-9][0-9],[01]"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
LEFTOVER
      ;;
    *) return 1 ;;
  esac
}

# Writes every leftover into DIR, readable by every user.
write_leftovers() {
  local dir=$1 name
  install -d -m 755 "$dir" || return 1
  for name in wifi_backend.conf asahi-notch.conf omarchy-wifi-resume-fix.service asahi-headset-mic.conf asahi-audio-no-suspend.conf asahi-audio-no-suspend-overlay.conf; do
    leftover "$name" >"$dir/$name" && chmod 644 "$dir/$name" || return 1
  done
}

# FILE goes when it is the regular file ORIGINAL holds byte for byte. Fails
# when a backup that differs is in the way.
retire_copy() {
  local file=$1 original=$2
  [[ -f $file && ! -L $file ]] && cmp -s "$file" "$original" || return 0
  if [[ -e $file.omarchy-mac-retired || -L $file.omarchy-mac-retired ]]; then
    if ! cmp -s "$file" "$file.omarchy-mac-retired"; then
      echo "$file.omarchy-mac-retired differs from $file; move it aside and run the migration again" >&2
      return 1
    fi
    rm -- "$file"
  else
    mv -- "$file" "$file.omarchy-mac-retired"
  fi
}

# The machine's leftovers: the Wi-Fi backend and notch settings, and the Wi-Fi
# resume unit, whose enablement links into /etc are pointed at the vendor unit
# omarchy-mac ships.
retire_system_leftovers() {
  local dir=$state/leftovers unit=omarchy-wifi-resume-fix.service target link
  write_leftovers "$dir" || die "cannot stage the fork's leftover files"
  retire_copy "$R/etc/NetworkManager/conf.d/wifi_backend.conf" "$dir/wifi_backend.conf" &&
    retire_copy "$R/etc/modprobe.d/asahi-notch.conf" "$dir/asahi-notch.conf" &&
    retire_copy "$R/etc/systemd/system/$unit" "$dir/$unit" || die "cannot retire the fork's leftover files"
  if [[ ! -e $R/etc/systemd/system/$unit && ! -L $R/etc/systemd/system/$unit ]] &&
    cmp -s "$R/etc/systemd/system/$unit.omarchy-mac-retired" "$dir/$unit"; then
    for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
      link=$R/etc/systemd/system/$target.target.wants/$unit
      if [[ -L $link && $(readlink "$link") == "/etc/systemd/system/$unit" ]]; then
        ln -sfn "/usr/lib/systemd/system/$unit" "$link" || die "cannot point $link at the vendor unit"
      fi
    done
  fi
}

# A user's leftovers: the WirePlumber policies the fork copied into each
# user's configuration, retired as that user.
retire_user_leftovers() {
  local user=$1 home=$2 dir=$state/leftovers policies=$R$2/.config/wireplumber/wireplumber.conf.d
  [[ -d $policies && ! -L $policies ]] || return 0
  [[ -d $dir ]] || write_leftovers "$dir" || return 1
  # shellcheck disable=SC2016 # expanded by the user's shell
  as_user "$user" "$R$home" bash -c "$(declare -f retire_copy)"'
    retire_copy "$1/asahi-headset-mic.conf" "$2/asahi-headset-mic.conf" &&
      retire_copy "$1/asahi-audio-no-suspend.conf" "$2/asahi-audio-no-suspend.conf" &&
      retire_copy "$1/asahi-audio-no-suspend.conf" "$2/asahi-audio-no-suspend-overlay.conf"' _ "$policies" "$dir"
}
