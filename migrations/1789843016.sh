echo "Register the Widevine CDM for an installed Brave"

# The widevine package registers its CDM for Chromium and Firefox only, so a
# Brave installed through `omarchy install browser brave` never finds one and
# DRM sites (Netflix, Apple TV+, Spotify) fail to play with no useful error.
# omarchy-install-browser links it for new installs; repair existing ones here.
if [[ ! -d /opt/WidevineCdm/chromium ]]; then
  echo "Widevine CDM not installed; nothing to register."
elif [[ ! -d /opt/brave-bin ]]; then
  echo "Brave not installed; nothing to register."
elif [[ -e /opt/brave-bin/WidevineCdm ]]; then
  echo "Brave already has a Widevine CDM registered."
else
  sudo ln -sfn /opt/WidevineCdm/chromium /opt/brave-bin/WidevineCdm
  echo "Registered the Widevine CDM for Brave; restart Brave to pick it up."
fi
