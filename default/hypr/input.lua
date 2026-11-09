-- https://wiki.hypr.land/Configuring/Basics/Variables/#input

local function read_vconsole()
  local values = {}
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return values
  end

  for line in file:lines() do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and value then
      value = value:gsub("%s+#.*$", "")
      value = value:gsub('^"(.*)"$', "%1")
      value = value:gsub("^'(.*)'$", "%1")
      values[key] = value
    end
  end

  file:close()
  return values
end

-- Layouts that can't type Latin letters. Keep in sync with the list in
-- etc/mkinitcpio.conf.d/omarchy_hooks.conf.
local non_latin_layouts =
  " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua "

local vconsole = read_vconsole()

local kb_layout = vconsole.XKBLAYOUT or "us"
local kb_variant = vconsole.XKBVARIANT or ""
-- CapsLock is the compose key, so Caps Lock itself has to live somewhere else.
-- Both Shifts together is the usual home for it, but it's easy to hit by
-- accident while typing. The _cancel variant sets Caps Lock the same way and
-- releases it on the next lone Shift, so a misfire clears itself.
local kb_options = "compose:caps,shift:both_capslock_cancel"

-- Hyprland resolves keybindings against the first entry in kb_layout, not the
-- layout that's currently active, so Omarchy's Latin-keysym bindings (SUPER + W
-- and friends) only fire when a Latin layout leads. Installing with a non-Latin
-- one would otherwise leave the desktop unusable.
if non_latin_layouts:find(" " .. kb_layout:match("^[^,]*") .. " ", 1, true) then
  kb_layout = "us," .. kb_layout
  kb_variant = "," .. kb_variant
  -- Reach the original layout with Left Alt + Right Alt.
  kb_options = kb_options .. ",grp:alts_toggle"
end

hl.config({
  input = {
    kb_layout = kb_layout,
    kb_variant = kb_variant,
    kb_model = "",
    kb_options = kb_options,
    kb_rules = "",
    follow_mouse = 1,
    sensitivity = 0,

    repeat_rate = 40,
    repeat_delay = 250,
    numlock_by_default = true,

    touchpad = {
      -- Match macOS: natural scrolling, and physical clicks instead of taps.
      -- On the Asahi touchpad, disable_while_typing alone does not stop stray
      -- taps while typing; turning off tap_to_click does.
      natural_scroll = true,
      tap_to_click = false,
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },

  misc = {
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },
})

-- The built-in trackpad (M2 and later) follows macOS's default trackpad
-- acceleration instead of libinput's adaptive profile, which is about 2.5x
-- faster for slow, precise movements and slower for quick flicks. The points
-- follow macOS's curve at its default tracking speed (0.6875: IOHIDFamily's
-- parametric acceleration with the HIDAccelCurves macOS 27 reports for its
-- trackpads), fitted with libinput's 64 evenly spaced points (11 mm/s of
-- finger speed apart) to within 7 % of it at every speed: libinput takes the
-- input speed in device units/ms (98 units/mm) and the output speed in px/ms,
-- and at scale 2 a Hyprland px is a macOS point. That is 3.9-4.3 px/mm when
-- crawling, 12 at 150 mm/s, 21 at 300 and 31-34 for flicks.
local macos_trackpad_points = {
  0, 0.04425, 0.10053, 0.19062, 0.28687, 0.39515, 0.51815, 0.65609,
  0.80915, 0.97743, 1.161, 1.3598, 1.574, 1.8035, 2.0482, 2.3082,
  2.5833, 2.8736, 3.179, 3.4993, 3.8344, 4.1838, 4.547, 4.9234,
  5.3124, 5.7132, 6.1251, 6.5475, 6.9798, 7.4211, 7.8708, 8.3283,
  8.7928, 9.2636, 9.7401, 10.222, 10.707, 11.197, 11.689, 12.183,
  12.679, 13.176, 13.673, 14.169, 14.664, 15.157, 15.648, 16.135,
  16.618, 17.096, 17.569, 18.036, 18.495, 18.948, 19.392, 19.827,
  20.252, 20.668, 21.072, 21.464, 21.844, 22.211, 22.564, 22.903,
}

-- A custom profile also takes over scrolling: scroll_points keeps the adaptive
-- profile's scroll speed (0.9 x 0.2968 x 1000 / 25.4 / 98 px per unit).
hl.device({
  name = "apple-mtp-multi-touch",
  accel_profile = "custom 1.078 " .. table.concat(macos_trackpad_points, " "),
  scroll_points = "1 0 0.1073",
})

-- Scroll nicely in the terminal.
o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 1.5 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 0.2 })
