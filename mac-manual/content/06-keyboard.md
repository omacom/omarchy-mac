---
title: Keyboard and trackpad
description: Command as Super, the top row, screenshots without a Print Screen key, the trackpad and the keyboard backlight.
section: Using it
---

On an Apple keyboard, Command is Omarchy's `Super` key, so every binding in [Hotkeys](https://omarchy.org/manual/hotkeys/) works with Command wherever it says Super.

The top row behaves as it does in macOS: press a key on its own for its media function, or hold `Fn` to send F1 to F12.

External keyboards that are not Apple keyboards but use the same driver, such as Keychron boards, keep F1 to F12 first. To put F1 to F12 first on the Mac keyboard too, write `options hid_apple fnmode=2` to `/etc/modprobe.d/hid_apple.conf` and run `sudo omarchy-mac-boot-update`: the keyboard driver loads from the boot image, so the setting takes effect once that image is rebuilt. Updates keep a setting you made.

## Screenshots and recording

Apple keyboards have no Print Screen key, so Apple Silicon Macs get these bindings in its place:

| Shortcut | Action |
| --- | --- |
| `Command + F10`, or Command with the mute key | Screenshot a window |
| `Command + F11`, or Command with the volume-down key | Screenshot a region |
| `Command + F12`, or Command with the volume-up key | Screenshot the whole display |
| `Command + Ctrl + C` | The Capture menu, including screen recording |

The screenshot bindings are bound to both forms of each key, so they work whether or not you hold `Fn`. Everything else in [Screenshots & recording](https://omarchy.org/manual/screenshots-recording/) applies as written.

## Keyboard backlight

On Macs with an ambient light sensor, the keyboard backlight follows the room: lit in the dark, off in bright light. On an Apple keyboard, `Shift` with the brightness keys sets the keyboard backlight instead of the screen. Setting it yourself takes over until the light changes enough that your choice no longer fits.

## Trackpad

The built-in trackpad scrolls naturally, as in macOS, and tap-to-click is off, because a palm brushing the trackpad while typing would otherwise click. Click by pressing the trackpad. Tapping is off for every touchpad on a Mac, an external one included. Change either in the `touchpad` section of `~/.config/hypr/input.lua`, as [Keyboard, mouse, trackpad](https://omarchy.org/manual/keyboard-mouse-trackpad/) describes; a value you set yourself is kept. To tap to click, set `tap_to_click = true` there (setup writes `tap_to_click = false` into that file on a new install), or add this line at the end of the file:

```lua
hl.config({ input = { touchpad = { tap_to_click = true } } })
```

Swipe sideways with three fingers to move between workspaces, as in macOS, including empty ones: swiping past the last workspace opens the next one. While each screen has its own workspaces, the swipe stays on the screen's workspaces in use. A three-finger sideways gesture of your own in `~/.config/hypr/input.lua` takes its place. To turn the swipe off, add this line to `~/.config/hypr/input.lua`:

```lua
omarchy_workspace_gesture = false
```

Stepping into empty workspaces is a Mac default for every workspace swipe, yours included, unless each screen has its own workspaces. To go back to Hyprland's own stepping, add this line to `~/.config/hypr/input.lua`:

```lua
hl.config({ gestures = { workspace_swipe_use_r = false } })
```
