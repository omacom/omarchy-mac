local paths = require("default.hypr.paths")
local require_all = require("default.hypr.require_all")

local toggles_dir = paths.state_home .. "/omarchy/toggles/hypr"
package.path = toggles_dir .. "/?.lua;" .. package.path

-- touchpad-disabled.lua / touchscreen-disabled.lua were generated Lua in older
-- versions and could carry an injected USB device name. They must never be loaded
-- as code again: exclude them so a not-yet-migrated install cannot execute a
-- leftover payload on reload. The migration recovers the name and deletes them.
require_all.files(toggles_dir, nil, {
  reload = true,
  exclude = {
    ["touchpad-disabled"] = true,
    ["touchscreen-disabled"] = true,
  },
})

local disabled_input_device = require("default.hypr.disabled-input-device")
disabled_input_device("touchpad")
disabled_input_device("touchscreen")

require("default.hypr.workspace-layouts")

-- A platform package's own late defaults (default/hypr/platform/*.lua), loaded
-- after the user's files so that the user's settings can keep them out (a
-- default gesture stepping aside for the user's own, say). They are read from
-- the packaged tree, so a development checkout in OMARCHY_PATH keeps them.
local platform_dir = paths.packaged_path .. "/default/hypr/platform"
package.path = platform_dir .. "/?.lua;" .. package.path
require_all.files(platform_dir, nil, { reload = true })
