# The x86 ISO asks for a timezone while provisioning and applies it on first
# boot (omarchy-provision-owner: omarchy_prompt_timezone, then
# configure_timezone). None of that runs on a Mac, so the machine keeps
# whatever Asahi Alarm shipped -- UTC -- and every clock, log timestamp and
# calendar entry is wrong until somebody notices.
#
# First run is a graphical session with nowhere to ask, so this follows the
# pattern wifi.sh uses for the same problem: notify, and open a terminal for
# the one step that needs a person.

current_timezone() {
  timedatectl show --property=Timezone --value 2>/dev/null
}

# UTC is what the image ships, so it stands in for "nobody has chosen yet".
# Someone genuinely in UTC gets one notification and dismisses it, which is a
# better failure than a machine quietly running on the wrong clock.
timezone_needs_setting() {
  local timezone
  timezone=$(current_timezone)
  [[ -z $timezone || $timezone == "UTC" ]]
}

if timezone_needs_setting; then
  omarchy-notification-send -u critical -g 󰥔 "Set your timezone" \
    "This machine is on $(current_timezone). Click to choose yours." \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-cmd-tzupdate-enhanced
fi
