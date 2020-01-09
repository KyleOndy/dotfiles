" vim:fdm=marker et ft=vim sts=2 sw=2 ts=2
" -------------------------------------------------------------
scriptencoding utf-8

" # bootstraping
" -------------------------------------------------------------

" automatically download vim-plug, if not present
if !filereadable(expand($XDG_CONFIG_HOME.'/nvim/autoload/plug.vim'))
  echo 'vim-plug not installed, downloading'
  !curl -fLo "$XDG_CONFIG_HOME/nvim/autoload/plug.vim" --create-dirs
        \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  echo 'vim-plug downloaded, will install plugins once vim loads'
  augroup VimPlugInstall
    autocmd!
    autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
  augroup END
else
  " Clear out install on enter
  augroup VimPlugInstall
    autocmd!
  augroup END
endif

call plug#begin()

" # plugins
" ------------------------------------------------------------

" ## core plugins
" -------------------------------------------------------------

" These pluging are always loaded as they are language agnostic or modify the
" behavior of neovim itself.

" provides a nice customizable status bar at the bottom of vim. Lots of useful
" information always visible.
Plug 'bling/vim-airline'

" theme that status bar. Like everything else I run, tweak all the settings
" and customizable the interface.
Plug 'vim-airline/vim-airline-themes'

" my favorite color scheme. Slowly tweaked over the years as needed.
Plug 'kyleondy/wombat256mod'

" lots of nice git commands so we don't have to leave nvim. Provides seamless
" git operations with familiar keybindings.
Plug 'tpope/vim-fugitive'

" shows a git diff in the gutter (+, -, ~). Very useful to quickly know what
" has changed within a file at a glance.
Plug 'airblade/vim-gitgutter'

" honor .editorconfig files. You need to respect other people's choices.
Plug 'editorconfig/editorconfig-vim'

" seamlessly move between tmux and nvim. Without ths plugin, working within
" vim panes inside tmux is painful. This allows for moving between tmux panes
" and neovim panes as if they are the same thing.
Plug 'christoomey/vim-tmux-navigator'

" easily add and change surrounding characters. Saving a few annoying
" keystrokes.
Plug 'tpope/vim-surround'

" fuzzy file finder. This is the application itself. The application is useful
" outside on neovim, directly useable in the shell. I chose to install it this
" way because they support it, and it stays updated this way.
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }

" funzzy file finding in vim. Perhaps one of my most used plugins. Easily open
" a file via a fuzzy match.
Plug 'junegunn/fzf.vim'

" intellisense engine for vim8 & neovim. This is one of the new kids on
" the block, but is picking up steam. I like the range of sources coc can pull
" from.
Plug 'neoclide/coc.nvim', {'do': { -> coc#util#install()}}

" show marks in gutter. Without this, I never remember where the marks I et
" are.
Plug 'kshenoy/vim-signature'

" quick (un)comment code.
Plug 'tpope/vim-commentary'

" easily invoke a test runner from within neovim.
Plug 'janko-m/vim-test'

" langauge server. Offload launage specific autocompletes and lints and such
" to a langauge server.
Plug 'autozimu/LanguageClient-neovim', { 'branch': 'next', 'do': 'bash install.sh' }

" completion from other tmux windows. This is really nice to have suggestions
" from other tmux panes as you type.
Plug 'wellle/tmux-complete.vim'

" Asynchronous linting/fixing for Vim and LSP integration. Handles almost all
" linters and langauge servers out of the box.
Plug 'w0rp/ale'

" help you read complex code by showing diff level of parentheses in diff color. Once you get used to this, its hard to go back.
Plug 'luochen1990/rainbow'

" ## markdown plugins
" -------------------------------------------------------------

" provides syntax and other nice to haves for markdown
Plug 'gabrielelana/vim-markdown', { 'for': 'markdown' }

" ## haskell plugins
" -------------------------------------------------------------

" help for haskell
Plug 'neovimhaskell/haskell-vim', { 'for': 'haskell' }

" run stylish-haskell on save
Plug 'nbouscal/vim-stylish-haskell', { 'for': 'haskell' }

" the power of ghc-mod
Plug 'eagletmt/ghcmod-vim', { 'for': 'haskell' }

" command execution
Plug 'shougo/vimproc', { 'for': 'haskell', 'do': 'make' }

" hdevtool support
Plug 'bitc/vim-hdevtools', { 'for': 'haskell' }

" lhs support.
Plug 'wting/lhaskell.vim', { 'for': 'haskell' }

" ## elm plugins
" -------------------------------------------------------------
Plug 'elmcast/elm-vim'

" ## golang plugins
" -------------------------------------------------------------
Plug 'fatih/vim-go', { 'for': 'go' }

" ## json plugins
" -------------------------------------------------------------
Plug 'elzr/vim-json', { 'for': 'json' }

" ## jenkinsfile plugins
" -------------------------------------------------------------
Plug 'martinda/Jenkinsfile-vim-syntax', { 'for': 'jenkinsfile' }

" ## powerhsell plugins
" -------------------------------------------------------------
Plug 'PProvost/vim-ps1', { 'for': 'ps1' }

" ## ansible plugins
" -------------------------------------------------------------

" ansible syntax
Plug 'pearofducks/ansible-vim', { 'for': 'ansible' }

" ## puppet plugins
" -------------------------------------------------------------
Plug 'rodjek/vim-puppet', { 'for': 'puppet' }

" ## groovy plugins
" -------------------------------------------------------------
Plug 'vim-scripts/groovyindent-unix', { 'for': 'groovy' }


" ## terraform plugins
" -------------------------------------------------------------
Plug 'hashivim/vim-terraform'

call plug#end()

" # neovim setup
" -------------------------------------------------------------

" enable syntax and autocmd if available. These should always be available
" within the enviroments I am working in.
if has('autocmd')
  filetype plugin indent on
endif
if has('syntax') && !exists('g:syntax_on')
  syntax enable
endif

" # general settings
" -------------------------------------------------------------

" Map the leader key to space. Easy to reach with either hand and shouldn't
" clobber other applications control sequences. Need to be mindful of tmux's
" leader since neovim is very often run within a tmux session.
let mapleader="\<SPACE>"

" set the prefered color scheme.
colors wombat256mod

" Allow backspace over everything in insert mode.
set backspace=indent,eol,start
" todo: what does removing `i` do?
set complete-=i
" try and guess where the next line should be indented.
set smartindent
" do notconsider octal (leading 0) as a number.
set nrformats-=octal
" greatly decraase the default (1000ms) timeout to wait for a mapped sequence to complete (<esc> sequences).
set ttimeoutlen=100

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
if maparg('<C-L>', 'n') ==# ''
  nnoremap <silent> <C-L> :nohlsearch<CR><C-L>
endif
" }

" # formattings
" -------------------------------------------------------------
set showcmd             " Show (partial) command in status line.
set showmatch           " hlighlight matching brackets.
set showmode            " Show current mode.
set ruler               " Show the line and column numbers of the cursor.
set number              " Show the line numbers on the left side.
set formatoptions+=o    " Continue comment marker in new lines.
set textwidth=0         " Hard-wrap long lines as you type them.
set expandtab           " Insert spaces when TAB is pressed.
set tabstop=2           " Render TABs using this many spaces.
set shiftwidth=2        " Indentation amount for < and > commands.

set noerrorbells        " No beeps. Noone like terminal bells.
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

" Tell Vim which characters to show for expanded TABs,
" trailing whitespace, and end-of-lines. VERY useful!
if &listchars ==# 'eol:$'
  set listchars=tab:>\ ,trail:-,extends:>,precedes:<,nbsp:+
endif
set list                " Show problematic characters.

" Also highlight all tabs and trailing whitespace characters.
highlight ExtraWhitespace ctermbg=darkgreen guibg=darkgreen
match ExtraWhitespace /\s\+$\|\t/


" # file configuration
" -------------------------------------------------------------

if has('path_extra')
  setglobal tags-=./tags tags^=./tags;
endif

set autoread            " If file updates, load automatically.
set hidden

" wrap commit message at 72 chracters, set a colorcolumn at 50 chracters for
" the commit title.
autocmd FileType gitcommit setlocal spell | setlocal tw=72 | setlocal colorcolumn=50

" mail width at 72 chracters to preserve formatting when the message is quoted
" in a reply by others
autocmd FileType mail setlocal spell | setlocal tw=72

" enable spell check when writing markdown
autocmd FileType markdown setlocal spell

" typicaly literate haskell is going to be embeded into a webage, so keep a
" *hard* line length is critical to prevent users from having to scroll code
" blocks.
autocmd FileType lhaskell setlocal colorcolumn=72

set updatetime=100 " quicker updates

" Remove special characters for filename
set isfname-=:
set isfname-==
set isfname-=+

if &history < 1000
  set history=1000      " Number of lines in command history.
endif
if &tabpagemax < 50
  set tabpagemax=50     " Maximum tab pages.
endif

if &undolevels < 200
  set undolevels=200    " Number of undo levels.
endif

" Path/file expansion in colon-mode.
set wildmenu
set wildmode=list:longest
set wildchar=<TAB>

if !empty(&viminfo)
  set viminfo^=!        " Write a viminfo file with registers.
endif
set sessionoptions-=options

" commands
command! -nargs=0 -bar SiteDate execute "normal! A\<C-R>=strftime(\"%FT%TZ\")\<CR>"

" Diff options
set diffopt+=iwhite

" use jk to exit insert mode. Escape key is a far reach.
inoremap jk <Esc>`^
"Enter to go to EOF and backspace to go to start
nnoremap <CR> G
nnoremap <BS> gg
" Stop cursor from jumping over wrapped lines
nnoremap j gj
nnoremap k gk
" Make HOME and END behave like shell
inoremap <C-E> <End>
inoremap <C-A> <Home>

" # gui options
" -------------------------------------------------------------

" Relative numbering
function! NumberToggle()
  if(&relativenumber == 1)
    set norelativenumber
    set number
  else
    set relativenumber
  endif
endfunc

" Toggle between normal and relative numbering.
nnoremap <leader>r :call NumberToggle()<cr>

" # keybindings
" -------------------------------------------------------------

" Save file
nnoremap <Leader>w :w<CR>
" load
nnoremap <Leader>e :e<CR>
"Copy and paste from system clipboard
vmap <Leader>y "+y
vmap <Leader>d "+d
nmap <Leader>p "+p
nmap <Leader>P "+P
vmap <Leader>p "+p
vmap <Leader>P "+P

" Quickly edit/reload the vimrc file
nmap <silent> <leader>ev :e $MYVIMRC<CR>
nmap <silent> <leader>sv :so $MYVIMRC<CR>

nmap <silent> <leader>et :e $HOME/src/todo/todo.txt<CR>

" # work with terminal
" -------------------------------------------------------------
"
nnoremap <silent> <leader>tt :terminal<CR>            " new terminal
nnoremap <silent> <leader>tv :vnew<CR>:terminal<CR>   " new terminal in vertical split
nnoremap <silent> <leader>th :new<CR>:terminal<CR>    " new terminal in Horizontal split
" Terminal settings
tnoremap <Leader><ESC> <C-\><C-n>                     " escape terminal mode with leader esc
tnoremap <Leader>jk <C-\><C-n>                        " or escape with jk, just like insert mode
highlight TermCursor ctermfg=red guifg=red            " make the cursor red. Stands out more

" file specific settings
" -------------------------------------------------------------
au FileType haskell nnoremap <buffer> <F1> :HdevtoolsType<CR>           " todo: remove this?
au FileType haskell nnoremap <buffer> <silent> <F2> :HdevtoolsClear<CR> " todo: remove this?
" }

" # plugin settings
" -------------------------------------------------------------

" ## general
" -------------------------------------------------------------
" assuming pyenv is installed and a virtualenv named neovim3 is setup
let g:python3_host_prog = '/home/kondy/.pyenv/shims/python3'

" ## fugitive
" -------------------------------------------------------------
nnoremap <Leader>gc :Gcommit<CR>
nnoremap <Leader>gs :Gstatus<CR>
nnoremap <Leader>gd :Gdiff<CR>
nnoremap <Leader>gb :Gblame<CR>
nnoremap <Leader>gL :exe ':!cd ' . expand('%:p:h') . '; git la'<CR>
nnoremap <Leader>gl :exe ':!cd ' . expand('%:p:h') . '; git las'<CR>
nnoremap <Leader>gr :Gread<CR>
nnoremap <Leader>gw :Gwrite<CR>
nnoremap <Leader>gp :Git push<CR>
nnoremap <Leader>g- :silent! Git stash<CR>:e<CR>
nnoremap <Leader>g+ :silent! Git stash pop<CR>:e<CR>

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
let g:airline_theme= 'wombat'

" ## ale
" -------------------------------------------------------------
highlight ALEWarning ctermbg=DarkMagenta

" ## fzf
" -------------------------------------------------------------
" linewise completion
imap <c-x><c-l> <plug>(fzf-complete-line)
" Open file menu
nnoremap <Leader>o :Files<CR>
" Open git tracked files (git ls-files)
nnoremap <Leader>f :GFiles<CR>
" Open buffer menu
nnoremap <Leader>b :Buffers<CR>
" Open most recently used files
nnoremap <Leader>c :Commits<CR>

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

" ## vim-json
" -------------------------------------------------------------
let g:vim_json_syntax_conceal = 0

" ## vim-test
" -------------------------------------------------------------
" these "Ctrl mappings" work well when Caps Lock is mapped to Ctrl
nnoremap <Leader>tn :TestNearest<CR>
nnoremap <Leader>tf :TestFile<CR>
nnoremap <Leader>ts :TestSuite<CR>
nnoremap <Leader>tl :TestLast<CR>
nnoremap <Leader>tg :TestVisit<CR>

" ## languageclient
" -------------------------------------------------------------
let g:LanguageClient_autoStart = 1
let g:LanguageClient_serverCommands = {
  \ 'python': ['/home/kondy/.pyenv/shims/pyls'],
  \ }

nnoremap <F5> :call LanguageClient_contextMenu()<CR>

" ## rainbow
" -------------------------------------------------------------
let g:rainbow_active = 1

" ## terraform
" -------------------------------------------------------------
let g:terraform_align=1
let g:terraform_fold_sections=1
let g:terraform_commentstring='//%s'
let g:terraform_fmt_on_save=1

" ## elm-vim setup
" -------------------------------------------------------------
" I like to set my own leader bindings
let g:elm_setup_keybindings = 0
