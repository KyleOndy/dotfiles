-- Keymaps converted from nvimrc
local keymap = vim.keymap.set
local opts = { noremap = true, silent = true }

-- Disable Ex mode
keymap("n", "Q", "<Nop>", opts)

-- Clear search highlighting
keymap("n", "<C-L>", "<cmd>nohlsearch<CR><C-L>", { noremap = true, silent = true })

-- Better movement over wrapped lines
keymap("n", "j", "gj", { noremap = true })
keymap("n", "k", "gk", { noremap = true })

-- Insert mode shortcuts
keymap("i", "jk", "<Esc>`^", { noremap = true })
keymap("i", "<C-E>", "<End>", { noremap = true })
keymap("i", "<C-A>", "<Home>", { noremap = true })

-- System clipboard operations
-- Document in which-key
require("which-key").add({
  { "<leader>y", '"+y', desc = "Yank to clipboard", mode = "v" },
  { "<leader>p", '"+p', desc = "Paste from clipboard", mode = { "n", "v" } },
  { "<leader>P", '"+P', desc = "Paste before from clipboard", mode = { "n", "v" } },
})
