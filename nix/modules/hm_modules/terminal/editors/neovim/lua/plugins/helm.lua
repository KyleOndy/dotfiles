-- vim-helm configuration

-- Disable diagnostics for Helm templates (they're Go templates, not valid YAML)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "helm",
  callback = function()
    vim.diagnostic.disable(0)
  end,
})
