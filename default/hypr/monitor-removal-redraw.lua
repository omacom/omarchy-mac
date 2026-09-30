-- Workaround: windows from an unplugged monitor redraw at their new scale.
--
-- Hyprland 0.56.2 tells a window it has left a monitor only while that monitor
-- is still enabled (CWindow::updateSurfaceScaleTransformDetails), so the
-- windows of a monitor that's unplugged are never told they left it. Chromium
-- keeps laying such a window out at the scale of the monitor it never left,
-- drawing it in a corner when the monitor it's on now has another scale,
-- until the window next changes size. Other clients, foot among them, draw at
-- the right scale.
--
-- So once a removal has reached the clients, each window that was open then
-- gets a pixel more border when it's on a workspace that's showing, and its
-- own border back a moment later: a resize nobody sees, after which it draws
-- at the scale of the monitor it's on. A window on a workspace that's hidden
-- gets it when that workspace is shown.

local stale = {} -- address -> true, for windows open when a monitor went

local function border(addresses, value)
  for _, address in ipairs(addresses) do
    pcall(hl.dispatch, hl.dsp.window.set_prop({ window = "address:" .. address, prop = "border_size", value = value }))
  end
end

local function redraw()
  local showing = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if monitor.active_workspace then
      showing[monitor.active_workspace.id] = true
    end
  end

  local now, open = {}, {}
  for _, window in ipairs(hl.get_windows() or {}) do
    local address, workspace = window.address, window.workspace
    if address then
      open[address] = true
      if stale[address] and workspace and showing[workspace.id] then
        stale[address] = nil
        now[#now + 1] = address
      end
    end
  end
  for address in pairs(stale) do
    if not open[address] then
      stale[address] = nil
    end
  end

  if #now > 0 then
    border(now, tostring((hl.get_config("general.border_size") or 0) + 1))
    hl.timer(function()
      border(now, "unset")
    end, { timeout = 100, type = "oneshot" })
  end
end

local function redraw_soon()
  hl.timer(redraw, { timeout = 300, type = "oneshot" })
end

hl.on("monitor.removed", function()
  for _, window in ipairs(hl.get_windows() or {}) do
    if window.address then
      stale[window.address] = true
    end
  end
  redraw_soon()
end)

hl.on("workspace.active", function()
  if next(stale) then
    redraw_soon()
  end
end)
