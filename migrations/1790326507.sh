echo "Link the system Widevine CDM into Brave so DRM sites play"

opt_path="${OMARCHY_OPT_PATH:-/opt}"
cdm="$opt_path/WidevineCdm/chromium"

[[ -d $cdm ]] || exit 0

for install_dir in "$opt_path/brave-bin" "$opt_path/brave-origin-bin"; do
  if [[ -d $install_dir && ! -e $install_dir/WidevineCdm ]]; then
    sudo ln -sfn "$cdm" "$install_dir/WidevineCdm"
  fi
done
