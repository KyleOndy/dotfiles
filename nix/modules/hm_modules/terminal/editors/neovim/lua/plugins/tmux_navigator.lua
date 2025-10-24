-- vim-tmux-navigator configuration
-- Navigate seamlessly between Neovim and tmux panes

-- Disable default mappings
vim.g.tmux_navigator_no_mappings = 1

-- Custom keymaps using Alt key
local opts = { noremap = true, silent = true }
vim.keymap.set("n", "<A-h>", "<cmd>TmuxNavigateLeft<CR>", opts)
vim.keymap.set("n", "<A-j>", "<cmd>TmuxNavigateDown<CR>", opts)
vim.keymap.set("n", "<A-k>", "<cmd>TmuxNavigateUp<CR>", opts)
vim.keymap.set("n", "<A-l>", "<cmd>TmuxNavigateRight<CR>", opts)
vim.keymap.set("n", "<A-\\>", "<cmd>TmuxNavigatePrevious<CR>", opts)
