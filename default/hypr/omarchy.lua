-- Omarchy Hyprland setup: helpers, defaults, and current theme overrides.

require("default.hypr.helpers")
local require_optional = require("default.hypr.require_optional")
local paths = require("default.hypr.paths")

-- Use Omarchy defaults, but don't edit these directly.
require("default.hypr.autostart")
if _G.omarchy_default_bindings ~= false then
  require("default.hypr.bindings.media")
  require("default.hypr.bindings.clipboard")
  require("default.hypr.bindings.tiling")
  require("default.hypr.bindings.utilities")
  require("default.hypr.bindings.voxtype")
  require_optional.module("default.hypr.bindings.applications")
  local apple_m1_air = paths.omarchy_path .. "/bin/omarchy-hw-apple-m1-air"
  if o.shell_succeeds(o.shell_quote(apple_m1_air)) then
    require("default.hypr.bindings.apple_m1_air")
  end
end
require("default.hypr.envs")
require("default.hypr.looknfeel")
require("default.hypr.qconsole")
require("default.hypr.input")
require("default.hypr.windows")

-- Current theme overrides.
require_optional.module("omarchy.current.theme.hyprland")
