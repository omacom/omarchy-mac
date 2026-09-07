# Touch Bar

First-party service for Apple Silicon Macs that ship a Touch Bar. `tiny-dfr` owns the DSI strip; this plugin does not draw pixels.

Hardware setup installs `default/tiny-dfr/config.toml` to `/etc/tiny-dfr/config.toml`. The default media layer (no Fn) is brightness, Omarchy menu, terminal, lock, screenshot, mic, transport, and volume. Fn still shows F1–F12.

## Customize

Copy `layout.json` to `~/.config/omarchy/touchbar.json` and edit. Saving it regenerates the tiny-dfr config (sudo/pkexec once). `key` values are tiny-dfr key names (`BrightnessUp`, `F13`, `Print`, or a combo array). New keys that are not already in `default/hypr/bindings/touchbar.lua` need an `o.bind` in `~/.config/hypr/bindings.lua`.
