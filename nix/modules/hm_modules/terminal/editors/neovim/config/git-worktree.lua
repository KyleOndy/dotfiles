require("git-worktree").setup({})
require("telescope").load_extension("git_worktree")
require("which-key").add({
  { "<leader>w", group = "worktree" },
  {
    "<leader>wc",
    '<cmd>lua require"telescope".extensions.git_worktree.create_git_worktree()<cr>',
    desc = "Create worktree",
  },
  { "<leader>wn", "<esc>:!git wt-feature-branch ", desc = "Create worktree feature branch" },
  { "<leader>ww", '<cmd>lua require"telescope".extensions.git_worktree.git_worktrees()<cr>', desc = "Switch worktree" },
})
