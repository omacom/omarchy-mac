-- Make the built-in top row match the legends on the M1 MacBook Air.

o.bind("XF86LaunchA", "Apps menu (F3)", "omarchy-menu toggle apps")
o.bind("XF86LaunchB", "Omarchy search (F4)", "omarchy-menu toggle root")
o.bind("XF86Search", "Omarchy search (F4)", "omarchy-menu toggle root")

-- Linux exposes F5/F6 on this model as keyboard-backlight keys. Keyboard
-- brightness remains available through the default Shift+F1/F2 bindings.
hl.unbind("XF86KbdBrightnessDown")
hl.unbind("XF86KbdBrightnessUp")

if o.cmd_present("voxtype") then
  o.bind("XF86KbdBrightnessDown", "Toggle dictation (F5)", "voxtype record toggle")
end
o.bind_toggle("XF86KbdBrightnessUp", "Toggle Do Not Disturb (F6)", "notification-silencing", { locked = true })

-- The built-in keyboard has no Print Screen key. Apple F10-F12 capture
-- bindings are provided by media.lua and remain available.
hl.unbind("PRINT")
hl.unbind("ALT + PRINT")
hl.unbind("SUPER + PRINT")
hl.unbind("SUPER + CTRL + PRINT")
