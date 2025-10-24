-- nixCats-nvim main configuration entry point
-- This file is the starting point for all Neovim configuration

-- Add the lua directory to package.path so we can require our modules
local lua_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = lua_dir .. "?.lua;" .. lua_dir .. "?/init.lua;" .. package.path

-- Load core settings
require("options")
require("keymaps")
require("autocmds")

-- Load plugins
require("plugins")
