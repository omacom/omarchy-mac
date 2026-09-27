-- Shared helpers for Hyprland Lua configuration.

o = o or {}

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

o.shell_quote = shell_quote

local function file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end

  return false
end

-- Hyprland reaps its own children, so os.execute() can't retrieve an exit status
-- from inside the compositor. Read a marker off stdout instead.
function o.shell_succeeds(command)
  -- Subshell, so the redirection covers every command rather than binding to
  -- the last one and letting an earlier one write its own OK into the pipe.
  local pipe = io.popen("( " .. command .. " ) >/dev/null 2>&1 && echo OK")
  if not pipe then
    return false
  end

  local output = pipe:read("*a") or ""
  pipe:close()

  return output:find("OK", 1, true) ~= nil
end

function o.cmd_present(command)
  if command:find("/", 1, true) then
    return file_exists(command)
  end

  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin"
  for directory in (path .. ":"):gmatch("([^:]*):") do
    if file_exists((directory ~= "" and directory or ".") .. "/" .. command) then
      return true
    end
  end

  return false
end

function o.cmd_missing(command)
  return not o.cmd_present(command)
end

local function command_from(value, description)
  if type(value) ~= "table" then
    return value
  end

  if value.omarchy then
    return "omarchy-launch-" .. value.omarchy
  elseif value.focus and value.launch then
    return o.launch_sole(value.focus, value.launch)
  elseif value.launch then
    return o.launch(value.launch)
  elseif value.webapp then
    if value.focus then
      return o.launch_webapp_sole(description, value.webapp)
    else
      return o.launch_webapp(value.webapp)
    end
  elseif value.tui then
    if value.focus then
      return "omarchy-launch-or-focus-tui " .. shell_quote(value.tui)
    else
      return "omarchy-launch-tui " .. shell_quote(value.tui)
    end
  end

  return value
end

function o.preinstalled_bindings_enabled()
  if _G.omarchy_preinstalled_bindings ~= nil then
    return _G.omarchy_preinstalled_bindings == true
  end

  return not file_exists((os.getenv("HOME") or "") .. "/.local/state/omarchy/preinstalls-removed")
end

-- A platform package's defaults load before Omarchy's (see omarchy.lua). A chord
-- they bind replaces Omarchy's own default for it, and a decorator they add runs
-- for every later bind, before it is made, so it can bind something that must
-- run first (Hyprland runs the binds of a key press in the order they were
-- added). The user's files, loaded after both, can still unbind or rebind any
-- chord. Both start empty on every load.
o.platform_chords = {}
o.bind_decorators = {}
o.decorating = false

-- Modifier order, case and aliases don't change the chord Hyprland binds.
local modifier_aliases = { CONTROL = "CTRL", WIN = "SUPER", LOGO = "SUPER", MOD4 = "SUPER", META = "SUPER", MOD1 = "ALT" }

local function chord(keys)
  local parts = {}
  for raw in (tostring(keys) .. "+"):gmatch("([^+]*)%+") do
    local part = raw:match("^%s*(.-)%s*$"):upper()
    if part ~= "" then
      table.insert(parts, part)
    end
  end
  for index = 1, #parts - 1 do
    parts[index] = modifier_aliases[parts[index]] or parts[index]
  end

  local key = table.remove(parts) or ""
  table.sort(parts)
  table.insert(parts, key)
  return table.concat(parts, "+")
end

function o.bind(keys, description, dispatcher, options)
  local opts = options or {}

  if description then
    opts.description = description
  end

  dispatcher = command_from(dispatcher, description)

  if o.binding_phase == "defaults" and o.platform_chords[chord(keys)] then
    return
  elseif o.binding_phase == "platform" then
    o.platform_chords[chord(keys)] = true
  end

  -- A bind a decorator makes through o.bind is not decorated again.
  if not o.decorating then
    o.decorating = true
    for _, decorate in ipairs(o.bind_decorators) do
      local ok, err = pcall(decorate, keys, dispatcher, opts)
      if not ok then
        o.decorating = false
        error(err, 0)
      end
    end
    o.decorating = false
  end

  if type(dispatcher) == "string" then
    dispatcher = hl.dsp.exec_cmd(dispatcher)
  end

  hl.bind(keys, dispatcher, opts)
end

function o.rebind(keys, description, dispatcher, options)
  hl.unbind(keys)
  o.bind(keys, description, dispatcher, options)
end

function o.launch(command)
  return "uwsm-app -- " .. command
end

function o.exec_on_start(command)
  hl.on("hyprland.start", function()
    hl.exec_cmd(command)
  end)
end

function o.launch_on_start(command)
  o.exec_on_start(o.launch(command))
end

function o.launch_webapp(url)
  return "omarchy-launch-webapp " .. shell_quote(url)
end

function o.launch_webapp_sole(name, url)
  return "omarchy-launch-or-focus-webapp " .. shell_quote(name) .. " " .. shell_quote(url)
end

function o.launch_sole(match, command)
  return "omarchy-launch-or-focus " .. shell_quote(match) .. " " .. shell_quote(o.launch(command))
end

function o.bind_toggle(keys, description, toggle, options)
  o.bind(keys, description, "omarchy-toggle-" .. toggle, options)
end

function o.notify(message)
  return "omarchy-notification-send -u low " .. shell_quote(message)
end

function o.window(match, rules)
  rules.match = rules.match or {}

  if type(match) == "string" then
    rules.match.class = match
  else
    for key, value in pairs(match) do
      rules.match[key] = value
    end
  end

  hl.window_rule(rules)
end

local modifier_names = { "SHIFT", "CAPS", "CTRL", "CONTROL", "ALT", "MOD1", "MOD2", "MOD3", "SUPER", "WIN", "LOGO", "MOD4", "META", "MOD5" }

-- Hyprland reads a modifier out of any string that contains one's name, so
-- "NONE" or "" is no modifier at all.
local function holds_modifier(mods)
  if type(mods) ~= "string" then
    return mods ~= nil
  end

  mods = mods:upper()
  for _, name in ipairs(modifier_names) do
    if mods:find(name, 1, true) then
      return true
    end
  end

  return false
end

-- Hyprland rejects a gesture another one already covers, and gives Lua no way
-- to list what's registered. Record each one, so a platform's default gesture,
-- added after the user's files, can step aside for the user's own. The list
-- starts empty on every load, and hl.gesture is wrapped once whether or not a
-- reload keeps the Lua state.
if hl and hl.gesture then
  o.registered_gestures = {}

  if hl.gesture ~= o.gesture_wrapper then
    local register_gesture = hl.gesture

    o.gesture_wrapper = function(gesture, ...)
      if type(gesture) == "table" then
        table.insert(o.registered_gestures, {
          fingers = tonumber(gesture.fingers),
          direction = type(gesture.direction) == "string" and gesture.direction:lower() or "",
          modified = holds_modifier(gesture.mods),
        })
      end

      return register_gesture(gesture, ...)
    end
    hl.gesture = o.gesture_wrapper
  end
end
