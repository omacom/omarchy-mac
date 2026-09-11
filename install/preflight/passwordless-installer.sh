#!/bin/bash
# Setup passwordless sudo for installation scripts to prevent multiple password prompts
# This sudoers rule will be automatically removed after installation completes

# omarchy:heredoc-expands paths=none -- $USER is the installing account name for a temporary sudoers grant
sudo tee /etc/sudoers.d/99-omarchy-installer >/dev/null <<EOF
# Temporary sudoers rule for Omarchy installation
# This file is automatically removed after installation
Cmnd_Alias INSTALLER_CLEANUP = /bin/rm -f /etc/sudoers.d/99-omarchy-installer
$USER ALL=(ALL) NOPASSWD: ALL
EOF

# Set proper permissions for sudoers file
sudo chmod 440 /etc/sudoers.d/99-omarchy-installer
