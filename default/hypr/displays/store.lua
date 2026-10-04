-- Remembered display state in ~/.local/state/omarchy/displays.json:
--   displays: identity -> { selector, size = { w, h } in pixels, scale,
--             transform, block (its workspaces are block * 10 + 1..10),
--             connector (last seen on) }
--   main:     the display the user chose as main
--   scale_mode: "each" when every display keeps its own scale (Per display),
--             absent while scales are linked to main
--   global_workspaces: workspaces are global (display-workspaces-off)
--   connectors: connector -> block of each display that's connected, for
--             the bar
--   layouts:  arrangements the user made, most recent first,
--             each { positions = { identity = { x, y, w, h } } }, the size
--             in logical pixels the display had there
-- It is read and written with io.open and never require()'d: Hyprland watches
-- every required file and reloads the whole config when one changes.

local paths = require("default.hypr.paths")
local model = require("default.hypr.displays.model")

local M = {}

M.path = paths.state_home .. "/omarchy/displays.json"

local named_escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(value, indent)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(char)
      return named_escapes[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
  elseif kind == "number" then
    if math.type(value) == "integer" or value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.10g", value)
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind ~= "table" then
    return "null"
  end

  local inner = indent .. "  "
  local items = {}
  if value[1] ~= nil then
    for _, item in ipairs(value) do
      items[#items + 1] = encode(item, inner)
    end
    if #items <= 4 and not items[1]:find("\n", 1, true) then
      return "[" .. table.concat(items, ", ") .. "]"
    end
    return "[\n" .. inner .. table.concat(items, ",\n" .. inner) .. "\n" .. indent .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  if #keys == 0 then
    return "{}"
  end
  for _, key in ipairs(keys) do
    items[#items + 1] = encode(key) .. ": " .. encode(value[key], inner)
  end
  return "{\n" .. inner .. table.concat(items, ",\n" .. inner) .. "\n" .. indent .. "}"
end

local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Enough JSON for this file: objects, arrays, strings, numbers, booleans.
-- Returns nil on anything malformed.
local function decode(text)
  local pos = 1

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end

  local value

  local function string_value()
    local parts = {}
    pos = pos + 1
    while true do
      local chunk_end = text:find('["\\]', pos)
      if not chunk_end then
        error("unterminated string")
      end
      parts[#parts + 1] = text:sub(pos, chunk_end - 1)
      if text:sub(chunk_end, chunk_end) == '"' then
        pos = chunk_end + 1
        return table.concat(parts)
      end
      local escape = text:sub(chunk_end + 1, chunk_end + 1)
      if escape == "u" then
        parts[#parts + 1] = utf8.char(tonumber(text:sub(chunk_end + 2, chunk_end + 5), 16))
        pos = chunk_end + 6
      else
        parts[#parts + 1] = escapes[escape] or escape
        pos = chunk_end + 2
      end
    end
  end

  function value()
    skip()
    local char = text:sub(pos, pos)
    if char == "{" then
      local object = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return object
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          error("expected key")
        end
        local key = string_value()
        skip()
        if text:sub(pos, pos) ~= ":" then
          error("expected colon")
        end
        pos = pos + 1
        object[key] = value()
        skip()
        char = text:sub(pos, pos)
        pos = pos + 1
        if char == "}" then
          return object
        elseif char ~= "," then
          error("expected comma")
        end
      end
    elseif char == "[" then
      local array = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return array
      end
      while true do
        array[#array + 1] = value()
        skip()
        char = text:sub(pos, pos)
        pos = pos + 1
        if char == "]" then
          return array
        elseif char ~= "," then
          error("expected comma")
        end
      end
    elseif char == '"' then
      return string_value()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end

    local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not number or not tonumber(number) then
      error("unexpected character")
    end
    pos = pos + #number
    return tonumber(number)
  end

  local ok, result = pcall(value)
  if not ok then
    return nil
  end
  skip()
  if pos <= #text then
    return nil
  end
  return result
end

M.encode = function(value)
  return encode(value, "") .. "\n"
end
M.decode = decode

-- Only displays that can be recognised again are remembered: externals by
-- their EDID description, the internal panel by its connector. An external
-- that reported no EDID (a glitch the kernel can have after a display comes
-- back on) is kept for the session only, not as a new display for good.
local function lasting(key)
  return key:sub(1, 5) == "desc:" or model.is_internal(key)
end

local function point(p)
  local x, y = type(p) == "table" and math.tointeger(p[1]), type(p) == "table" and math.tointeger(p[2])
  if x and y then
    return { x, y }
  end
end

-- A stored position, with the size the display had there if it's valid.
local function spot(p)
  local xy = point(p)
  local w, h = xy and math.tointeger(p[3]), xy and math.tointeger(p[4])
  if w and h and w > 0 and h > 0 then
    xy[3], xy[4] = w, h
  end
  return xy
end

-- Keep only what this version can use, so nothing malformed reaches a rule.
local function sanitize(data)
  local state = { version = 1, displays = {}, layouts = {} }
  if type(data) ~= "table" or data.version ~= 1 then
    return state
  end
  state.main = type(data.main) == "string" and data.main or nil
  state.scale_mode = data.scale_mode == "each" and "each" or nil
  state.global_workspaces = data.global_workspaces == true or nil
  for name, block in pairs(type(data.connectors) == "table" and data.connectors or {}) do
    block = math.tointeger(block)
    if type(name) == "string" and block and block >= 0 and block < 100 then
      state.connectors = state.connectors or {}
      state.connectors[name] = block
    end
  end

  local displays, keys, used = type(data.displays) == "table" and data.displays or {}, {}, {}
  for key in pairs(displays) do
    keys[#keys + 1] = type(key) == "string" and key or nil
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local display = displays[key]
    if lasting(key) and type(display) == "table" and type(display.selector) == "string" then
      local size = point(display.size)
      local scale = type(display.scale) == "number" and model.snap_scale(display.scale)
      local transform = math.tointeger(display.transform or 0)
      -- A duplicate or wild block is dropped and handed out again.
      local block = math.tointeger(display.block)
      block = block and block >= 0 and block < 100 and not used[block] and block or nil
      if size and size[1] > 0 and size[2] > 0 and scale and scale >= 0.25 and scale <= 10 and transform and transform >= 0 and transform <= 7 then
        state.displays[key] = {
          selector = display.selector,
          connector = type(display.connector) == "string" and display.connector or nil,
          size = size,
          scale = scale,
          transform = transform,
          block = block,
        }
        used[block or -1] = true
      end
    end
  end

  -- A layout holding a display that isn't remembered is for a set that
  -- can't be recognised again, and goes as a whole.
  for _, layout in ipairs(type(data.layouts) == "table" and data.layouts or {}) do
    local positions = {}
    local valid = type(layout) == "table" and type(layout.positions) == "table" and next(layout.positions) ~= nil
    for key, p in pairs(valid and layout.positions or {}) do
      positions[key] = type(key) == "string" and lasting(key) and spot(p) or nil
      valid = valid and positions[key] ~= nil
    end
    if valid then
      state.layouts[#state.layouts + 1] = { positions = positions }
    end
  end

  return state
end

M.sanitize = sanitize

local last_written

-- A file that doesn't parse is moved aside to displays.json.bad rather than
-- overwritten by the next save.
function M.load(path)
  path = path or M.path
  local file = io.open(path, "r")
  if not file then
    return sanitize(nil)
  end
  local text = file:read("a")
  file:close()

  local data = decode(text)
  if data == nil and text:find("%S") then
    os.rename(path, path .. ".bad")
    last_written = nil
  else
    last_written = text
  end
  return sanitize(data)
end

-- Write only when the content changed, through a temp file and rename so a
-- crash or a full disk can't leave half a file behind.
function M.save(state, path)
  path = path or M.path
  local text = M.encode(sanitize(state))
  if text == last_written then
    return false
  end

  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    return false
  end
  local written = file:write(text)
  local closed = file:close()
  if not (written and closed and os.rename(tmp, path)) then
    os.remove(tmp)
    return false
  end
  last_written = text
  return true
end

return M
