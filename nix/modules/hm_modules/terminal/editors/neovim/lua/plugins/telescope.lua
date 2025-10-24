-- Telescope configuration
require("telescope").setup({
  defaults = {
    file_sorter = require("telescope.sorters").get_fzy_sorter,
  },
})

-- Load fzy native extension
require("telescope").load_extension("fzy_native")

-- Keymaps via which-key
require("which-key").add({
  { "<leader>o", group = "open" },
  { "<leader>ob", "<cmd>Telescope buffers<cr>", desc = "Open Buffer" },
  {
    "<leader>oc",
    "<cmd>lua require('telescope.builtin').find_files({cwd = vim.fn.expand('%:p:h')})<cr>",
    desc = "Open Current Directory Files",
  },
  { "<leader>of", "<cmd>Telescope find_files<cr>", desc = "Open File" },
  { "<leader>og", "<cmd>Telescope git_files<cr>", desc = "Open Git Files" },
  {
    "<leader>oj",
    "<cmd>lua require('telescope.builtin').find_files({find_command = {'rg', '--files', '--glob', '*.json'}})<cr>",
    desc = "Open JSON Files",
  },
  { "<leader>ok", "<cmd>Telescope keymaps<cr>", desc = "Open Keymaps" },
  { "<leader>om", "<cmd>Telescope marks<cr>", desc = "Open Marks" },
  { "<leader>on", "<cmd>enew<cr>", desc = "New File" },
  { "<leader>op", "<cmd>Telescope man_pages<cr>", desc = "Open Man Pages" },
  { "<leader>or", "<cmd>Telescope oldfiles<cr>", desc = "Open Recent File" },
  { "<leader>ot", "<cmd>Telescope help_tags<cr>", desc = "Open Tags" },
  {
    "<leader>oy",
    "<cmd>lua require('telescope.builtin').find_files({find_command = {'rg', '--files', '--glob', '*.yaml', '--glob', '*.yml'}})<cr>",
    desc = "Open YAML Files",
  },
  { "<leader>s", group = "search" },
  { "<leader>s/", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "Search buffer" },
  { "<leader>sa", "<cmd>Telescope grep_string<cr>", desc = "Search word under cursor" },
  {
    "<leader>sb",
    "<cmd>lua require('telescope.builtin').live_grep({grep_open_files = true})<cr>",
    desc = "Search in open buffers",
  },
  { "<leader>sc", "<cmd>Telescope git_commits<cr>", desc = "Search git commits" },
  { "<leader>ss", "<cmd>Telescope live_grep<cr>", desc = "Search Live Grep" },
})
