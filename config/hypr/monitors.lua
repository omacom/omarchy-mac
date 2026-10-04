-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

-- Omarchy arranges and scales displays itself (default/hypr/displays.lua):
-- it remembers where each display goes, matches new ones to the main
-- display's scale, and is adjusted from the Monitor panel or with SUPER+/.
-- This catch-all only applies to a display it doesn't know yet.
local omarchy_monitor_scale = "auto"
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- A rule for a specific display takes that display over: Omarchy then leaves
-- its mode, position and scale to you. `hyprctl monitors` shows each
-- display's description, which finds it on any port.
-- hl.monitor({ output = "desc:BNQ BenQ LCD T4M01236019", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })

-- GDK scale is GDK_SCALE, the factor GTK draws its own UI at. It's what
-- sizes X11/XWayland windows, which Omarchy leaves unscaled so they stay
-- crisp instead of being stretched by the compositor. It follows the main
-- display's scale, rounded to the whole number GTK needs; set it here to
-- keep it fixed, and restart an app for a change to reach it.
-- hl.env("GDK_SCALE", "2")
