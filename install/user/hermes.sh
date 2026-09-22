# Shared by fresh user setup and the existing-install migration. Provisioning
# marks migrations complete, so the lazy launcher must be seeded here too.
configure_hermes_launcher() {
  local wrapper="$HOME/.local/bin/hermes"

  # Removing preinstalls opts out of the lazy wrappers, including Hermes.
  [[ -f $HOME/.local/state/omarchy/preinstalls-removed ]] && return 0

  # The app owns Hermes when installed. An unbootstrapped desktop is expected
  # for a new user, so its readiness warning must not abort user finalization.
  if omarchy-pkg-present hermes-desktop; then
    omarchy-install-hermes-cli || true
    return 0
  fi

  # Preserve user-owned executables, directories and links without running
  # them. Only the installer's ownership predicate permits replacement.
  if [[ -e $wrapper || -L $wrapper ]] && ! omarchy-install-hermes-cli --owns; then
    return 0
  fi

  omarchy-install-hermes-cli
}

configure_hermes_launcher
