-- Autocommands converted from nvimrc
local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Highlight trailing whitespace and tabs
augroup("ExtraWhitespace", { clear = true })
autocmd("ColorScheme", {
  group = "ExtraWhitespace",
  pattern = "*",
  callback = function()
    vim.cmd([[highlight ExtraWhitespace ctermbg=darkgreen guibg=darkgreen]])
    vim.fn.matchadd("ExtraWhitespace", [[\s\+$\|\t]])
  end,
})

-- Git commit settings
autocmd("FileType", {
  pattern = "gitcommit",
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.textwidth = 72
    vim.opt_local.colorcolumn = "50"
  end,
})

-- Mail settings
autocmd("FileType", {
  pattern = "mail",
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.textwidth = 72
  end,
})

-- Markdown settings
autocmd("FileType", {
  pattern = "markdown",
  callback = function()
    vim.opt_local.spell = true
  end,
})

-- Cursor line highlighting
augroup("CursorLineHighlight", { clear = true })
autocmd("ColorScheme", {
  group = "CursorLineHighlight",
  pattern = "*",
  callback = function()
    vim.cmd([[highlight CursorLineNr ctermbg=DarkRed guibg=DarkRed]])
    vim.cmd([[highlight CursorLine ctermbg=NONE guibg=NONE]])
  end,
})

-- Terminal cursor color
autocmd("TermOpen", {
  callback = function()
    vim.cmd([[highlight TermCursor ctermfg=red]])
  end,
})

-- Mojo file type detection
autocmd({ "BufRead", "BufNewFile" }, {
  pattern = { "*.mojo", "*.🔥" },
  callback = function()
    vim.bo.filetype = "mojo"
  end,
})
