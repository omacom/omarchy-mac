# ARM settings leave generator configuration to the installed machine. Fresh
# users receive completed migration markers, so system setup must supply the
# missing default before user provisioning. Keep every existing local choice.
if [[ ${OMARCHY_FIRST_INSTALL:-0} == "1" && ${OMARCHY_UPGRADE:-0} != "1" && $(uname -m) == "aarch64" ]]; then
  source "$OMARCHY_INSTALL/helpers/zram.sh"
  if ! omarchy_zram_has_config; then
    if omarchy-pkg-missing zram-generator; then
      echo "zram-generator is required before configuring compressed swap; retry system setup after installing it." >&2
      return 1
    fi
    omarchy_zram_write_default
  fi
fi
