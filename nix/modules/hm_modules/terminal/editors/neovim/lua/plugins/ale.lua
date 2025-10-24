-- ALE linting configuration

-- Highlight warnings with a dark magenta background
vim.cmd([[autocmd ColorScheme * highlight ALEWarning ctermbg=DarkMagenta guibg=DarkMagenta]])

-- Configure linters per filetype
vim.g.ale_linters = {
  gitcommit = { "proselint" },
}
-- Note: Clojure linting via clj-kondo is handled by clojure-lsp (LSP server)

-- Only lint when a file is saved, or when a file is loaded. Keep performance
-- higher and don't run so much in the background
vim.g.ale_lint_on_text_changed = "never"
vim.g.ale_lint_on_insert_leave = 0
