-- Display arrangement model: identity, numbering and layout math.
-- Functions over plain tables with no hl calls, so the logic runs under a
-- stock Lua interpreter in test/shell.d/hyprland-displays-test.sh. The only
-- state is M.preferred, the main display the user chose.
--
-- A rect is { x, y, w, h } in Hyprland's logical pixels: positions as Hyprland
-- reports them, sizes being the pixel mode divided by the scale. A layout maps
-- display keys to rects, which may carry further fields.

local M = {}

-- The presets SUPER+/ steps through and the Monitor panel offers.
M.SCALE_STEPS = { 1, 1.25, 1.6, 2, 3, 4 }
local SCALE_STEPS = M.SCALE_STEPS

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

function M.moved(rect, x, y)
  local copy = {}
  for field, value in pairs(rect) do
    copy[field] = value
  end
  copy.x, copy.y = x, y
  return copy
end

function M.is_internal(name)
  return name:match("^eDP%-") ~= nil or name:match("^LVDS%-") ~= nil or name:match("^DSI%-") ~= nil
end

-- FALLBACK and HEADLESS-n are Hyprland's synthetic outputs, never a display.
function M.is_virtual(name)
  return name == "FALLBACK" or name:match("^HEADLESS") ~= nil
end

local function usable_serial(serial)
  local value = (serial or ""):lower():gsub("%s", ""):gsub("^0x", "")
  return value ~= "" and value:match("^0+$") == nil
end

-- Identity is the EDID description, which ends in the serial string, so the
-- same monitor keeps its identity on any port. The internal panel goes by
-- connector, EDID or not (the Asahi one has none). The connector joins an external's identity only
-- when its serial is unusable or two connected displays share a description;
-- desc: can't tell those apart, so they are selected by connector. Sets m.key
-- and m.selector on each monitor.
function M.identify(monitors)
  local count = {}
  for _, m in ipairs(monitors) do
    count[m.description] = (count[m.description] or 0) + 1
  end

  for _, m in ipairs(monitors) do
    if m.description == "" or M.is_internal(m.name) then
      m.key, m.selector = m.name, m.name
    elseif usable_serial(m.serial) and count[m.description] == 1 then
      m.key = "desc:" .. m.description
      m.selector = m.key
    else
      m.key = "desc:" .. m.description .. "@" .. m.name
      m.selector = m.name
    end
  end

  return monitors
end

-- A rule for a display that is off must not catch another monitor: desc:
-- selectors are unique per identity and the internal connector is always the
-- panel, but a USB-n or DP-n connector takes whatever is plugged in next.
function M.safe_when_absent(selector)
  return selector:sub(1, 5) == "desc:" or M.is_internal(selector)
end

-- Hyprland reports scales as float32 (1.6000000238418579); every valid scale
-- is a multiple of 1/120.
function M.snap_scale(scale)
  return math.floor(scale * 120 + 0.5) / 120
end

function M.logical_size(width, height, scale, transform)
  if (transform or 0) % 2 == 1 then
    width, height = height, width
  end
  return math.floor(width / scale + 0.5), math.floor(height / scale + 0.5)
end

local function gcd(a, b)
  while b ~= 0 do
    a, b = b, a % b
  end
  return a
end

-- Hyprland only accepts scales that divide the mode into whole logical pixels
-- in 1/120 steps, so clean scales are divisors of gcd(w*120, h*120). Rounds up
-- to the nearest clean value, like omarchy-hyprland-monitor-scaling.
function M.clean_scale(scale, width, height)
  local g = gcd(width * 120, height * 120)
  local k = math.max(1, math.min(math.floor(scale * 120 + 0.5), g))
  while g % k ~= 0 do
    k = k + 1
  end
  return k / 120
end

-- The next clean preset up (direction 1) or down (-1) from the current scale.
function M.step_scale(current, direction, width, height)
  local options, seen = {}, {}
  for _, preset in ipairs(SCALE_STEPS) do
    local scale = M.clean_scale(preset, width, height)
    if not seen[scale] then
      seen[scale] = true
      options[#options + 1] = scale
    end
  end
  table.sort(options)

  -- Derived scales sit between presets; step to the next one past current.
  if direction > 0 then
    for _, scale in ipairs(options) do
      if scale > current + 1e-6 then
        return scale
      end
    end
    return options[#options]
  end
  for index = #options, 1, -1 do
    if options[index] < current - 1e-6 then
      return options[index]
    end
  end
  return options[1]
end

-- Scale by real size: a display gets the clean scale that shows things as
-- many millimetres tall as another display shows them, from both displays'
-- pixels per inch (the EDID's physical size and the mode).

-- Pixels per inch from the EDID width. A size outside what real displays
-- have (TVs and projectors often report 0 or nonsense) counts as unknown.
local function ppi(d)
  local value = (d.physical or 0) > 0 and d.width / (d.physical / 25.4)
  if value and value >= 50 and value <= 600 then
    return value
  end
end

-- The clean scale nearest to scale, in either direction.
function M.nearest_clean(scale, width, height)
  local g = gcd(width * 120, height * 120)
  local k = math.floor(scale * 120 + 0.5)
  for step = 0, g do
    for _, candidate in ipairs({ k - step, k + step }) do
      if candidate >= 30 and candidate <= g and g % candidate == 0 then
        return candidate / 120
      end
    end
  end
end

-- The scale at which display d shows things the same real size as display
-- ref does at ref.scale, or nil without EDID sizes.
function M.derived_scale(d, ref)
  local dppi, rppi = ppi(d), ppi(ref)
  if not dppi or not rppi then
    return nil
  end
  return M.nearest_clean(dppi * ref.scale / rppi, d.width, d.height)
end

local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- Sharing a stretch of edge is what lets the pointer cross between two
-- displays; Hyprland keeps it inside the displays' union.
local function touching(a, b)
  if a.x + a.w == b.x or b.x + b.w == a.x then
    return a.y < b.y + b.h and b.y < a.y + a.h
  end
  if a.y + a.h == b.y or b.y + b.h == a.y then
    return a.x < b.x + b.w and b.x < a.x + a.w
  end
  return false
end

-- Whether rect can join layout: overlapping nothing, and touching something
-- if there is anything. The second result is the first display in the way.
function M.fits(layout, rect, except)
  local alone, touches = true, false
  for key, other in pairs(layout) do
    if key ~= except then
      if overlaps(rect, other) then
        return false, key
      end
      alone = false
      touches = touches or touching(rect, other)
    end
  end
  return alone or touches
end

local fits = M.fits

-- Main is a role: the display the user chose (M.preferred) while it's on,
-- otherwise the internal panel, otherwise the leftmost display.
function M.main(layout)
  if M.preferred and layout[M.preferred] then
    return M.preferred
  end
  local best
  for _, key in ipairs(sorted_keys(layout)) do
    if M.is_internal(key) then
      return key
    end
    local rect, top = layout[key], best and layout[best]
    if not best or rect.x < top.x or (rect.x == top.x and rect.y < top.y) then
      best = key
    end
  end
  return best
end

-- Display numbers 1..n run left to right, ties top to bottom.
function M.numbering(layout)
  local keys = sorted_keys(layout)
  table.sort(keys, function(a, b)
    local ra, rb = layout[a], layout[b]
    if ra.x ~= rb.x then
      return ra.x < rb.x
    end
    if ra.y ~= rb.y then
      return ra.y < rb.y
    end
    return a < b
  end)
  return keys
end

-- Where a w×h display goes against rect p. Left and right align the far edge
-- ("end", so bottoms are flush), "start" or "center"; above and below do the
-- same horizontally. "offset" keeps a fixed distance between the start edges.
function M.attach(p, side, align, offset, w, h)
  local x, y
  if side == "right" then
    x = p.x + p.w
  elseif side == "left" then
    x = p.x - w
  elseif side == "below" then
    y = p.y + p.h
  else
    y = p.y - h
  end

  local horizontal = side == "left" or side == "right"
  local start, span, size = horizontal and p.y or p.x, horizontal and p.h or p.w, horizontal and h or w
  local along
  if align == "end" then
    along = start + span - size
  elseif align == "start" then
    along = start
  elseif align == "center" then
    along = start + (span - size) // 2
  else
    -- Still sharing at least a pixel of edge when p has shrunk.
    along = math.max(start - size + 1, math.min(start + offset, start + span - 1))
  end

  if horizontal then
    y = along
  else
    x = along
  end
  return x, y
end

-- How q sits against p when they share an edge: the side, then the alignment
-- that attach() reproduces exactly. Nil when they don't touch.
local function relation(p, q)
  if not touching(p, q) then
    return nil
  end

  local side
  if q.x == p.x + p.w then
    side = "right"
  elseif q.x + q.w == p.x then
    side = "left"
  elseif q.y == p.y + p.h then
    side = "below"
  else
    side = "above"
  end

  local horizontal = side == "left" or side == "right"
  local ps, pspan = horizontal and p.y or p.x, horizontal and p.h or p.w
  local qs, qspan = horizontal and q.y or q.x, horizontal and q.h or q.w
  local flush_end, flush_start = qs + qspan == ps + pspan, qs == ps
  local centred = qs == ps + (pspan - qspan) // 2

  -- Beside each other, bottoms flush is the default; stacked, centred is.
  if horizontal then
    if flush_end then
      return side, "end"
    elseif flush_start then
      return side, "start"
    elseif centred then
      return side, "center"
    end
  else
    if centred then
      return side, "center"
    elseif flush_start then
      return side, "start"
    elseif flush_end then
      return side, "end"
    end
  end
  return side, "offset", qs - ps
end

-- A display seen for the first time goes right of main with bottoms flush,
-- or right of whatever already stands there.
function M.place_new(layout, w, h)
  local main = M.main(layout)
  if not main then
    return 0, 0
  end

  local rect = { w = w, h = h }
  rect.x, rect.y = M.attach(layout[main], "right", "end", nil, w, h)
  while true do
    local ok, blocker = fits(layout, rect)
    if ok then
      return rect.x, rect.y
    end
    rect.x, rect.y = M.attach(layout[blocker], "right", "end", nil, w, h)
  end
end

-- Whether stored positions cover every display in layout (and key, if
-- given), and whether they cover nothing else.
local function covers(positions, layout, key)
  local wanted, count = 0, 0
  if key then
    if not positions[key] then
      return false
    end
    wanted = 1
  end
  for other in pairs(layout) do
    if not positions[other] then
      return false
    end
    wanted = wanted + 1
  end
  for _ in pairs(positions) do
    count = count + 1
  end
  return true, count == wanted
end

local attach_all

-- A stored layout brought to the sizes the displays have now. current maps
-- the keys to rects; each goes to its stored spot at the size it had there,
-- shifted so anchor is where current has it, and is then seated at its size
-- now on the side and alignment it had. So a display that comes back at
-- another scale keeps its side instead of overlapping its neighbour. A spot
-- stored without its size is taken at the size now.
local function stored_at(positions, current, anchor)
  local p0 = positions[anchor]
  local dx, dy = current[anchor].x - p0[1], current[anchor].y - p0[2]
  local old, sizes = {}, {}
  for key, rect in pairs(current) do
    local p = positions[key]
    old[key] = M.moved(rect, p[1] + dx, p[2] + dy)
    old[key].w, old[key].h = p[3] or rect.w, p[4] or rect.h
    sizes[key] = { w = rect.w, h = rect.h }
  end
  return attach_all(old, sizes, anchor)
end

-- Where display `key` (w×h) lands if it connects while `layout` is on: its
-- spot in the most recently used stored layout that holds it and everything
-- on, preferring one for exactly this set, seated around main where it is.
-- A spot that overlaps a display that's on, or touches none, is skipped;
-- then the default spot. With nothing on, the most recent stored position is
-- used as is.
function M.place_joining(layout, key, w, h, layouts)
  local main = M.main(layout)
  if not main then
    for _, stored in ipairs(layouts) do
      local p = stored.positions[key]
      if p then
        return p[1], p[2]
      end
    end
    return 0, 0
  end

  for _, exact in ipairs({ true, false }) do
    for _, stored in ipairs(layouts) do
      local positions = stored.positions
      local holds, only = covers(positions, layout, key)
      if holds and only == exact then
        local current = { [key] = { x = 0, y = 0, w = w, h = h } }
        for other, rect in pairs(layout) do
          current[other] = rect
        end
        local spot = stored_at(positions, current, main)[key]
        local rect = { x = spot.x, y = spot.y, w = w, h = h }
        if fits(layout, rect) then
          return rect.x, rect.y
        end
      end
    end
  end

  return M.place_new(layout, w, h)
end

-- The arrangement the user made for exactly this set of displays, if any,
-- around display `anchor` where it is, at the sizes the displays have now.
function M.restore(layout, anchor, layouts)
  for _, stored in ipairs(layouts) do
    local positions = stored.positions
    local holds, only = covers(positions, layout)
    if holds and only then
      return stored_at(positions, layout, anchor)
    end
  end
end

-- Keep the arrangement in one piece, so the pointer can reach every display.
-- Walking out from main, a display that touches what's been reached and
-- overlaps none of it stays where it is. Any display left over is seated
-- again with place_joining against the ones that stayed.
function M.connect(layout, layouts)
  layouts = layouts or {}
  local main = M.main(layout)
  if not main then
    return layout
  end

  local result, rest = { [main] = layout[main] }, {}
  for _, key in ipairs(sorted_keys(layout)) do
    if key ~= main then
      rest[#rest + 1] = key
    end
  end

  local grew = true
  while grew do
    grew = false
    for index, key in ipairs(rest) do
      if key and fits(result, layout[key]) then
        result[key] = layout[key]
        rest[index] = false
        grew = true
      end
    end
  end

  for _, key in ipairs(rest) do
    if key then
      local rect = layout[key]
      result[key] = M.moved(rect, M.place_joining(result, key, rect.w, rect.h, layouts))
    end
  end
  return result
end

-- Re-seat displays after some change size (a scale step, a rotation). The
-- anchor (main unless one is given) keeps its spot, and every other display
-- keeps the side and alignment it had against the neighbour that links it to
-- the anchor; connect() mends whatever ends up overlapping or detached. sizes
-- maps keys to their new { w, h }.
function M.reflow(old, sizes, layouts, anchor)
  local main = anchor and old[anchor] and anchor or M.main(old)
  if not main then
    return {}
  end
  return M.connect(attach_all(old, sizes, main), layouts)
end

-- The part of reflow() that seats every display by its relation to the
-- anchor, before anything is mended.
function attach_all(old, sizes, main)
  local function sized(key, x, y)
    local rect = M.moved(old[key], x or old[key].x, y or old[key].y)
    if sizes[key] then
      rect.w, rect.h = sizes[key].w, sizes[key].h
    end
    return rect
  end

  local new, queue, head = { [main] = sized(main) }, { main }, 1
  while queue[head] do
    local p = queue[head]
    head = head + 1
    for _, q in ipairs(sorted_keys(old)) do
      if not new[q] then
        local side, align, offset = relation(old[p], old[q])
        if side then
          local rect = sized(q)
          new[q] = sized(q, M.attach(new[p], side, align, offset, rect.w, rect.h))
          queue[#queue + 1] = q
        end
      end
    end
  end

  for key in pairs(old) do
    new[key] = new[key] or sized(key)
  end
  return new
end

local function signature(positions)
  return table.concat(sorted_keys(positions), "\n")
end

-- Store the arrangement of the displays that are on as the most recently used
-- layout for that set, replacing the older entry for the same set.
function M.remember(layouts, layout, limit)
  local positions = {}
  for key, rect in pairs(layout) do
    positions[key] = { rect.x, rect.y, rect.w, rect.h }
  end

  local sig = signature(positions)
  local result = { { positions = positions } }
  for _, stored in ipairs(layouts) do
    if #result >= limit then
      break
    end
    if signature(stored.positions) ~= sig then
      result[#result + 1] = stored
    end
  end
  return result
end

-- The complete rule set: every display that's on where it is, and every known
-- display that's off at the spot it would take if it connected now. present
-- maps keys to rects carrying selector, scale and transform; known is the
-- store's per-display record. desc: rules come first, so a connector rule for
-- a display that shares its description stays the newest match.
function M.plan(present, known, layouts)
  local rules = {}
  for _, rect in pairs(present) do
    rules[#rules + 1] = { selector = rect.selector, x = rect.x, y = rect.y, scale = rect.scale, transform = rect.transform }
  end

  for _, key in ipairs(sorted_keys(known)) do
    local display = known[key]
    if not present[key] and M.safe_when_absent(display.selector) then
      local w, h = M.logical_size(display.size[1], display.size[2], display.scale, display.transform)
      local x, y = M.place_joining(present, key, w, h, layouts)
      rules[#rules + 1] = { selector = display.selector, x = x, y = y, scale = display.scale, transform = display.transform }
    end
  end

  table.sort(rules, function(a, b)
    local ad, bd = a.selector:sub(1, 5) == "desc:", b.selector:sub(1, 5) == "desc:"
    if ad ~= bd then
      return ad
    end
    return a.selector < b.selector
  end)
  return rules
end

return M
