# Real newlines, not a literal \n: the card renders the body as it arrives, and
# elides past three lines.
keybindings_shortcut=$(omarchy-keybinding-label 'Super + K')
menu_shortcut=$(omarchy-keybinding-label 'Super + Space')
omarchy-notification-send -u critical -g  "Learn Keybindings" \
  "$keybindings_shortcut for cheatsheet."$'\n'"$menu_shortcut for Omarchy Menu." \
  --exec omarchy-menu-keybindings
