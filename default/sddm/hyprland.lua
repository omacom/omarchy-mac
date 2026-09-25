-- Minimal Hyprland config for the SDDM Wayland greeter.
-- SDDM starts the greeter itself after the compositor is ready.
hl.config({
  general = {
    gaps_in = 0,
    gaps_out = 0,
    border_size = 0,
  },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})

-- SDDM creates additional windows as outputs appear. They must not steal
-- keyboard focus from the prompt that is already accepting input.
hl.window_rule({
  match = { class = "^sddm-greeter.*$" },
  no_initial_focus = true,
})

-- Choose the built-in panel when its login window is ready, or the first
-- output on desktops. Bound startup polling and leave later clicks alone.
local attempts = 0
local focusTimer
focusTimer = hl.timer(function()
  attempts = attempts + 1
  local focused = hl.get_active_window()
  if focused and focused.class:match("^sddm%-greeter") then
    focusTimer:set_enabled(false)
    return
  end
  local monitors = hl.get_monitors()
  local target = monitors[1]
  for _, monitor in ipairs(monitors) do
    if monitor.name:match("^eDP") then
      target = monitor
      break
    end
  end
  if target then
    for _, window in ipairs(hl.get_windows()) do
      if window.mapped and window.class:match("^sddm%-greeter") and
          window.monitor and window.monitor.name == target.name then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. window.address }))
        break
      end
    end
  end
  if attempts >= 80 then
    focusTimer:set_enabled(false)
  end
end, { timeout = 250, type = "repeat" })

-- A newly attached display can leave its workspace with no focused window.
-- Recheck after mapping, without moving focus away from an active prompt.
hl.on("window.open", function(window)
  if window.class:match("^sddm%-greeter") then
    attempts = 0
    focusTimer:set_enabled(true)
  end
end)
