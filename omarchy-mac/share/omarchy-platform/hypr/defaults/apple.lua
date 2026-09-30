-- omarchy-mac: Apple Silicon Hyprland defaults. Omarchy loads this directory
-- (hypr/defaults under /usr/share/omarchy-platform) before its own defaults,
-- so a chord bound here replaces Omarchy's default for it, and the user's
-- files, loaded after both, can still unbind or rebind any of it.

if not (o and o.shell_succeeds and o.shell_succeeds("omarchy-hw-apple-silicon")) then
  return
end

-- A runtime older than Omarchy's platform loader has no settings slot, so the
-- Mac's settings (settings/apple.lua) load from here instead.
if not package.loaded["default.hypr.platform"] then
  dofile(debug.getinfo(1, "S").source:match("^@(.+)/defaults/[^/]+$") .. "/settings/apple.lua")
end

if _G.omarchy_default_bindings ~= false then
  -- The lid switch is "Apple SMC power/lid events" here, so Omarchy's "Lid
  -- Switch" binds never fire.
  o.bind("switch:on:Apple SMC power/lid events", nil, "omarchy-system-lid-close", { locked = true })
  o.bind("switch:off:Apple SMC power/lid events", nil, "omarchy-hyprland-monitor-clamshell", { locked = true })

  -- No Print Screen key: SUPER+F10-F12 and the same chords on the top row's
  -- media keysyms capture without holding Fn in media-first mode.
  o.bind("SUPER + F12", "Screenshot Display", "omarchy-capture-screenshot fullscreen")
  o.bind("SUPER + F11", "Screenshot Region", "omarchy-capture-screenshot region")
  o.bind("SUPER + F10", "Screenshot Window", "omarchy-capture-screenshot windows")
  o.bind("SUPER + XF86AudioMute", "Screenshot Window (Apple top row)", "omarchy-capture-screenshot windows")
  o.bind("SUPER + XF86AudioLowerVolume", "Screenshot Region (Apple top row)", "omarchy-capture-screenshot region")
  o.bind("SUPER + XF86AudioRaiseVolume", "Screenshot Display (Apple top row)", "omarchy-capture-screenshot fullscreen")

  -- The keyboard has no backlight keys: Shift+brightness drives it, in place of
  -- Omarchy's display maximum and minimum.
  o.bind("SHIFT + XF86MonBrightnessUp", "Keyboard brightness up", "omarchy-brightness-keyboard up", { locked = true, repeating = true })
  o.bind("SHIFT + XF86MonBrightnessDown", "Keyboard brightness down", "omarchy-brightness-keyboard down", { locked = true, repeating = true })
end

-- A menu or panel pressed on the MacBook's own keyboard opens on the MacBook's
-- own screen; apps keep opening on the focused screen. Hyprland runs every bind
-- matching a key press in the order they were added, so a bind scoped to the
-- built-in keyboard (SPI on M1, MTP on M2 and later), made just before the menu
-- bind, moves focus first. Other keyboards only match the menu bind. Pickers
-- that paste into the focused window stay with that window's screen.
local builtin_keyboards = { "apple-spi-keyboard", "apple-mtp-keyboard" }
local overlay_prefixes = { "omarchy-menu", "omarchy-shell shell toggle ", "omarchy-shell -q shell togglePanelAt " }
local pastes_into_focused_window = { ["omarchy.emojis"] = true, ["omarchy.clipboard"] = true }

local function opens_overlay(command)
  if type(command) ~= "string" then
    return false
  end
  local panel = command:match("^omarchy%-shell shell toggle '?([^' ]+)'?$")
  if panel and pastes_into_focused_window[panel] then
    return false
  end
  for _, prefix in ipairs(overlay_prefixes) do
    if command:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function focus_builtin_screen()
  for _, monitor in ipairs(hl.get_monitors()) do
    if monitor.name:match("^eDP%-") then
      if not monitor.focused then
        hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
      end
      return
    end
  end
end

-- A menu or panel bound as { menu = ... } or { panel = ... } reaches the shell
-- through its global shortcut, an opaque dispatcher; Omarchy passes the command
-- it stands for fourth. Older runtimes pass only the dispatcher.
table.insert(o.bind_decorators, function(keys, dispatcher, opts, command)
  if opens_overlay(command or dispatcher) and not (opts and opts.locked) then
    hl.bind(keys, focus_builtin_screen, { device = { inclusive = true, list = builtin_keyboards } })
  end
end)
