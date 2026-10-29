#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# The built-in trackpad's custom acceleration must stay a valid libinput curve:
# at most 64 points, starting at 0 and never slowing down, with the scroll
# curve set alongside it (a custom profile otherwise scrolls unaccelerated).
result=$(OMARCHY_PATH="$ROOT" lua <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path

local devices = {}
hl = {
  config = function() end,
  device = function(device)
    devices[#devices + 1] = device
  end,
}
o = { window = function() end }

require("default.hypr.input")

local trackpad
for _, device in ipairs(devices) do
  if device.name == "apple-mtp-multi-touch" then
    trackpad = device
  end
end
if not trackpad then
  print("no apple-mtp-multi-touch device")
  return
end

local fields = {}
for field in trackpad.accel_profile:gmatch("%S+") do
  fields[#fields + 1] = field
end
local points = #fields - 2
if fields[1] ~= "custom" or not (tonumber(fields[2]) > 0) then
  print("not a custom profile with a step: " .. trackpad.accel_profile)
elseif points < 2 or points > 64 then
  print(("%d points, libinput takes 2 to 64"):format(points))
elseif tonumber(fields[3]) ~= 0 then
  print("first point is not 0")
elseif not trackpad.scroll_points then
  print("no scroll_points")
else
  for i = 4, #fields do
    if tonumber(fields[i]) < tonumber(fields[i - 1]) then
      print("output speed drops at point " .. (i - 2))
      return
    end
  end
  print("ok")
end
LUA
)

[[ $result == "ok" ]] || fail "trackpad curve is a valid libinput custom profile" "$result"
pass "trackpad curve is a valid libinput custom profile"
