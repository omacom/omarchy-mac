-- Omarchy Hyprland setup: helpers, defaults, and current theme overrides.

require("default.hypr.helpers")
local paths = require("default.hypr.paths")
local require_all = require("default.hypr.require_all")
local require_optional = require("default.hypr.require_optional")

-- A platform package's own defaults (default/hypr/platform/defaults/*.lua in
-- the packaged tree), loaded before Omarchy's so that a chord they bind replaces
-- Omarchy's default for it and the user's files can override both. See
-- o.platform_chords in helpers.lua.
local platform_defaults = paths.packaged_path .. "/default/hypr/platform/defaults"
package.path = platform_defaults .. "/?.lua;" .. package.path
o.binding_phase = "platform"
require_all.files(platform_defaults, nil, { reload = true })
o.binding_phase = "defaults"

-- Use Omarchy defaults, but don't edit these directly.
require("default.hypr.autostart")
if _G.omarchy_default_bindings ~= false then
  require("default.hypr.bindings.media")
  require("default.hypr.bindings.clipboard")
  require("default.hypr.bindings.tiling")
  require("default.hypr.bindings.utilities")
  require("default.hypr.bindings.voxtype")
  require_optional.module("default.hypr.bindings.applications")
end
o.binding_phase = nil
require("default.hypr.envs")
require("default.hypr.looknfeel")
require("default.hypr.qconsole")
require("default.hypr.monitor-removal")
require("default.hypr.input")
require("default.hypr.windows")
require("default.hypr.displays")

-- Current theme overrides.
require_optional.module("omarchy.current.theme.hyprland")
