#!/bin/bash

# =============================================================================
# Omarchy Mac Bootstrap Setup Script
# =============================================================================
# This script downloads the omarchy-mac repository to the correct location
# and guides the user to run the actual bootstrap script locally.
#
# Usage (as root after first boot):
#   curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bootstrap.sh | bash
#   OR
#   wget -qO- https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bootstrap.sh | bash
# =============================================================================

set -e

echo "Omarchy Mac is no longer maintained and can't start new installs." >&2
echo "Install the official Omarchy for Apple Silicon: brew install omacom/mac/omarchy" >&2
echo "Mac manual: https://omarchy.org/manual/mac-support/" >&2
exit 1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ASCII Art Banner
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

print_step() {
    echo -e "\n${BLUE}${BOLD}==>${NC}${BOLD} $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root for initial setup."
        print_info "Please log in as root and run this script again."
        exit 1
    fi
}

# Clone repository and setup
clone_repository() {
    local repo_url="https://github.com/omarchy-mac/omarchy-mac.git"
    local target_dir="/root/.local/share/omarchy"
    
    print_step "Downloading Omarchy Mac repository..."
    
    # Install git if not available
    if ! command -v git &>/dev/null; then
        print_info "Installing git..."
        pacman -Sy --noconfirm git
    fi
    
    # Create target directory
    mkdir -p "$(dirname "$target_dir")"
    
    # Remove existing directory if it exists
    if [[ -d "$target_dir" ]]; then
        rm -rf "$target_dir"
    fi
    
    # Clone the repository
    git clone "$repo_url" "$target_dir"
    print_success "Repository cloned to $target_dir"
    
    echo ""
    print_step "Next Steps:"
    echo ""
    print_info "The Omarchy Mac repository has been downloaded."
    print_info "Now run the actual bootstrap script:"
    echo ""
    echo -e "  ${CYAN}cd ~/.local/share/omarchy${NC}"
    echo -e "  ${CYAN}bash bootstrap.sh${NC}"
    echo ""
    print_warning "Make sure you're running as root when you execute the bootstrap script."
    echo ""
}

# Main execution
main() {
    print_banner
    
    echo -e "${BOLD}Omarchy Mac Setup${NC}"
    echo -e "Downloading the repository to your system...\n"
    
    # Pre-flight checks
    check_root
    
    # Clone repository
    clone_repository
}

# Run main function
main "$@"