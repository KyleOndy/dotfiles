require("git-worktree").setup({})
require("telescope").load_extension("git_worktree")
require("which-key").register({
	["<leader>w"] = {
		name = "+worktree",
		w = { '<cmd>lua require"telescope".extensions.git_worktree.git_worktrees()<cr>', "Switch worktree" },
		c = { '<cmd>lua require"telescope".extensions.git_worktree.create_git_worktree()<cr>', "Create worktree" },
	},
})
