" --------------------------------------------------------------------------
"        _ __   ___  _____   _(_)_ __ ___
"       | '_ \ / _ \/ _ \ \ / / | '_ ` _ \
"       | | | |  __/ (_) \ V /| | | | | | |
"       |_| |_|\___|\___/ \_/ |_|_| |_| |_|
"
" Below is the magic that powers my day to day work.
"
" I have intentionally chosen to leave this as a single file for simplicity.
"
" todo:
"       - find / build a function/plugin to lookup word in dictionary
"       - looking into vim's 'thesaurus' command
"       - can I control the order items appear in the auto-complete buffer?
"
" --------------------------------------------------------------------------
" # neovim setup
" -------------------------------------------------------------

" Map the leader key to space. Easy to reach with either hand and shouldn't
" clobber other applications control sequences. Need to be mindful of tmux's
" leader (currently <C-Space>) since neovim is very often run within a
" tmux session.
let mapleader="\<SPACE>"

" I didn't really have a strong first choice for localleader, so I chose `,`
" arbitrarily. localleader is used to have different implementations for a
" function depending on file type.
let maplocalleader=","

" 'Ex mode is fucking dumb' --sircmpwm
" I have never intentionally entered Ex mode, make it a NOP.
nnoremap Q <Nop>

" I really like dark and warm color schemes. I used to rock a fork of
" Wombat256 [1]. Gruvbox [2] is 90% of where I want to be, and its available
" for everything via the contrib repo [3]. Given that, I've learned to live
" with almost perfect due to the amount of work it would take to make my own
" color scheme.
"
" [1] https://github.com/KyleOndy/wombat256mod
" [2] https://github.com/morhetz/gruvbox
" [3] https://github.com/morhetz/gruvbox-contrib
colorscheme gruvbox
set background=dark

" Allow backspace over everything in insert mode.
"     indent - allow backspacing over autoindent
"     eol    - allow backspacing over line breaks (join lines)
"     start  - allow backspacing over the start of insert
set backspace=indent,eol,start

" allow completions from; .      - current buffer
"                         w      - buffer from other windows
"                         b      - loaded buffers in the buffer list
"                         u      - unloaded buffers in the buffer list
"                         kspell - current active spell check dict
set complete=.,w,b,u,t,kspell

" make a best guess for where the tabstop should be when starting a new line.
set smartindent

" do not consider octal (leading 0) as a number. I tend to justify columns
" with leading zeros, and rarely (never>) work with octal numbers.
set nrformats-=octal

" greatly decrease the default (1000ms) timeout to wait for a mapped sequence
" to complete (<esc> sequences).
set ttimeoutlen=100

"  I don’t really want Vim to litter my filesystem with all of these piles of
"  nervous energy. --Lee Phillips
"  https://lee-phillips.org/badvim/
"
"  The above link has a much better explanation, but using backup files can
"  write your changes to an unexpected inode, causing inotify (and the like)
"  to not work as expected.
set nobackup
set nowritebackup
set nobackup
set noundofile
set noswapfile

" Give more space for displaying messages. Useful for diagnostics
set cmdheight=2

" # search settings
" -------------------------------------------------------------

" Highlight search results. Makes it easy to see all the matches.
set hlsearch

" Make searching case insensitive ...
set ignorecase

" ... unless the query has capital letters.
set smartcase

" jump to the first current match
set incsearch

" Use 'magic' patterns (extended regular expressions).
set magic

" Use <C-L> to clear the highlighting of :set hlsearch. Muscle memory maps
" nicely to clearing a terminal.
nnoremap <silent> <C-L> :nohlsearch<CR><C-L>

" # formattings
" -------------------------------------------------------------
set showcmd             " Show (partial) command in status line.
set showmatch           " highlight matching brackets.
set showmode            " Show current mode.
set ruler               " Show the line and column numbers of the cursor.
set number              " Show the line numbers on the left side.
set formatoptions+=o    " Continue comment marker in new lines.
set textwidth=0         " Hard-wrap long lines as you type them.
set expandtab           " Insert spaces when TAB is pressed.
set tabstop=2           " Render TABs using this many spaces.
set shiftwidth=2        " Indentation amount for < and > commands.

set noerrorbells        " No beeps. No one like terminal bells.
set modeline            " Enable modeline.
set linespace=0         " Set line-spacing to minimum.
set nojoinspaces        " Prevents inserting two spaces after punctuation on a join (J)

" More natural splits
set splitbelow          " Horizontal split below current.
set splitright          " Vertical split to right of current.

if !&scrolloff
  set scrolloff=3       " Show next 3 lines while scrolling.
endif
if !&sidescrolloff
  set sidescrolloff=5   " Show next 5 columns while side-scrolling.
endif
set display+=lastline
set nostartofline       " Do not jump to first character with page commands.

" explicitly show the start of a wrapped line
set showbreak=↪\
" explicitly show these characters
set list                " Show problematic characters.
set listchars=tab:→\ ,nbsp:␣,trail:•,extends:›,precedes:‹

set colorcolumn=72

" Highlight all tabs and trailing whitespace characters is an very noticeable
" color.
highlight ExtraWhitespace ctermbg=darkgreen
match ExtraWhitespace /\s\+$\|\t/


" # file configuration
" -------------------------------------------------------------

" todo: I should learn how to use tabs
"if has('path_extra')
"  setglobal tags-=./tags tags^=./tags;
"endif

set autoread            " If file updates, load automatically.
set hidden

" todo: move these filetype declaration into own file?

" wrap commit message at 72 characters, set a colorcolumn at 50 chracters for
" the commit title.
autocmd FileType gitcommit setlocal spell | setlocal tw=72 | setlocal colorcolumn=50

" mail width at 72 chracters to preserve formatting when the message is quoted
" in a reply by others
autocmd FileType mail setlocal spell | setlocal tw=72

" enable spell check when writing markdown
autocmd FileType markdown setlocal spell

set updatetime=250 " quicker updates

" Don't pass messages to |ins-completion-menu|.
set shortmess+=c
"
" Remove special characters for filename
set isfname-=:
set isfname-==
set isfname-=+

set history=1000      " Number of lines in command history.
set tabpagemax=50     " Maximum tab pages.

" Path/file expansion in colon-mode.
set wildmenu
set wildmode=list:longest
set wildchar=<TAB>

" commands
command! -nargs=0 -bar SiteDate execute "normal! A\<C-R>=strftime(\"%FT%TZ\")\<CR>"

" use jk to exit insert mode. Escape key is a far reach.
inoremap jk <Esc>`^
" Stop cursor from jumping over wrapped lines
nnoremap j gj
nnoremap k gk
" Make HOME and END behave like shell
inoremap <C-E> <End>
inoremap <C-A> <Home>

" # work with terminal
" -------------------------------------------------------------
"
" make the cursor red. Stands out more
highlight TermCursor ctermfg=red

" file specific settings
" -------------------------------------------------------------
au FileType haskell nnoremap <buffer> <F1> :HdevtoolsType<CR>           " todo: remove this?
au FileType haskell nnoremap <buffer> <silent> <F2> :HdevtoolsClear<CR> " todo: remove this?
" }

" # plugin settings
" -------------------------------------------------------------

" ## general
" -------------------------------------------------------------

" enable cursorline so we can color it
set cursorline
" Set the line number background coloring to dark gray
"highlight CursorLineNr ctermbg=DarkGrey
highlight CursorLineNr ctermbg=DarkRed
" do not highlight the line itslef
highlight CursorLine ctermbg=NONE

" ## airline
" -------------------------------------------------------------
let g:airline#extensions#tabline#enabled = 2
let g:airline#extensions#tabline#fnamemod = ':t'
let g:airline#extensions#tabline#left_sep = ' '
let g:airline#extensions#tabline#left_alt_sep = '|'
let g:airline#extensions#tabline#right_sep = ' '
let g:airline#extensions#tabline#right_alt_sep = '|'
let g:airline#extensions#ale#enabled = 1
let g:airline_left_sep = ' '
let g:airline_left_alt_sep = '|'
let g:airline_right_sep = ' '
let g:airline_right_alt_sep = '|'
let g:airline_theme= 'gruvbox'

" ## ale
" -------------------------------------------------------------
highlight ALEWarning ctermbg=DarkMagenta
let g:ale_linters = {
      \ 'gitcommit': ['proselint'],
      \ 'clojure': ['clj-kondo']
      \}

" ## fzf
" -------------------------------------------------------------
" linewise completion
"imap <c-x><c-l> <plug>(fzf-complete-line)

" ## vim-tmux-navigation
" -------------------------------------------------------------
let g:tmux_navigator_no_mappings = 1
nnoremap <silent> <A-h> :TmuxNavigateLeft<cr>
nnoremap <silent> <A-j> :TmuxNavigateDown<cr>
nnoremap <silent> <A-k> :TmuxNavigateUp<cr>
nnoremap <silent> <A-l> :TmuxNavigateRight<cr>
nnoremap <silent> <A-\> :TmuxNavigatePrevious<cr>

" ## neo-ghc
" -------------------------------------------------------------
let g:haskellmode_completion_ghc = 1
autocmd FileType haskell setlocal omnifunc=necoghc#omnifunc

" ## vim-test
" -------------------------------------------------------------

" ## languageclient
" -------------------------------------------------------------
let g:LanguageClient_autoStart = 1

nnoremap <F5> :call LanguageClient_contextMenu()<CR>

" ## rainbow
" -------------------------------------------------------------
let g:rainbow_active = 1

" ## ack
" -------------------------------------------------------------
if executable('ag')
  let g:ackprg = 'ag --vimgrep'
endif

" automatically highlight the word we are seaching for
let g:ackhighlight = 1


" ## terraform
" -------------------------------------------------------------
let g:terraform_align=1
let g:terraform_fmt_on_save=1

" ## elm-vim setup
" -------------------------------------------------------------
" I like to set my own leader bindings
let g:elm_setup_keybindings = 0

" ## sexp
" -------------------------------------------------------------
" So I have become old and crank and refuse to relearn any custom
" commands and keybinds I've developed over the years. This plugin clobbers
" some of my exisitng workflow so I am going to disable _all_ the mapping
" and only reenebale what I want.
"
" I also use tpope's mappings for sexp which cover a great deal of my use.
" see `:help sexp-explicit-mappings` for more information.

let g:sexp_filetypes = ""

" -------------------------------------------------------------
" treesitter
lua <<EOF
    require'nvim-treesitter.configs'.setup {
        highlight = {
          enable = true,
        },
        indent = {
          enable = true,
        },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "gnn",
            node_incremental = "grn",
            scope_incremental = "grc",
            node_decremental = "grm",
          },
        },
      ensure_installed = 'all'
    }
EOF

lua <<EOF
local lspconfig = require('lspconfig')
local on_attach = function(_, bufnr)
  require('completion').on_attach()
end
local servers = {
  'bashls',
  'clangd',
  'clojure_lsp',
  'cssls',
  'diagnosticls',
  'dockerls',
  'ghcide',
  'gopls',
  'html',
  'jsonls',
  'omnisharp',
  'pyls_ms',
  'terraformls',
  'tsserver',
  -- 'vimls', -- no nix package
  'yamlls',
}
for _, lsp in ipairs(servers) do
  lspconfig[lsp].setup {
    on_attach = on_attach,
  }
end
EOF

set foldmethod=expr
set foldexpr=nvim_treesitter#foldexpr()

" -------------------------------------------------------------
" general key mappings.
" I assign most letters to a broder group of functions, and assign leader
" mapping within those. Some keys are bound to a single command.

" top level bindings
nnoremap <silent> <leader> :WhichKey '<Space>'<CR>
nnoremap <silent> <localleader> :<c-u>WhichKey  ','<CR>
nmap <Leader>w :w<CR>

" (o) is for opening
nmap <leader>o? :map <leader>o<cr>
nmap <Leader>ob :Buffers<CR>
nmap <Leader>oc :Commits<CR>
nmap <Leader>of :Files<CR>
nmap <Leader>oo :GFiles<CR>

" (s) is for search
nmap <leader>s? :map <leader>s<cr>
nmap <Leader>sa :Ack<Space>
nmap <Leader>ss :Rg<CR>

" (g) is for git
nmap <leader>g? :map <leader>g<cr>
nmap <leader>gd :SignifyDiff<cr>
nmap <leader>gj <plug>(signify-next-hunk)
nmap <leader>gp :SignifyHunkDiff<cr>
nmap <leader>gu :SignifyHunkUndo<cr>
nmap <leader>gk <plug>(signify-prev-hunk)

" (e) is for edit
nmap <leader>e? :map <leader>g<cr>
nmap <silent> <leader>ev :e $DOTFILES/home/neovim.nix<CR>
nmap <silent> <leader>et :e $HOME/src/todo/todo.txt<CR>
nmap <silent> <leader>en :e `note --vim`<CR>G

" (t) is for test / terminal / toggle
nmap <leader>t? :map <leader>t<cr>
nmap <Leader>tf :TestFile<CR>
nmap <Leader>tg :TestVisit<CR>
nmap <Leader>tl :TestLast<CR>
nmap <Leader>tn :TestNearest<CR>
nmap <Leader>ts :TestSuite<CR>
nmap <leader>tr :call NumberToggle()<cr>
nmap <leader>ts :call WrapToggle()<cr>
nmap <silent> <leader>th :new<CR>:terminal<CR>
nmap <silent> <leader>tt :terminal<CR>
nmap <silent> <leader>tv :vnew<CR>:terminal<CR>

" mode specific mappings

" escape terminl mode
tnoremap <leader><ESC> <C-\><C-n>
tnoremap <leader>jk <C-\><C-n>
tnoremap jk <C-\><C-n>

"Copy and paste from system clipboard
vmap <Leader>y "+y
vmap <Leader>d "+d
nmap <Leader>p "+p
nmap <Leader>P "+P
vmap <Leader>p "+p
vmap <Leader>P "+P

" -------------------------------------------------------------
" helper functions

function! NumberToggle()
  if(&relativenumber == 1)
    set norelativenumber
    set number
  else
    set relativenumber
  endif
endfunc

" WordWrap toggle
function! WrapToggle()
  if(&wrap == 1)
    set nowrap
  else
    set wrap
  enfif
endfunc




" Enable startify startup screen
let g:webdevicons_enable_startify = 1

" Completion configuration
" Use <Tab> and <S-Tab> to navigate through popup menu
inoremap <expr> <Tab>   pumvisible() ? "\<C-n>" : "\<Tab>"
inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"

" Set completeopt to have a better completion experience
set completeopt=menuone,noinsert,noselect

" Avoid showing message extra message when using completion
set shortmess+=c

let g:completion_enable_auto_popup = 0
imap <tab> <Plug>(completion_smart_tab)
imap <s-tab> <Plug>(completion_smart_s_tab)
