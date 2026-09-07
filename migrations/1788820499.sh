echo "Map the Asahi mic array to stereo and retry speakersafetyd"

# Fresh installs run the hardware leaf and the per-user mic leaf. Reuse both
# here so existing Apple Silicon sessions get the same mapping without a
# reboot, and so a failed speakersafetyd start-limit is cleared.
audio_setup="$OMARCHY_PATH/install/hardware/apple/audio.sh"
[[ -f $audio_setup ]] && source "$audio_setup"

mic_setup="$OMARCHY_PATH/install/user/hardware/apple/mic.sh"
[[ -f $mic_setup ]] && source "$mic_setup"
