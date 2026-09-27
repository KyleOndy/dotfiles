-- Incremental selection is built in: `an` / `in` in visual mode.
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    -- Fails for filetypes with no installed parser.
    if pcall(vim.treesitter.start, args.buf) then
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end,
})
