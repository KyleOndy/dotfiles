-- Main plugin loader
-- This file loads all plugin configurations

-- Load individual plugin configs
local plugin_modules = {
  "plugins.telescope",
  "plugins.treesitter",
  "plugins.lsp",
  "plugins.cmp",
  "plugins.conjure",
  "plugins.tmux_navigator",
  "plugins.git",
  "plugins.ui",
  "plugins.editing",
  "plugins.ale",
  "plugins.dap",
  "plugins.vim_test",
  "plugins.helm",
}

for _, module in ipairs(plugin_modules) do
  local ok, err = pcall(require, module)
  if not ok then
    vim.notify("Error loading " .. module .. ": " .. err, vim.log.levels.ERROR)
  end
end
