-- Git-related plugin configs

-- gitsigns for git integration in the gutter
require("gitsigns").setup({
  current_line_blame = false, -- Toggle with <leader>gl instead
  on_attach = function(bufnr)
    local gs = package.loaded.gitsigns

    -- Navigation
    vim.keymap.set("n", "]c", function()
      if vim.wo.diff then
        return "]c"
      end
      vim.schedule(function()
        gs.next_hunk()
      end)
      return "<Ignore>"
    end, { expr = true, buffer = bufnr, desc = "Next git hunk" })

    vim.keymap.set("n", "[c", function()
      if vim.wo.diff then
        return "[c"
      end
      vim.schedule(function()
        gs.prev_hunk()
      end)
      return "<Ignore>"
    end, { expr = true, buffer = bufnr, desc = "Previous git hunk" })
  end,
})

-- Git keybindings via which-key
require("which-key").add({
  -- Global git hunk navigation
  { "]c", desc = "Next git hunk" },
  { "[c", desc = "Previous git hunk" },

  -- Git operations
  { "<leader>g", group = "git" },
  { "<leader>gg", "<cmd>tab Git<cr>", desc = "Git status" },
  { "<leader>gb", "<cmd>GBrowse<cr>", desc = "Browse file/selection in browser", mode = { "n", "v" } },
  { "<leader>gB", "<cmd>GBrowse!<cr>", desc = "Copy file/selection URL to clipboard", mode = { "n", "v" } },
  { "<leader>gd", "<cmd>Gdiffsplit<cr>", desc = "Diff this file" },
  { "<leader>gh", "<cmd>Gitsigns preview_hunk<cr>", desc = "Preview git hunk" },
  { "<leader>gl", "<cmd>Gitsigns toggle_current_line_blame<cr>", desc = "Toggle line blame" },
  { "<leader>gm", desc = "Show commit message for line (git-messenger)" },
  { "<leader>gp", "<cmd>Git push<cr>", desc = "Git push" },
  { "<leader>gr", "<cmd>Gitsigns reset_hunk<cr>", desc = "Reset/undo hunk", mode = { "n", "v" } },
  { "<leader>gs", "<cmd>Gitsigns stage_hunk<cr>", desc = "Stage hunk", mode = { "n", "v" } },
  { "<leader>gS", "<cmd>Gitsigns stage_buffer<cr>", desc = "Stage entire buffer" },
})
