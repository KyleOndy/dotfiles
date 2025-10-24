-- UI plugins configuration

-- which-key setup
require("which-key").setup({
  icons = {
    breadcrumb = "»",
    separator = "->",
    group = "+",
    ellipsis = "...",
    -- Disable mappings icons (which often use nerd fonts)
    mappings = false,
    -- Key icons that might use nerd fonts
    keys = {
      Up = "<Up>",
      Down = "<Down>",
      Left = "<Left>",
      Right = "<Right>",
      C = "<C-…>",
      M = "<M-…>",
      D = "<D-…>",
      S = "<S-…>",
      CR = "<CR>",
      Esc = "<Esc>",
      ScrollWheelDown = "<ScrollWheelDown>",
      ScrollWheelUp = "<ScrollWheelUp>",
      NL = "<NL>",
      BS = "<BS>",
      Space = "<Space>",
      Tab = "<Tab>",
      F1 = "<F1>",
      F2 = "<F2>",
      F3 = "<F3>",
      F4 = "<F4>",
      F5 = "<F5>",
      F6 = "<F6>",
      F7 = "<F7>",
      F8 = "<F8>",
      F9 = "<F9>",
      F10 = "<F10>",
      F11 = "<F11>",
      F12 = "<F12>",
    },
  },
})

-- nvim-web-devicons setup
require("nvim-web-devicons").setup({})

-- lualine status bar
require("lualine").setup({
  options = {
    icons_enabled = true,
    theme = "gruvbox",
    component_separators = { "", "" },
    section_separators = { "", "" },
    disabled_filetypes = {},
  },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff" },
    lualine_c = { "filename" },
    lualine_x = {
      {
        "diagnostics",
        sections = { "error", "warn", "info", "hint" },
        sources = { "nvim_lsp", "ale" },
      },
      "encoding",
      "fileformat",
      "filetype",
    },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = { "filename" },
    lualine_x = { "location" },
    lualine_y = {},
    lualine_z = {},
  },
  tabline = {},
  extensions = { "fugitive" },
})

-- marks.nvim for better mark visualization
require("marks").setup({})
