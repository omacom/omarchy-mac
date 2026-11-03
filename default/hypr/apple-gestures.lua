-- Macs swipe between workspaces with three fingers, as they do in macOS.
-- Loaded after the user's files, so a three-finger sideways gesture the user
-- set, or omarchy_workspace_gesture = false, keeps this one out instead of
-- Hyprland rejecting it as a duplicate. Lines added to hyprland.lua after the
-- toggles come too late for that, which is why the manual points at input.lua.

if _G.omarchy_workspace_gesture == false or not (o and o.apple_silicon and o.apple_silicon()) then
  return
end

local sideways = {
  horizontal = true,
  horiz = true,
  left = true,
  l = true,
  right = true,
  r = true,
  swipe = true,
}

for _, gesture in ipairs(o.registered_gestures or {}) do
  if gesture.fingers == 3 and not gesture.modified and sideways[gesture.direction] then
    return
  end
end

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
