# hyprland-preview-share-picker in omarchy-base.packages has no aarch64 build, so
# xdg-desktop-portal-hyprland shows no source chooser and browser sharing silently
# degrades to tab-only. The -git package builds on aarch64, and only as the user.
if omarchy-hw-aarch64 && omarchy-cmd-missing hyprland-preview-share-picker; then
  echo "Installing the browser screen-share picker for Apple Silicon."

  omarchy-pkg-aur-add hyprland-preview-share-picker-git ||
    echo "Warning: hyprland-preview-share-picker-git failed to build; browser screen sharing stays tab-only." >&2
fi
