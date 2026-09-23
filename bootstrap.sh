#!/bin/bash

# =============================================================================
# Omarchy Mac Bootstrap Installer
# =============================================================================
# This script is intended to be run as root on a fresh Arch/Asahi install.
# It creates a user (wheel), installs core dependencies (sudo, git, base-devel),
# installs yay, clones the repo into the new user's home, and then runs install.sh.
# =============================================================================

set -euo pipefail

# When invoked from `wget ... | bash`, stdin may be the pipe (EOF).
# Prefer reading from the controlling terminal.
TTY_IN=""
if [[ -r /dev/tty ]]; then
    TTY_IN="/dev/tty"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
                                 ▄▄▄                                                   
 ▄█████▄    ▄███████████▄    ▄███████   ▄███████   ▄███████   ▄█   █▄    ▄█   █▄ 
████   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
████   ███  ███   ███   ███  ███   ███  ███   ███  ███   █▀   ███   ███  ███   ███
████   ███  ███   ███   ███ ▄███▄▄▄███ ▄███▄▄▄██▀  ███       ▄███▄▄▄███▄ ███▄▄▄███
████   ███  ███   ███   ███ ▀███▀▀▀███ ▀███▀▀▀▀    ███      ▀▀███▀▀▀███  ▀▀▀▀▀▀███
████   ███  ███   ███   ███  ███   ███ ██████████  ███   █▄   ███   ███  ▄██   ███
████   ███  ███   ███   ███  ███   ███  ███   ███  ███   ███  ███   ███  ███   ███
 ▀█████▀    ▀█   ███   █▀   ███   █▀   ███   ███  ███████▀   ███   █▀    ▀█████▀ 
                                                                             ███   █▀                                  

                                                MAC BOOTSTRAP INSTALLER
EOF
    echo -e "${NC}"
}

print_step() { echo -e "\n${BLUE}${BOLD}==>${NC}${BOLD} $1${NC}"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${CYAN}ℹ${NC} $1"; }

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-${LINENO}}"
    print_error "Bootstrap failed (exit ${exit_code}) at line ${line_no}."
    print_info "Command: ${BASH_COMMAND}"
    exit "${exit_code}"
}

trap on_error ERR

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        print_error "This script must be run as root."
        exit 1
    fi
}

prompt_keyboard() {
    local keymap answer listed
    keymap=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2>/dev/null | tr -d '"' | head -1) || keymap=""
    keymap=${keymap:-us}

    while true; do
        if ! read -r -p "Keyboard layout [$keymap] (? to list): " answer <"${TTY_IN:-/dev/null}"; then
            print_error "Keyboard selection requires a terminal."
            exit 1
        fi
        if [[ $answer == "?" ]]; then
            localectl --no-pager list-keymaps || true
            continue
        fi
        answer=${answer:-$keymap}
        listed=$(localectl --no-pager list-keymaps 2>/dev/null || true)
        if [[ -z $listed ]] || grep -qixF "$answer" <<<"$listed"; then
            if [[ -n $listed ]]; then
                keymap=$(grep -ixF "$answer" <<<"$listed" | head -1)
            else
                keymap=$answer
            fi
            break
        fi
        print_warning "Unknown keyboard layout: $answer. Type ? to see available layouts."
    done

    if [[ $(tty <"${TTY_IN:-/dev/null}" 2>/dev/null) == /dev/tty* ]]; then
        loadkeys "$keymap" || { print_error "Could not activate keyboard layout $keymap"; exit 1; }
    fi
    localectl set-keymap "$keymap" || { print_error "Could not save keyboard layout $keymap"; exit 1; }
}

valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

prompt_username() {
    local input
    while true; do
        if [[ -n "${OMARCHY_USER_NAME:-}" ]]; then
            input="$OMARCHY_USER_NAME"
        else
            if [[ -n "$TTY_IN" ]]; then
                if ! read -r -p "Choose a username to create: " input <"$TTY_IN"; then
                    print_error "Unable to read username (no interactive input)."
                    print_info "Run with OMARCHY_USER_NAME=yourname to continue non-interactively."
                    exit 1
                fi
            else
                print_error "No TTY available for interactive input."
                print_info "Run with OMARCHY_USER_NAME=yourname to continue non-interactively."
                exit 1
            fi
        fi

        if valid_username "$input"; then
            echo "$input"
            return 0
        fi
        print_warning "Invalid username. Use lowercase letters/numbers/_/- and start with a letter or _."
        unset OMARCHY_USER_NAME
    done
}

ensure_deps() {
    print_step "Updating system and installing dependencies"
    if ! pacman -Syu --noconfirm --needed sudo git base-devel; then
        print_warning "Package installation failed; continuing anyway. Some later steps may fail."
    fi
}

ensure_wheel_sudo() {
    print_step "Configuring sudo for wheel group"
    cat >/etc/sudoers.d/00-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 440 /etc/sudoers.d/00-wheel
}

ensure_user() {
    local username="$1"

    if id "$username" &>/dev/null; then
        print_info "User '$username' already exists; reusing."
    else
        print_step "Creating user '$username'"
        useradd -m -G wheel -s /bin/bash "$username"
        print_success "User created"
    fi

    local home_dir
    home_dir="$(getent passwd "$username" | cut -d: -f6)"
    if [[ -n "$home_dir" ]] && [[ -d "$home_dir" ]]; then
        local home_owner
        home_owner="$(stat -c %U "$home_dir" 2>/dev/null || true)"
        if [[ -n "$home_owner" ]] && [[ "$home_owner" != "$username" ]]; then
            print_warning "Home directory ownership is '$home_owner' (expected '$username'); fixing."
            chown -R "$username:$username" "$home_dir"
        fi
    fi

    print_step "Setting password for '$username'"
    print_info "You will be prompted to enter the password twice."
    # passwd reads from the controlling terminal; if none exists, this will fail.
    if ! passwd "$username"; then
        print_error "Failed to set password (is this running in a real TTY?)."
        exit 1
    fi
}

install_yay() {
    local username="$1"
    print_step "Installing yay (AUR helper)"

    if command -v findmnt &>/dev/null; then
        local tmp_opts
        tmp_opts="$(findmnt -no OPTIONS /tmp 2>/dev/null || true)"
        if [[ "$tmp_opts" == *noexec* ]]; then
            print_info "/tmp is mounted with noexec; building yay under the user's cache directory."
        fi
    fi

    if su - "$username" -c "bash -lc 'set -e; build_root=\"\${XDG_CACHE_HOME:-\${HOME}/.cache}/omarchy-build\"; mkdir -p \"\$build_root\"; cd \"\$build_root\"; rm -rf yay; git clone https://aur.archlinux.org/yay.git yay; cd yay; makepkg -si --noconfirm --needed'"; then
        print_success "yay installed"
    else
        print_warning "Failed to install yay; continuing without AUR helper."
    fi
}

clone_repo_to_user() {
    local username="$1"
    local repo="${OMARCHY_REPO:-omarchy-mac/omarchy-mac}"
    local ref="${OMARCHY_REF:-main}"

    print_step "Cloning Omarchy Mac into user's home"
    su - "$username" -c "bash -lc 'set -e; mkdir -p ~/.local/share; rm -rf ~/.local/share/omarchy; git clone https://github.com/${repo}.git ~/.local/share/omarchy; cd ~/.local/share/omarchy; if [[ \"${ref}\" != \"main\" ]]; then git fetch origin \"${ref}\" && git checkout \"${ref}\"; fi'"
    print_success "Repository cloned"
}

run_installer() {
    local username="$1"
    print_step "Running Omarchy installer as $username"
    print_info "You may be prompted for the user's sudo password during installation."
    su - "$username" -c "bash -lc 'cd ~/.local/share/omarchy && OMARCHY_KEYBOARD_CONFIRMED=1 bash install.sh'"
}

main() {
    print_banner
    require_root
    prompt_keyboard

    local username
    username="$(prompt_username)"

    ensure_deps
    ensure_wheel_sudo
    ensure_user "$username"
    install_yay "$username"
    clone_repo_to_user "$username"
    run_installer "$username"

    print_success "Bootstrap complete"
    print_info "If you hit mirror issues, run: bash fix-mirrors.sh"
}

main "$@"
