# obsidian in omarchy-base.packages is a pkgbase, not a package: its PKGBUILD
# declares pkgname=(${pkgbase}-{bin,appimage}). Asking for "obsidian" installs
# the dependencies -- fuse2, for the AppImage -- builds, and then installs
# nothing, because no package by that name exists. Apple Silicon therefore ends
# up with no Obsidian and an orphaned fuse2.
#
# Of the two outputs, obsidian-bin is arch=('x86_64') while obsidian-appimage
# carries aarch64 and extracts Obsidian's own arm64 AppImage, so ask for that
# one by name. Verified on an M2 Max: obsidian-appimage-1.12.7-1-aarch64 builds
# and runs.
if omarchy-hw-aarch64 && omarchy-cmd-missing obsidian; then
  echo "Installing Obsidian for Apple Silicon (the AppImage build)."

  # The Omarchy ARM repo carries a built obsidian-appimage, so try the repos
  # first: it is a 118 MB AppImage that every machine would otherwise download
  # and repack for itself. omarchy-pkg-add skips packages the repos do not have,
  # so fall back to building when the repo is missing or unreachable.
  omarchy-pkg-add obsidian-appimage

  if omarchy-cmd-missing obsidian; then
    omarchy-pkg-aur-add obsidian-appimage ||
      echo "Warning: obsidian-appimage failed to build; install it later with 'omarchy pkg aur add obsidian-appimage'." >&2
  fi
fi
