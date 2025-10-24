-- Neovim options converted from nvimrc
local opt = vim.opt
local g = vim.g

-- Leader keys
g.mapleader = " "
g.maplocalleader = ","

-- UI settings
opt.termguicolors = true
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.showcmd = true
opt.showmatch = true
opt.showmode = true
opt.ruler = true

-- Search settings
opt.hlsearch = true
opt.ignorecase = true
opt.smartcase = true
opt.incsearch = true
opt.magic = true

-- Editing behavior
opt.backspace = { "indent", "eol", "start" }
opt.complete = ".,w,b,u,t,kspell"
opt.smartindent = true
opt.nrformats:remove("octal")

-- Timeout settings
opt.ttimeoutlen = 100
opt.updatetime = 250

-- File handling
opt.backup = false
opt.writebackup = false
opt.swapfile = false
opt.autoread = true
opt.hidden = true

-- Persistent undo
if vim.fn.has("persistent_undo") == 1 then
  local target_path = vim.fn.expand("~/.undodir")
  if vim.fn.isdirectory(target_path) == 0 then
    vim.fn.mkdir(target_path, "p", 0700)
  end
  opt.undodir = target_path
  opt.undofile = true
end

-- Display settings
opt.cmdheight = 2
opt.formatoptions:append("o")
opt.textwidth = 0
opt.expandtab = true
opt.tabstop = 2
opt.shiftwidth = 2
opt.errorbells = false
opt.modeline = true
opt.linespace = 0
opt.joinspaces = false

-- Splits
opt.splitbelow = true
opt.splitright = true

-- Scrolling
opt.scrolloff = 3
opt.sidescrolloff = 5
opt.display:append("lastline")
opt.startofline = false

-- Special characters
opt.showbreak = "↪ "
opt.list = true
opt.listchars = { tab = "→ ", nbsp = "␣", trail = "•", extends = "›", precedes = "‹" }

-- Visual guide
opt.colorcolumn = "72"

-- Command-line completion
opt.history = 1000
opt.tabpagemax = 50
opt.wildmenu = true
opt.wildmode = "list:longest"
opt.wildchar = 9 -- Tab

-- Filename special characters
opt.isfname:remove({ ":", "=", "+" })

-- Shorter messages
opt.shortmess:append("c")

-- Spell files
opt.spellfile = { "~/.config/nvim/spell/en.utf-8.add", "~/.config/nvim/spell/shared.en.utf-8.add" }

-- Colorscheme configuration
-- I really like dark and warm color schemes. I used to rock a fork of
-- Wombat256 [1]. Gruvbox [2] is 90% of where I want to be, and its available
-- for everything via the contrib repo [3]. Given that, I've learned to live
-- with almost perfect due to the amount of work it would take to make my own
-- color scheme. However, since I am running neovim 0.5.x, I am
-- currently using gruvbox.nvim [4], which better supports new
-- features. I hope that gruvbox proper will intergate these features
-- in the future.
--
-- [1] https://github.com/KyleOndy/wombat256mod
-- [2] https://github.com/morhetz/gruvbox
-- [3] https://github.com/morhetz/gruvbox-contrib
-- [4] https://github.com/npxbr/gruvbox.nvim
vim.cmd([[colorscheme gruvbox]])
vim.opt.background = "dark"

-- pretty sure this is the default
g.gruvbox_contrast_dark = "medium"

-- when in light mode, I am probably outside, and need the contract cranked to 11.
g.gruvbox_contrast_light = "hard"
