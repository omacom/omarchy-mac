# Touch Bar mini apps

MacBook Pros with a Touch Bar (the 13-inch M1 and M2 models, and the Intel T2 models upstream Omarchy supports) run tiny-dfr on it: a daemon that draws the F-keys and media keys. Everything else about the bar is a small display with a touch digitizer, so it can also show things.

The first mini app is **Now Playing**: a live audio spectrum, the current track with album art, and previous / play-pause / next buttons, drawn straight onto the Touch Bar. Track info comes from the Omarchy shell's media service (MPRIS), so it works for the Spotify web app, cliamp, mpv, or a browser tab. The spectrum comes from `cava` listening to PipeWire. Colours follow the active theme.

## Use

- `Super + Ctrl + M` toggles it. The first press on a machine without `cava` opens a floating terminal to install it.
- Tap the spectrum or the play button to play or pause; the arrows skip tracks.
- Tap **F1-F12** at the right end of the bar, or press the hotkey again, to get the function keys back.
- With nothing playing for 45 seconds the bar dims; a touch or playback wakes it.

_Trigger > Hardware > Touch Bar: Now Playing_ in the menu does the same, and only appears on a Touch Bar Mac.

## How the handoff works

tiny-dfr owns the Touch Bar's DRM device and digitizer, both root-only. A mini app borrows them through `omarchy-touchbar-handoff`, a root helper with three verbs:

- `app` stops tiny-dfr, grants the calling user a read/write ACL on the Touch Bar's DRM node and digitizer, and makes the user the owner of the bar's backlight attribute (sysfs has no ACLs). It prints the three paths.
- `keys` removes the grants and starts tiny-dfr again.
- `devices` prints what would be handed over, without root.

`etc/sudoers.d/omarchy-touchbar` lets `wheel` run exactly the `app` and `keys` invocations without a password, following the pattern of the DNS and theme helpers: a hotkey has no terminal to carry a password prompt. The app runs `keys` on any exit, including a failed handoff, so the bar is never left dark and keyless.

## Developing a mini app

`bin/omarchy-touchbar-now-playing` is a single Python file with no dependencies beyond `pycairo`, `python-gobject`, and `cava`. It talks to the kernel directly: modesetting with one dumb buffer on the Touch Bar's CRTC, cairo drawing rotated onto the portrait panel, a dirty-fb call per frame, and evdev multitouch (protocol B) for taps. Its display and input classes are the starting point for another app.

- `omarchy-touchbar-now-playing --preview frame.png` renders a sample frame without touching hardware, for design work.
- `omarchy-touchbar-now-playing --probe` lists the devices it would use.
- Sending the running app `SIGUSR1` writes the current frame to `$XDG_RUNTIME_DIR/omarchy-touchbar-now-playing.png`.
- `OMARCHY_TOUCHBAR_DEBUG=1` logs every touch and the button it resolved to.

`tests/test-touchbar-hw.sh` covers Touch Bar detection and the helper's device discovery against fake sysfs trees.
