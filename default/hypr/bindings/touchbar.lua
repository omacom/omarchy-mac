-- Touch Bar (tiny-dfr) keys that are not already in media.lua / utilities.lua.
-- Harmless on machines with no Touch Bar: those keycodes simply never fire.
o.bind("XF86Search", "Omarchy menu", "omarchy-menu toggle")
o.bind("F13", "Terminal", "omarchy-launch-terminal")
o.bind("F14", "Lock", "omarchy-system-lock")
