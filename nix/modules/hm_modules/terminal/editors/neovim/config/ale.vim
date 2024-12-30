autocmd ColorScheme * highlight ALEWarning ctermbg=DarkMagenta guibg=DarkMagenta
let g:ale_linters = {
      \ 'gitcommit': ['proselint'],
      \ 'clojure': ['clj-kondo']
      \}

" Only lint when a while is saved, or when a file is loaded. Keep proframnce a
" bit higer and don't run so much in the background
let g:ale_lint_on_text_changed = 'never'
let g:ale_lint_on_insert_leave = 0
