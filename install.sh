#!/bin/bash

# Omarchy Mac is retired, so this refuses before it touches the machine.
echo "Omarchy Mac is now part of Omarchy for Apple Silicon, so it can't start new installs." >&2
echo "Install the official Omarchy for Apple Silicon: brew install omacom/mac/omarchy" >&2
echo "Mac support page: https://github.com/omacom/omarchy/blob/quattro/manual/44-mac-support.md#coming-from-omarchy-mac" >&2
exit 1

# Exit immediately if a command exits with a non-zero status
#set -eEo pipefail

# Terminal control codes
export ANSI_HIDE_CURSOR="\033[?25l"
export ANSI_SHOW_CURSOR="\033[?25h"
export ANSI_CLEAR_SCREEN="\033[2J\033[H"

# Show cursor on exit (cleanup trap to prevent ghosting)
trap 'printf "$ANSI_SHOW_CURSOR"; sudo -k; kill ${SUDO_KEEPALIVE_PID:-} 2>/dev/null' EXIT INT TERM

# Hide cursor during installation for cleaner display
printf "$ANSI_HIDE_CURSOR"

# Validate sudo access and refresh timestamp at the start
echo "🔐 Omarchy Mac Installation requires administrator access..."
if ! sudo -v; then
  printf "$ANSI_SHOW_CURSOR"
  echo "❌ Error: sudo access required. Please run with proper permissions."
  exit 1
fi

# Keep sudo alive throughout installation to prevent password re-prompts
keep_sudo_alive() {
  while true; do
    sudo -v
    sleep 50
  done
}

keep_sudo_alive &
SUDO_KEEPALIVE_PID=$!

# Clear any lingering password prompts from display (fixes ghosting)
printf "$ANSI_CLEAR_SCREEN"

# Define Omarchy locations
export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export OMARCHY_INSTALL_LOG_FILE="/var/log/omarchy-install.log"
export OMARCHY_BIN="$OMARCHY_PATH/bin"
export PATH="$OMARCHY_PATH/bin:$PATH"

# Set default compilation flags (do not suppress warnings or disable FORTIFY_SOURCE)
export CFLAGS=""
export CXXFLAGS=""
export CPPFLAGS=""
export LDFLAGS=""
export MAKEFLAGS="-s"

# Guardrail: install.sh must run from a cloned repo
if [[ ! -d "$OMARCHY_INSTALL" ]]; then
  echo "❌ Error: $OMARCHY_INSTALL not found."
  echo "This installer must be run from a cloned Omarchy repo in $OMARCHY_PATH."
  echo "Recommended:" 
  echo "  wget -qO- https://malik-na.codeberg.page/omarchy-mac/boot.sh | bash"
  exit 1
fi

# Set locale first for proper TUI display
source "$OMARCHY_INSTALL/preflight/locale.sh"

# Install
source "$OMARCHY_INSTALL/helpers/all.sh"
source "$OMARCHY_INSTALL/preflight/all.sh"
source "$OMARCHY_INSTALL/packaging/all.sh"
source "$OMARCHY_INSTALL/config/all.sh"
source "$OMARCHY_INSTALL/login/all.sh"
source "$OMARCHY_INSTALL/post-install/all.sh"

# Show cursor at completion
printf "$ANSI_SHOW_CURSOR"
