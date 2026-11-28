# omarchy-settings seeds /etc/skel/.bashrc from its install hook, but on Apple
# Silicon that hook returns early to keep Arch Linux ARM's system files, which
# also skips the bashrc. Users there get bash's stock ~/.bashrc, which never
# sources Omarchy's bash rc: no aliases (c, cx, g, ...), no functions (tdl,
# ga, ...), no prompt or tool init. Install Omarchy's bashrc, keeping a backup
# and any lines the user added on top of the stock file.
bashrc="$HOME/.bashrc"
stock_bashrc=${OMARCHY_STOCK_BASHRC:-/etc/skel/.bashrc}

if omarchy-hw-apple && ! grep -qs 'default/bash/rc' "$bashrc"; then
  echo "Installing Omarchy's ~/.bashrc so its aliases and functions load"

  carried=""
  if [[ -f $bashrc ]]; then
    cp "$bashrc" "$bashrc.backup-$(date +%Y%m%d-%H%M%S)"
    if [[ -f $stock_bashrc ]]; then
      carried=$(grep -vxFf "$stock_bashrc" "$bashrc" || true)
    else
      carried=$(<"$bashrc")
    fi
  fi

  cp "$OMARCHY_PATH/default/bashrc" "$bashrc"
  if [[ -n $carried ]]; then
    printf '\n# Kept from your previous ~/.bashrc\n%s\n' "$carried" >>"$bashrc"
  fi
fi
