echo "Install omarchy-zsh for existing systems"

# Migration: Install omarchy-zsh for existing systems
# This migration sets up zsh with Omarchy customizations for users who already have Omarchy installed

set -euo pipefail

STATE_DIR="$HOME/.local/state/omarchy/migrations"
STATE_FILE="$STATE_DIR/1770001483.sh"

# Check if zsh is installed
if ! command -v zsh &> /dev/null; then
    echo "zsh is not installed. Skipping omarchy-zsh setup."
    echo "You can install zsh later with: yay -S zsh"
    echo "Then run: omarchy-setup-zsh"
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    exit 0
fi

echo "Installing omarchy-zsh configuration for existing system..."

# Check if .zshrc already has omarchy-zsh configured
if [ -f "$HOME/.zshrc" ] && grep -q "omarchy/default/zsh" "$HOME/.zshrc" 2>/dev/null; then
    echo "omarchy-zsh already configured in .zshrc"
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    exit 0
fi

ZSHRC="${HOME}/.zshrc"
BASHRC="${HOME}/.bashrc"
ZSHRC_DEFAULT="${HOME}/.local/share/omarchy/default/zshrc"
BASHRC_DEFAULT="${HOME}/.local/share/omarchy/default/bashrc"

# Setup .zshrc
if [ -f "${ZSHRC}" ]; then
    # Backup existing .zshrc
    ZSHRC_BACKUP="${HOME}/.zshrc.backup-$(date +%Y%m%d-%H%M%S)"
    cp "${ZSHRC}" "${ZSHRC_BACKUP}"
    echo "✓ Backed up existing .zshrc to: ${ZSHRC_BACKUP}"
    
    # Check if it's a basic zsh config (from zsh-newuser-install)
    if grep -q "zsh-newuser-install" "${ZSHRC}" 2>/dev/null; then
        # Replace with Omarchy default
        cp "${ZSHRC_DEFAULT}" "${ZSHRC}"
        echo "✓ Replaced basic .zshrc with Omarchy zsh configuration"
    else
        # Append omarchy-zsh to existing custom config
        cat >> "${ZSHRC}" << 'ZSHEOF'

# ============================================
# Omarchy-zsh configuration
# ============================================

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Load omarchy-zsh configuration
if [[ -d ~/.local/share/omarchy/default/zsh/conf.d ]]; then
  for config in ~/.local/share/omarchy/default/zsh/conf.d/*.zsh; do
    [[ -f "$config" ]] && source "$config"
  done
fi

# Load omarchy-zsh functions and aliases
if [[ -d ~/.local/share/omarchy/default/zsh/functions ]]; then
  for func in ~/.local/share/omarchy/default/zsh/functions/*.zsh; do
    [[ -f "$func" ]] && source "$func"
  done
fi

# ============================================
# Add your own customizations below
# ============================================
ZSHEOF
        echo "✓ Added Omarchy zsh configuration to existing .zshrc"
    fi
else
    # No existing .zshrc, create from template
    cp "${ZSHRC_DEFAULT}" "${ZSHRC}"
    echo "✓ Created .zshrc with Omarchy zsh configuration"
fi

# Configure bash to auto-launch zsh (optional, non-intrusive)
if [ -f "${BASHRC}" ] && ! grep -q "Auto-launch zsh shell" "${BASHRC}" 2>/dev/null; then
    # Backup existing bashrc
    BASHRC_BACKUP="${HOME}/.bashrc.backup-$(date +%Y%m%d-%H%M%S)"
    cp "${BASHRC}" "${BASHRC_BACKUP}"
    
    # Read existing content
    EXISTING_BASHRC=$(cat "${BASHRC}")
    
    # Create new bashrc with auto-launch
    cat > "${BASHRC}" << 'BASHEOF'
# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# Auto-launch zsh shell if in interactive bash
if command -v zsh &> /dev/null; then
  if [[ $(ps --no-header --pid=$PPID --format=comm) != "zsh" && -z ${BASH_EXECUTION_STRING} && ${SHLVL} == 1 ]]
  then
    shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=''
    exec zsh $LOGIN_OPTION
  fi
fi

BASHEOF

    # Append the rest of the existing content (skip interactive check line)
    echo "$EXISTING_BASHRC" | sed '/^\[.*!= \*i\*.*return$/d' >> "${BASHRC}"
    
    echo "✓ Configured bash to auto-launch zsh"
    echo "  (backed up to: ${BASHRC_BACKUP})"
fi

echo ""
echo "✓ omarchy-zsh migration complete!"
echo ""
echo "Available keybindings:"
echo "  Ctrl+Alt+F  - Search files/directories"
echo "  Ctrl+Alt+L  - Search Git Log"
echo "  Ctrl+R      - Search command history"
echo "  Ctrl+T      - Search files in current directory"
echo "  Ctrl+V      - Search Variables"
echo "  Alt+C       - cd into selected directory"
echo ""
echo "Restart your terminal or run 'exec zsh' to start using zsh"

# Mark migration as complete
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
