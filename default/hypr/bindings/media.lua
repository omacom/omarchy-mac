-- Volume, brightness, keyboard backlight, and touchpad controls.
o.bind("XF86AudioRaiseVolume", "Volume up", "omarchy-audio-output-volume raise", { locked = true, repeating = true })
o.bind("XF86AudioLowerVolume", "Volume down", "omarchy-audio-output-volume lower", { locked = true, repeating = true })
o.bind("XF86AudioMute", "Mute", "omarchy-audio-output-volume mute-toggle", { locked = true })
o.bind("XF86AudioMicMute", "Mute microphone", "omarchy-audio-input-mute", { locked = true })
o.bind("XF86MonBrightnessUp", "Brightness up", "omarchy-brightness-display +5%", { locked = true, repeating = true })
o.bind("XF86MonBrightnessDown", "Brightness down", "omarchy-brightness-display 5%-", { locked = true, repeating = true })
-- Mac fork: SHIFT+brightness drives the keyboard backlight (F1/F2 Mac layout).
-- Modern Apple Silicon MacBooks have no dedicated XF86KbdBrightness key, so
-- SHIFT+F1/F2 is the only accessible control; replaces upstream's max/min.
o.bind("SHIFT + XF86MonBrightnessUp", "Keyboard brightness up", "omarchy-brightness-keyboard up", { locked = true, repeating = true })
o.bind("SHIFT + XF86MonBrightnessDown", "Keyboard brightness down", "omarchy-brightness-keyboard down", { locked = true, repeating = true })
o.bind("XF86KbdBrightnessUp", "Keyboard brightness up", "omarchy-brightness-keyboard up", { locked = true, repeating = true })
o.bind("XF86KbdBrightnessDown", "Keyboard brightness down", "omarchy-brightness-keyboard down", { locked = true, repeating = true })
o.bind("XF86KbdLightOnOff", "Keyboard backlight cycle", "omarchy-brightness-keyboard cycle", { locked = true })
o.bind_toggle("XF86TouchpadToggle", "Toggle touchpad", "touchpad", { locked = true })
o.bind("XF86TouchpadOn", "Enable touchpad", "omarchy-toggle-touchpad on", { locked = true })
o.bind("XF86TouchpadOff", "Disable touchpad", "omarchy-toggle-touchpad off", { locked = true })

-- Precise volume and brightness controls.
o.bind("ALT + XF86AudioRaiseVolume", "Volume up precise", "omarchy-audio-output-volume +1", { locked = true, repeating = true })
o.bind("ALT + XF86AudioLowerVolume", "Volume down precise", "omarchy-audio-output-volume -1", { locked = true, repeating = true })
o.bind("ALT + XF86MonBrightnessUp", "Brightness up precise", "omarchy-brightness-display +1%", { locked = true, repeating = true })
o.bind("ALT + XF86MonBrightnessDown", "Brightness down precise", "omarchy-brightness-display 1%-", { locked = true, repeating = true })

-- Media controls.
o.bind("XF86AudioNext", "Next track", "omarchy-shell media next", { locked = true })
o.bind("ALT + XF86AudioPlay", "Next track", "omarchy-shell media next", { locked = true })
o.bind("XF86AudioPause", "Pause", "omarchy-shell media playPause", { locked = true })
o.bind("XF86AudioPlay", "Play", "omarchy-shell media playPause", { locked = true })
o.bind("XF86AudioPrev", "Previous track", "omarchy-shell media previous", { locked = true })
o.bind("ALT + SHIFT + XF86AudioPlay", "Previous track", "omarchy-shell media previous", { locked = true })
o.bind("XF86Eject", "Eject media", "eject", { locked = true })

o.bind("SHIFT + XF86AudioMute", "Switch audio output", "omarchy-audio-output-switch", { locked = true })
o.bind("SHIFT + XF86AudioPause", "Switch media source", "omarchy-audio-source-switch", { locked = true })
o.bind("SHIFT + XF86AudioPlay", "Switch media source", "omarchy-audio-source-switch", { locked = true })

-- Mac fork: screenshot binds on F-keys — Mac keyboards have no PRINT key, so
-- quattro's PRINT-based screenshot binds are dead keys on this hardware.
o.bind("SUPER + F12", "Screenshot Display", "omarchy-capture-screenshot fullscreen")
o.bind("SUPER + F11", "Screenshot Region", "omarchy-capture-screenshot region")
o.bind("SUPER + F10", "Screenshot Window", "omarchy-capture-screenshot windows")

-- Screen recording: SUPER+ALT+F12 mirrors the Display screenshot key. Starts a
-- fullscreen recording and toggles off on the next press (no options menu).
o.bind("SUPER + ALT + F12", "OmaRecord Display", "omarchy-capture-screenrecording --fullscreen")

-- Apple keyboards emit media keys on the top row, so the F-key captures above
-- need Fn held. Bind the media keycodes too and the same presses work bare.
o.bind("SUPER + XF86AudioMute", "Screenshot Window (Apple top row)", "omarchy-capture-screenshot windows")
o.bind("SUPER + XF86AudioLowerVolume", "Screenshot Region (Apple top row)", "omarchy-capture-screenshot region")
o.bind("SUPER + XF86AudioRaiseVolume", "Screenshot Display (Apple top row)", "omarchy-capture-screenshot fullscreen")
o.bind("SUPER + ALT + XF86AudioRaiseVolume", "OmaRecord Display (Apple top row)", "omarchy-capture-screenrecording --fullscreen")
