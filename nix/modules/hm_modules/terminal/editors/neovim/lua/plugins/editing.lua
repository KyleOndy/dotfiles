-- Editing plugins configuration

-- vim-easymotion for quick navigation
vim.g.EasyMotion_do_mapping = 0 -- Disable default mappings
vim.g.EasyMotion_smartcase = 1

-- Keymaps via which-key
require("which-key").add({
  { "<leader>f", group = "find/jump" },
  { "<leader>fj", "<Plug>(easymotion-j)", desc = "Jump down", mode = { "n", "v", "o" } },
  { "<leader>fk", "<Plug>(easymotion-k)", desc = "Jump up", mode = { "n", "v", "o" } },
  { "<leader>fl", "<Plug>(easymotion-lineforward)", desc = "Jump forward on line", mode = { "n", "v", "o" } },
  { "<leader>fh", "<Plug>(easymotion-linebackward)", desc = "Jump backward on line", mode = { "n", "v", "o" } },
  { "<leader>ff", "<Plug>(easymotion-overwin-f2)", desc = "Jump to 2-char search" },
})

-- vim-surround: no configuration needed (cs, ds, ys text objects)
-- editorconfig-vim: no configuration needed (respects .editorconfig files)
