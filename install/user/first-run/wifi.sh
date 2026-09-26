notify_update() {
  omarchy-notification-send -u critical -g  "Update System" "Click to update the system." \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-update
}

notify_wifi() {
  omarchy-notification-send -u critical -g 󰖩 "Setup Wi-Fi" "Click to configure the wireless network." \
    --exec omarchy-shell shell toggle omarchy.network
}

# nm-online counts a link-local-only link as connected. NetworkManager brings
# Thunderbolt networking (a Mac cabled to another computer) up that way, with no
# route out, so only a connection that holds a default route counts as online.
routable() {
  case "$(LC_ALL=C nmcli -t -f STATE general 2>/dev/null)" in
    "connected" | "connected (site only)") return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_routable() {
  local deadline=$((SECONDS + 3600))

  until routable; do
    ((SECONDS < deadline)) || return 1
    sleep 5
  done
}

announce_network() {
  # Ethernet is still negotiating DHCP when the session starts, so probing
  # right away calls a working machine offline. NetworkManager reports startup
  # complete once it has tried every connection it could auto-activate, which
  # is the first moment the answer means anything.
  nm-online -q -s -t 30

  # -x takes that answer as it stands rather than waiting out the timeout, so
  # a laptop with nothing to connect to gets prompted immediately.
  if ! nm-online -q -x -t 30 || ! routable; then
    notify_wifi
    # Nothing to update against until a link lands, so hold that prompt.
    wait_for_routable || return
  fi

  notify_update
}

# Detached, so a slow or absent connection never holds up the rest of first run.
announce_network &
