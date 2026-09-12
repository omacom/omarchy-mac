-- Touch Bar (tiny-dfr) keys that are not already in media.lua / utilities.lua.
-- Harmless on machines with no Touch Bar: those keycodes simply never fire.
--
-- tiny-dfr emits KEY_F13/KEY_F14. The default us keymap has no F13/F14
-- keysyms, so Hyprland never matches o.bind("F13"). Bind the X11 keycodes
-- (evdev + 8) instead.
o.bind("XF86Search", "Omarchy menu", "omarchy-menu toggle")
o.bind("code:191", "Terminal", "omarchy-launch-terminal")
o.bind("code:192", "Lock", "omarchy-system-lock")
