-- vim-test configuration for running tests

-- Keymaps via which-key
require("which-key").add({
  { "<leader>t", group = "test" },
  { "<leader>tn", ":TestNearest<CR>", desc = "Test Nearest" },
  { "<leader>tf", ":TestFile<CR>", desc = "Test File" },
  { "<leader>ts", ":TestSuite<CR>", desc = "Test Suite" },
  { "<leader>tl", ":TestLast<CR>", desc = "Test Last" },
  { "<leader>tg", ":TestVisit<CR>", desc = "Test Visit (go to)" },
})
