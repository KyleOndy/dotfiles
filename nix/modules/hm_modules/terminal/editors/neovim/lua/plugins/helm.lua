-- vim-helm configuration

-- Disable diagnostics for Helm templates (they're Go templates, not valid YAML)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "helm",
  callback = function()
    -- disable() is deprecated as of nvim 0.10 in favour of enable(false, ...)
    vim.diagnostic.enable(false, { bufnr = 0 })
  end,
})
