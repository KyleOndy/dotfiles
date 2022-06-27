autocmd ColorScheme * highlight ALEWarning ctermbg=DarkMagenta guibg=DarkMagenta
let g:ale_linters = {
      \ 'gitcommit': ['proselint'],
      \ 'clojure': ['clj-kondo']
      \}
