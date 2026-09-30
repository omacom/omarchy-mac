-- omarchy-mac: Apple Silicon Hyprland settings. Omarchy loads this directory
-- (hypr/settings under /usr/share/omarchy-platform) after its own defaults and
-- before the theme and the user's files, so these replace Omarchy's and the
-- user's input.lua can still replace them.

if not (o and o.shell_succeeds and o.shell_succeeds("omarchy-hw-apple-silicon")) then
  return
end

-- The built-in trackpad clicks physically; Asahi's disable-while-typing does
-- not stop stray taps, so tap-to-click stays off. It is set with hl.config, as
-- anything a user may set globally is: Hyprland lets an hl.device value beat
-- the global one whatever the order, so a per-device default would keep the
-- user's own global tap_to_click = true from working. An external touchpad on
-- a Mac starts with tapping off too.
hl.config({ input = { touchpad = { tap_to_click = false } } })

-- A workspace swipe steps by number, so it reaches empty workspaces as Spaces
-- do in macOS. Hyprland's default steps only through workspaces that exist and
-- never out of an empty one into a new one. The user's input.lua turns it off
-- with hl.config({ gestures = { workspace_swipe_use_r = false } }).
hl.config({ gestures = { workspace_swipe_use_r = true } })
