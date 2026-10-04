-- Display arrangement. Remembers where each display goes for every set of
-- connected displays, and keeps a complete monitor rule registered for every
-- known display, including the ones that are off. A display that connects
-- lands on its remembered spot in Hyprland's first pass, so nothing that is
-- already on has to move. Positions change when the user moves a display,
-- when a scale step or a rotation resizes one and its neighbours follow, or
-- when a display leaves and the others would no longer touch.
--
-- Each display also owns ten workspaces, which SUPER+1..0 reach on the
-- display that has focus.
--
-- Outside code reaches this through the omarchy_displays global, which is
-- only set while monitor rules go through here:
--   hyprctl eval "omarchy_displays.set_main('DP-1')"
--   hyprctl repl "return omarchy_displays.status()"

local paths = require("default.hypr.paths")
local model = require("default.hypr.displays.model")
local store = require("default.hypr.displays.store")

local M = {}

local LAYOUT_LIMIT = 16
local SETTLE_MS = 1500

local function toggle_on(name)
  local file = io.open(paths.state_home .. "/omarchy/toggles/hypr/" .. name .. ".lua", "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- Every writer of these toggles reloads the config, so they're read once.
-- Mirroring replaces the arrangement altogether; clamshell and the laptop
-- display toggle only matter here for keeping workspaces 1-10 the panel's.
local internal_off = toggle_on("internal-monitor-clamshell") or toggle_on("internal-monitor-disable")
local mirrored = toggle_on("internal-monitor-mirror")

-- Someone's own solution comes first: displays-off leaves displays to
-- Hyprland and the config entirely, display-workspaces-off keeps workspaces
-- global. A plugin can flip either with omarchy-hyprland-toggle.
local inactive = mirrored or toggle_on("displays-off")
local own_workspaces = not toggle_on("display-workspaces-off")

-- A rule the rest of the config registers for a display (the user's
-- monitors.lua, the clamshell and mirror toggles) is left alone: the module
-- never sends a rule for that display, which would become the newer match.
-- Rules for a display that's gone can't be told apart from the user's, so
-- the user's own go again after every batch and stay the newest.
local register_rule = hl.monitor
local claims, claimed = {}, {}

-- GTK and X11 apps scale by the whole-number GDK_SCALE, which follows main's
-- scale unless the config sets it itself.
local set_env = hl.env
local gdk_claimed = false
local gdk_scale

local function hands_off(selector, present)
  for _, claim in ipairs(claims) do
    if claim == selector or (claim:sub(1, 5) == "desc:" and selector:sub(1, #claim) == claim) then
      return true
    end
    for _, rect in pairs(present) do
      if rect.selector == selector and (rect.name == claim or ("desc:" .. rect.description):sub(1, #claim) == claim) then
        return true
      end
    end
  end
  return false
end

-- Runtime files outlive a reload (the monitor watcher reloads when a display
-- comes back), but not the session.
local runtime = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/omarchy-displays-"

local function read_runtime(name)
  local file = io.open(runtime .. name .. ".json", "r")
  local value = file and store.decode(file:read("a"))
  if file then
    file:close()
  end
  return type(value) == "table" and value or {}
end

local function write_runtime(name, value)
  local file = io.open(runtime .. name .. ".json", "w")
  if file then
    file:write(store.encode(value))
    file:close()
  end
end

local state = store.load()
model.preferred = state.main

-- The bar shows global workspaces whenever SUPER+1..0 are global.
if inactive or not own_workspaces then
  state.global_workspaces = true
  store.save(state)
end

local targets = {} -- connector -> where we put that display, while it's on
local registered = {} -- selector -> the rule last registered for it
local settling = false -- our rules are registered but maybe not applied yet
local generation = 0
local pointer_to -- where the pointer goes once our rules have landed
local pinned = {} -- identities whose workspace rules are registered
local choosing = 0
local switched_off = read_runtime("off") -- selector -> connector, switched off in the panel

-- Every display Hyprland lists, keyed by identity, including one that has no
-- mode yet while it comes back on. HL.Monitor objects must not outlive the
-- event that produced them, so only plain copies are kept.
local function listed()
  local monitors = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if monitor.name and not model.is_virtual(monitor.name) and not monitor.is_mirror then
      monitors[#monitors + 1] = {
        name = monitor.name,
        description = monitor.description or "",
        serial = monitor.serial or "",
        width = monitor.width or 0,
        height = monitor.height or 0,
        x = monitor.x,
        y = monitor.y,
        scale = model.snap_scale(monitor.scale or 0),
        transform = monitor.transform or 0,
        physical = monitor.physical_width,
        workspace = monitor.active_workspace and monitor.active_workspace.id,
        empty = monitor.active_workspace and monitor.active_workspace.windows == 0,
      }
    end
  end

  local result = {}
  for _, m in ipairs(model.identify(monitors)) do
    result[m.key] = m
  end

  -- An external that reports no EDID (the kernel can lose it when a display
  -- comes back on) is taken for the known display last seen on that
  -- connector, if that one isn't connected otherwise. Its rules go by
  -- connector for the time being.
  for _, m in ipairs(monitors) do
    if m.description == "" and not model.is_internal(m.name) then
      for known, display in pairs(state.displays) do
        if display.connector == m.name and not result[known] then
          result[m.key], m.key, m.borrowed = nil, known, true
          result[known] = m
          break
        end
      end
    end
  end
  return result
end

-- The displays that are on and have a mode.
local function read_live()
  local live = {}
  for key, m in pairs(listed()) do
    if m.width > 0 and m.scale > 0 then
      m.w, m.h = model.logical_size(m.width, m.height, m.scale, m.transform)
      live[key] = m
    end
  end
  return live
end

local function current()
  local present = {}
  for _, rect in pairs(targets) do
    present[rect.key] = rect
  end
  return present
end

-- The key of the display in layout that holds point p.
local function under(layout, p)
  for key, r in pairs(layout) do
    if p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h then
      return key
    end
  end
end

local NEUTRAL = { position = "auto", scale = "auto", transform = 0 }

local function same(a, b)
  return b and a.position == b.position and a.scale == b.scale and a.transform == b.transform and a.disabled == b.disabled
end

-- Register what changed as one synchronous batch, which Hyprland applies in a
-- single pass with one overlap check. Every field is given, because a rule
-- inherits whatever it omits from the previous rule for the same output.
local function register(present)
  local wanted, order = {}, {}
  for _, rule in ipairs(model.plan(present, state.displays, state.layouts)) do
    if not hands_off(rule.selector, present) then
      wanted[rule.selector] = { position = string.format("%dx%d", rule.x, rule.y), scale = rule.scale, transform = rule.transform }
      order[#order + 1] = rule.selector
    end
  end

  -- A display switched off in the panel stays off; one selected by
  -- connector has no rule of its own while off, so it keeps its last one.
  for selector in pairs(switched_off) do
    if not hands_off(selector, present) then
      if not wanted[selector] then
        local last = registered[selector] or NEUTRAL
        wanted[selector] = { position = last.position, scale = last.scale, transform = last.transform }
        order[#order + 1] = selector
      end
      wanted[selector].disabled = true
    end
  end

  -- A connector rule outlives its display until the next reload; reset it so
  -- it can't catch the next monitor on that port.
  local batch = {}
  for selector in pairs(registered) do
    if not wanted[selector] and not model.safe_when_absent(selector) and not hands_off(selector, present) then
      batch[#batch + 1] = selector
      wanted[selector] = NEUTRAL
    end
  end
  table.sort(batch)

  -- A reset connector rule is now newer than every desc: rule, and would win
  -- over them for a display that comes back on that port: send them again.
  -- plan() orders desc: rules first. Whenever anything is sent, the external
  -- connector rules go again last, so they stay newer than any desc: rule
  -- that also matches a display sharing its description.
  local reset = #batch > 0
  for _, selector in ipairs(order) do
    if (reset and selector:sub(1, 5) == "desc:") or not same(wanted[selector], registered[selector]) then
      batch[#batch + 1] = selector
    end
  end
  if #batch > 0 then
    for _, selector in ipairs(order) do
      if not model.safe_when_absent(selector) and same(wanted[selector], registered[selector]) then
        batch[#batch + 1] = selector
      end
    end
  end

  for _, selector in ipairs(batch) do
    local rule = wanted[selector]
    register_rule({
      output = selector,
      mode = "preferred",
      position = rule.position,
      scale = rule.scale,
      transform = rule.transform,
      disabled = rule.disabled or false,
      mirror = "",
    })
    registered[selector] = rule ~= NEUTRAL and rule or nil
  end
  if #batch > 0 then
    for _, rule in ipairs(claimed) do
      register_rule(rule)
    end
  end
  return #batch > 0
end

-- Each display owns ten workspace ids: the internal panel 1-10, the next
-- display seen 11-20, and so on. On a machine without an internal panel the
-- first display gets 1-10. has_panel says whether this one has one.
local function free_block(key, has_panel)
  local taken = {}
  for _, display in pairs(state.displays) do
    taken[display.block or -1] = true
  end
  local block = (model.is_internal(key) or not has_panel) and 0 or 1
  while taken[block] do
    block = block + 1
  end
  return block
end

-- Bind a display's workspaces to it, so Hyprland creates them there and
-- brings them home when the display reconnects on any port. They aren't
-- persistent: empty ones go away, as they always have. Workspace rules can't
-- be removed at runtime, so a display selected by connector isn't pinned, and
-- neither is a model seen as twins: those rules would catch another monitor.
local function pin(key)
  local display = state.displays[key]
  if pinned[key] or not display.block or not own_workspaces or not model.safe_when_absent(display.selector) then
    return
  end
  for other in pairs(state.displays) do
    if other:sub(1, #key + 1) == key .. "@" then
      return
    end
  end
  pinned[key] = true
  for slot = 1, 10 do
    hl.workspace_rule({ workspace = tostring(display.block * 10 + slot), monitor = display.selector, default = slot == 1 })
  end
end

-- Windows of a display that's gone come over to main's active workspace,
-- and go home when the display is back unless they were moved meanwhile.
-- What was moved is kept in a runtime file, so a reload in between doesn't
-- lose it.

local function rehome(present)
  local main = model.main(present)
  if not main then
    return
  end

  local home, main_workspace = {}, nil
  for key, m in pairs(listed()) do
    local display = state.displays[key]
    if display and display.block then
      home[display.block] = m.name
    end
    if key == main then
      main_workspace = m.workspace
    end
  end

  local returns = read_runtime("returns")

  local seen, changed, back_home = {}, false, {}
  for _, window in ipairs(hl.get_windows() or {}) do
    local address, id = window.address, window.workspace and window.workspace.id
    local back = address and returns[address]
    if address and id and id > 0 then
      seen[address] = true
      local target
      if not home[(id - 1) // 10] and main_workspace and id ~= main_workspace then
        returns[address] = { home = back and back.home or id, put = main_workspace }
        target = main_workspace
      elseif back and id == back.put and home[(back.home - 1) // 10] then
        returns[address] = nil
        target = back.home
        back_home[target] = true
      elseif back and id ~= back.put then
        returns[address] = nil
      end
      changed = changed or returns[address] ~= back
      if target then
        hl.dispatch(hl.dsp.window.move({ window = "address:" .. address, workspace = tostring(target), follow = false }))
      end
    end
  end

  -- A display without pinned workspaces (selected by connector, or back
  -- without its EDID) gets them onto itself.
  for id in pairs(back_home) do
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = home[(id - 1) // 10] }))
  end

  for address in pairs(returns) do
    if not seen[address] then
      returns[address], changed = nil, true
    end
  end
  if changed then
    write_runtime("returns", returns)
  end
end

local check

local function settle()
  settling = true
  generation = generation + 1
  local mine = generation
  hl.timer(function()
    if mine == generation then
      settling = false
      pointer_to = nil
      check()
    end
  end, { timeout = SETTLE_MS, type = "oneshot" })
end

-- Hyprland keeps the pointer where it was in the layout, so on a display the
-- module moves or resizes it would end up elsewhere on the screen, or in a
-- gap and pushed off it. It goes back to the same spot of its display once
-- the new rules have landed.
local function follow_pointer(present)
  pointer_to = nil
  local cursor = hl.get_cursor_pos()
  local old = current()
  local key = cursor and under(old, cursor)
  local was, now = key and old[key], key and present[key]
  if now and (now.x ~= was.x or now.y ~= was.y or now.w ~= was.w or now.h ~= was.h) then
    pointer_to = {
      x = math.floor(now.x + (cursor.x - was.x) * now.w / was.w + 0.5),
      y = math.floor(now.y + (cursor.y - was.y) * now.h / was.h + 0.5),
    }
  end
end

-- Make present the arrangement: mend it into one piece, remember it for this
-- set if the user made it or none is remembered yet, and register the rules
-- for it and for every display that's off.
local function commit(present, made_by_user)
  present = model.connect(present, state.layouts)
  follow_pointer(present)
  targets = {}

  -- Block 0 stays the panel's, even while clamshell keeps it off.
  local has_panel = internal_off
  for key in pairs(state.displays) do
    has_panel = has_panel or model.is_internal(key)
  end
  for key in pairs(present) do
    has_panel = has_panel or model.is_internal(key)
  end

  local connectors = {}
  for key, rect in pairs(present) do
    targets[rect.name] = rect
    local display = state.displays[key] or {}
    -- Without its EDID a display runs a fallback mode, which isn't its own.
    if not rect.borrowed then
      display.selector, display.size, display.scale, display.transform = rect.selector, { rect.width, rect.height }, rect.scale, rect.transform
    end
    for other, known in pairs(state.displays) do
      if other ~= key and known.connector == rect.name then
        known.connector = nil
      end
    end
    display.connector = rect.name
    local first = own_workspaces and not display.block
    if own_workspaces then
      display.block = display.block or free_block(key, has_panel)
      connectors[rect.name] = display.block
    end
    state.displays[key] = display
    pin(key)

    -- Hyprland gave a display seen for the first time the first free id,
    -- from another display's block; if it's still empty it becomes this
    -- display's first slot, without taking focus anywhere.
    local own = first and display.block * 10 + 1
    if own and rect.workspace and rect.empty and rect.workspace > 0 and (rect.workspace - 1) // 10 ~= display.block then
      hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(rect.workspace), id = own }))
    end
  end

  -- The bar reads these: which block each connected display shows, or that
  -- workspaces are global.
  state.global_workspaces = not own_workspaces or nil
  state.connectors = own_workspaces and connectors or nil
  if next(present) and (made_by_user or not model.restore(present, model.main(present), state.layouts)) then
    state.layouts = model.remember(state.layouts, present, LAYOUT_LIMIT)
  end
  store.save(state)

  if register(present) then
    settle()
  else
    pointer_to = nil
  end

  local main = model.main(present)
  local gdk = main and math.max(1, math.floor(present[main].scale + 0.5))
  if gdk and gdk ~= gdk_scale and not gdk_claimed then
    gdk_scale = gdk
    set_env("GDK_SCALE", tostring(gdk))
  end
  if own_workspaces then
    rehome(present)
  end
end

-- The display that stays where it is while others change size: one whose
-- size stays, the one under the pointer first, then main. So only the
-- displays that change move, and those are modeset anyway; the others
-- neither flicker nor have the pointer's spot slide away. With every size
-- changing, the one under the pointer stays, else main.
local function anchor_for(old, sizes)
  local function kept(key)
    return key ~= nil and old[key].w == sizes[key].w and old[key].h == sizes[key].h
  end
  local cursor = hl.get_cursor_pos()
  local pointed = cursor and under(old, cursor)
  local main = model.main(old)
  if kept(pointed) then
    return pointed
  elseif kept(main) then
    return main
  end
  local keys = {}
  for key in pairs(old) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if kept(key) then
      return key
    end
  end
  return pointed or main
end

-- The displays that are on after some change size, from where we put them:
-- the anchor stays and the others follow.
local function reflowed(live, sizes)
  local old = {}
  for key, m in pairs(live) do
    old[key] = targets[m.name] or m
  end
  local new = model.reflow(old, sizes, state.layouts, anchor_for(old, sizes))
  local present = {}
  for key, m in pairs(live) do
    present[key] = model.moved(m, new[key].x, new[key].y)
  end
  return present
end

-- A display comes back at its remembered rotation. Linked, its scale shows
-- things the same real size as main; per display, one seen before keeps its
-- own. Without EDID sizes it keeps its last scale.
local function remembered(m, main)
  local display = state.displays[m.key]
  local own = state.scale_mode == "each" and display and display.scale
  local derived = not own and main and model.derived_scale(m, main)
  local scale = own or derived or (display and display.scale)
  local transform = display and display.transform or m.transform
  if not scale or (scale == m.scale and transform == m.transform) then
    return m
  end
  local rect = model.moved(m, m.x, m.y)
  rect.scale, rect.transform = scale, transform
  rect.w, rect.h = model.logical_size(m.width, m.height, scale, transform)
  return rect
end

-- Seat the displays that are on after one connects or leaves, or after a
-- reload. The ones already placed stay where they are; with none placed yet,
-- main stays where it is. One that just connected goes where its remembered
-- layout, or the default, puts it: the spot its registered rule already gave
-- it. A set the user arranged comes back as arranged, around that anchor.
local function sync(live)
  -- Nothing on (the lid closed and the last display unplugged).
  if not next(live) then
    targets = {}
    return
  end

  local present, fresh = {}, {}
  for key, m in pairs(live) do
    local target = targets[m.name]
    if target then
      present[key] = model.moved(m, target.x, target.y)
    else
      fresh[#fresh + 1] = key
    end
  end

  local anchor = model.main(present)
  if not anchor then
    anchor = model.main(live)
    present[anchor] = remembered(live[anchor])
  end

  table.sort(fresh)
  for _, key in ipairs(fresh) do
    if not present[key] then
      local m = remembered(live[key], present[anchor])
      present[key] = model.moved(m, model.place_joining(present, key, m.w, m.h, state.layouts))
    end
  end

  commit(model.restore(present, anchor, state.layouts) or present, false)
end

-- Runs on every layout change, which Hyprland also sends after a display
-- connects or leaves. Once our own rules have landed, a difference between
-- the screen and what we placed was made by someone else and is adopted: a
-- new size keeps our positions and lets the neighbours follow; a move becomes
-- the layout for this set.
function check()
  local live = read_live()
  local unseen = 0
  for _ in pairs(targets) do
    unseen = unseen + 1
  end
  for _, m in pairs(live) do
    if not targets[m.name] then
      return sync(live)
    end
    unseen = unseen - 1
  end
  if unseen ~= 0 then
    return sync(live)
  end

  local sizes, resized, moved = {}, false, false
  for key, m in pairs(live) do
    local target = targets[m.name]
    sizes[key] = { w = m.w, h = m.h }
    if m.w ~= target.w or m.h ~= target.h or m.scale ~= target.scale or m.transform ~= target.transform then
      resized = true
    elseif m.x ~= target.x or m.y ~= target.y then
      moved = true
    end
  end

  if settling then
    settling = resized or moved
    if not settling and pointer_to then
      hl.dispatch(hl.dsp.cursor.move(pointer_to))
      pointer_to = nil
    end
    return
  end

  -- Whoever changed it may have replaced our rule for that output too.
  if resized then
    registered = {}
    commit(reflowed(live, sizes), true)
  elseif moved then
    registered = {}
    commit(live, true)
  end
end

-- Apply new scales and rotations (key -> scale, key -> transform) to
-- displays that are on. Each keeps its place and the neighbours follow the
-- new sizes.
local function resize(live, scales, transforms)
  local sizes = {}
  for key, m in pairs(live) do
    sizes[key] = {}
    sizes[key].w, sizes[key].h = model.logical_size(m.width, m.height, scales[key] or m.scale, transforms[key] or m.transform)
  end
  local present = reflowed(live, sizes)
  for key, rect in pairs(present) do
    rect.scale, rect.transform = scales[key] or rect.scale, transforms[key] or rect.transform
    rect.w, rect.h = sizes[key].w, sizes[key].h
  end
  commit(present, true)
end

-- Linked, the scales when display `key` is set to the clean `scale`: every
-- other display shows things the same real size as it does. Each is matched
-- to that display directly, so it doesn't matter which display is set; one
-- without EDID sizes keeps its own.
local function linked_for(live, key, scale)
  local reference = model.moved(live[key], live[key].x, live[key].y)
  reference.scale = scale
  local scales = { [key] = scale }
  for other, d in pairs(live) do
    if other ~= key then
      scales[other] = model.derived_scale(d, reference)
    end
  end
  return scales
end

-- Give the display on connector `name` a new scale, snapped to a clean one.
-- Linked, every other display follows it to the same real size; per display,
-- only that display changes. Used by SUPER+/ and by the Monitor panel.
function M.set_scale(name, scale)
  if inactive or type(scale) ~= "number" or scale < 0.25 then
    return
  end

  local live = read_live()
  for key, m in pairs(live) do
    if m.name == name then
      local chosen = model.clean_scale(scale, m.width, m.height)
      resize(live, state.scale_mode == "each" and { [key] = chosen } or linked_for(live, key, chosen), {})
      return
    end
  end
end

-- SUPER+CTRL+/, and choosing Linked: every display back to the scale that
-- shows things the same real size as main.
function M.match_all()
  if inactive then
    return
  end
  local live = read_live()
  local main = model.main(live)
  if main then
    resize(live, linked_for(live, main, live[main].scale), {})
  end
end

-- For the Monitor panel: Linked, the scale each display that's on would get
-- for each preset of each display, as JSON { connector = { preset =
-- { connector = scale } } }. Per display, where nothing else changes, "{}".
function M.linked_preview()
  local preview = {}
  local live = read_live()
  if state.scale_mode ~= "each" then
    for key, m in pairs(live) do
      local presets = {}
      for _, preset in ipairs(model.SCALE_STEPS) do
        local scales = {}
        for other, scale in pairs(linked_for(live, key, model.clean_scale(preset, m.width, m.height))) do
          scales[live[other].name] = scale
        end
        presets[string.format("%g", preset)] = scales
      end
      preview[m.name] = presets
    end
  end
  return store.encode(preview)
end

-- Linked ("linked") or Per display ("each"), for the Monitor panel. The choice
-- is kept until it's changed again; choosing Linked matches every display to
-- main.
function M.set_scale_mode(mode)
  if inactive then
    return
  end
  state.scale_mode = mode == "each" and "each" or nil
  store.save(state)
  if not state.scale_mode then
    M.match_all()
  end
end

-- SUPER+/ and SUPER+ALT+/: the next clean scale up or down for the focused
-- display.
function M.step_scale(direction)
  if inactive then
    hl.exec_cmd("omarchy-hyprland-monitor-scaling " .. (direction > 0 and "up" or "down"))
    return
  end
  local active = hl.get_active_monitor()
  local name = active and active.name
  for _, m in pairs(read_live()) do
    if m.name == name then
      M.set_scale(name, model.step_scale(m.scale, direction, m.width, m.height))
      return
    end
  end
end

-- Turn the display on connector `name` to `transform`, as Hyprland counts
-- them: 0 standard, 1 90°, 2 180°, 3 270°. Like a scale change, it keeps its
-- place and the others stay where they are; the turn is remembered for that
-- display. For the Monitor panel.
function M.set_rotation(name, transform)
  transform = type(transform) == "number" and math.tointeger(transform)
  if inactive or not transform or transform < 0 or transform > 3 then
    return
  end
  local live = read_live()
  for key, m in pairs(live) do
    if m.name == name then
      resize(live, {}, { [key] = transform })
      return
    end
  end
end

-- The workspace id of slot n on the display that has focus (SUPER+1..0),
-- or, for_window, on the display the focused window is on: SUPER+SHIFT+N
-- moves the window within its own display even when the pointer has left it.
function M.slot(n, for_window)
  local window = for_window and hl.get_active_window()
  local active = window and window.monitor or hl.get_active_monitor()
  local rect = active and targets[active.name]
  local display = own_workspaces and rect and state.displays[rect.key]
  return tostring((display and display.block or 0) * 10 + n)
end

-- SUPER+D: the next digit picks the display to send the focused window to.
-- The "display" submap is left after any other key, or after 1.5 s.
function M.choose_display()
  hl.dispatch(hl.dsp.submap("display"))
  choosing = choosing + 1
  local mine = choosing
  hl.timer(function()
    if mine == choosing and hl.get_current_submap() == "display" then
      hl.dispatch(hl.dsp.submap("reset"))
    end
  end, { timeout = 1500, type = "oneshot" })
end

-- Send the focused window to D<number>, onto the workspace it shows; focus
-- goes along. With displays-off the numbers still run left to right.
function M.send_window(number)
  local on = targets
  if inactive then
    on = {}
    for _, monitor in ipairs(hl.get_monitors() or {}) do
      if monitor.name and not model.is_virtual(monitor.name) and not monitor.is_mirror then
        on[monitor.name] = { x = monitor.x, y = monitor.y }
      end
    end
  end
  local name = model.numbering(on)[number]
  hl.dispatch(hl.dsp.submap("reset"))
  if name then
    hl.dispatch(hl.dsp.window.move({ monitor = name }))
  end
end

-- Move display `name` to x, y, where the Monitor panel's arrangement
-- dropped it. Displays it leaves detached are seated again.
function M.move(name, x, y)
  local present = current()
  local rect = targets[name]
  if inactive or not rect or type(x) ~= "number" or type(y) ~= "number" then
    return false
  end
  local moved = model.moved(rect, math.floor(x), math.floor(y))
  if not model.fits(present, moved, rect.key) then
    return false
  end
  present[rect.key] = moved
  commit(present, true)
  return true
end

-- Make display `name` main: new displays go beside it, the windows of a
-- display that's gone come over to its active workspace, and the others'
-- scale follows it.
function M.set_main(name)
  local rect = targets[name]
  if inactive or not rect then
    return
  end
  state.main = rect.key
  model.preferred = rect.key
  commit(current(), false)
end

-- Switch the display on connector `name` off or back on, for the Monitor
-- panel. One switched off stays off through later rule changes this
-- session; back on, it returns to its remembered spot and scale.
function M.set_enabled(name, on)
  if inactive then
    return
  end
  if not on then
    local rect = targets[name]
    if rect then
      switched_off[rect.selector] = name
      write_runtime("off", switched_off)
      register(current())
      if not (registered[rect.selector] or {}).disabled then
        register_rule({ output = name, disabled = true })
      end
    end
    return
  end
  local back
  for selector, connector in pairs(switched_off) do
    if connector == name then
      switched_off[selector], registered[selector], back = nil, nil, selector
    end
  end
  write_runtime("off", switched_off)
  register(current())
  -- One the module has no rule for comes back where Hyprland puts it, and
  -- is seated from there.
  if not (back and registered[back]) then
    register_rule({ output = name, mode = "preferred", position = "auto", scale = "auto", disabled = false, mirror = "" })
  end
end

-- The connector of the main display, for the Monitor panel.
function M.main_name()
  local present = current()
  local main = model.main(present)
  return main and present[main].name or ""
end

-- "each" while scaling is per display, else "linked".
function M.scale_mode()
  return state.scale_mode or "linked"
end

function M.status()
  local present = current()
  local main = model.main(present)
  local lines = {}
  for index, key in ipairs(model.numbering(present)) do
    local r = present[key]
    local turned = (r.transform or 0) ~= 0 and string.format(" transform %d", r.transform) or ""
    lines[#lines + 1] = string.format("D%d %s (%s) %dx%d at %d,%d scale %g%s%s", index, key, r.name, r.w, r.h, r.x, r.y, r.scale, turned, key == main and " main" or "")
  end
  return table.concat(lines, "\n")
end

if not inactive then
  M.own_workspaces = own_workspaces
  omarchy_displays = M

  -- The three-finger swipe stops at a display's last workspace instead of
  -- creating one outside its ten, like SUPER+TAB and the wheel, and steps only
  -- through the display's own: stepping by number (the Mac's platform setting)
  -- would run into the next display's. This loads after the platform's
  -- settings and before the user's files, so a user's own setting still wins.
  if own_workspaces then
    hl.config({ gestures = { workspace_swipe_create_new = false, workspace_swipe_use_r = false } })
  end

  for key in pairs(state.displays) do
    pin(key)
  end

  local live = read_live()
  if next(live) and model.restore(live, model.main(live), state.layouts) then
    -- A reload: bring back the remembered arrangement and scales.
    sync(live)
  elseif next(live) then
    -- The first start of this module on a running desktop: adopt what's
    -- there as this set's arrangement.
    commit(live, true)
  else
    -- First start, before any output exists: assume the most recently used
    -- layout, so each display's first modeset already puts it in place.
    local assumed = {}
    local recent = state.layouts[1]
    for key, p in pairs(recent and recent.positions or {}) do
      local display = state.displays[key]
      if display and model.safe_when_absent(display.selector) then
        local w, h = model.logical_size(display.size[1], display.size[2], display.scale, display.transform)
        assumed[key] = { x = p[1], y = p[2], w = w, h = h, selector = display.selector, scale = display.scale, transform = display.transform }
      end
    end
    register(assumed)
  end

  hl.on("monitor.layout_changed", check)

  -- Collect the rules the rest of this config run registers.
  hl.monitor = function(rule)
    if type(rule) == "table" and type(rule.output) == "string" and rule.output ~= "" then
      claims[#claims + 1] = rule.output
      claimed[#claimed + 1] = rule
    end
    return register_rule(rule)
  end
  hl.env = function(name, value)
    gdk_claimed = gdk_claimed or name == "GDK_SCALE"
    return set_env(name, value)
  end
  hl.on("config.reloaded", function()
    hl.monitor = register_rule
    hl.env = set_env
  end)
end

return M
