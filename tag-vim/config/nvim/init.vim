" install vim-plug if not installed
if empty(glob('~/.config/nvim/autoload/plug.vim'))
  silent !curl -fLo ~/.config/nvim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall
endif

call plug#begin('~/.config/nvim/plugged')

  " core plugins {
      " airline is a better status line and a tab-bar for nvim.
      Plug 'bling/vim-airline'
      " airline themse
      Plug 'vim-airline/vim-airline-themes'
      " my favorite color scheme
      Plug 'kyleondy/wombat256mod'
      " a Git wrapper so awesome, it should be illegal
      Plug 'tpope/vim-fugitive'
      " shows a git diff in the gutter
      Plug 'airblade/vim-gitgutter'
      " honor .editorconfig files
      Plug 'editorconfig/editorconfig-vim'
      " better tmux navigation
      Plug 'christoomey/vim-tmux-navigator'
      " more tpope, surround
      Plug 'tpope/vim-surround'
      " ansible syntax
      Plug 'pearofducks/ansible-vim'
      " fuzzy file finder
      Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
      " funzzy file finding in vim
      Plug 'junegunn/fzf.vim'
      " autocompletion
      Plug 'Shougo/deoplete.nvim', { 'do': ':UpdateRemotePlugins' }
      " tab completions
      " Plug 'ervandew/supertab'
      " haskicrop master bundle
      Plug 'hashivim/vim-hashicorp-tools'
      " show marks in gutter
      Plug 'kshenoy/vim-signature'
      " another tpope plugin
      Plug 'tpope/vim-commentary'
      " async linting
      Plug 'w0rp/ale'
  " }
  " markdown {
      Plug 'gabrielelana/vim-markdown', { 'for': 'markdown' }
  " }
  " haskell {
      " hekp for haskell
      Plug 'neovimhaskell/haskell-vim', { 'for': 'haskell' }
      " run stylish-haskell on save
      Plug 'nbouscal/vim-stylish-haskell', { 'for': 'haskell' }
      " the power of ghc-mod
      Plug 'eagletmt/ghcmod-vim', { 'for': 'haskell' }
      " use ghc-mod for completion
      "Plug 'eagletmt/neco-ghc', { 'for': 'haskell' }
      " command execution
      Plug 'shougo/vimproc', { 'for': 'haskell', 'do': 'make' }
      " hdevtool support
      Plug 'bitc/vim-hdevtools', { 'for': 'haskell' }
      " lhs support
      Plug 'wting/lhaskell.vim', { 'for': 'haskell' }
  " }
  " elm {
      Plug 'lambdatoast/elm.vim', { 'for': 'elm' }
  " }
  " golang {
      Plug 'fatih/vim-go', { 'for': 'go' }
  " }
  " markdown {
      Plug 'gabrielelana/vim-markdown', { 'for': 'markdown' }
  " }
  " json {
      Plug 'elzr/vim-json', { 'for': 'json' }
  " }
  " jenkinsfile {
      Plug 'martinda/Jenkinsfile-vim-syntax', { 'for': 'jenkinsfile' }
  " }

call plug#end()

if has('autocmd')
  filetype plugin indent on
endif
if has('syntax') && !exists('g:syntax_on')
  syntax enable
endif

" Map the leader key to ,
let mapleader="\<SPACE>"

" General {
  colors wombat256mod

  set backspace=indent,eol,start      " Allow backspace over everything in insert mode.
  set complete-=i
  set smarttab
  set smartindent
  set nrformats-=octal
  set ttimeout
  set ttimeoutlen=100
" }

" Search {
  set hlsearch            " Highlight search results.
  set ignorecase          " Make searching case insensitive
  set smartcase           " ... unless the query has capital letters.
  set incsearch           " Incremental search.
  set gdefault            " Use 'g' flag by default with :s/foo/bar/.
  set magic               " Use 'magic' patterns (extended regular expressions).

  " Use <C-L> to clear the highlighting of :set hlsearch.
  if maparg('<C-L>', 'n') ==# ''
    nnoremap <silent> <C-L> :nohlsearch<CR><C-L>
  endif
" }

" Formatting {
  set showcmd             " Show (partial) command in status line.
  set showmatch           " Show matching brackets.
  set showmode            " Show current mode.
  set ruler               " Show the line and column numbers of the cursor.
  set number              " Show the line numbers on the left side.
  set formatoptions+=o    " Continue comment marker in new lines.
  set textwidth=0         " Hard-wrap long lines as you type them.
  set expandtab           " Insert spaces when TAB is pressed.
  set tabstop=2           " Render TABs using this many spaces.
  set shiftwidth=2        " Indentation amount for < and > commands.

  set noerrorbells        " No beeps.
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

" }

" Configuration {
  if has('path_extra')
    setglobal tags-=./tags tags^=./tags;
  endif

  set autoread            " If file updates, load automatically.
  set hidden

  autocmd FileType gitcommit setlocal spell | setlocal tw=72 | setlocal colorcolumn=50
  autocmd FileType mail setlocal spell | setlocal tw=80
  autocmd FileType markdown setlocal spell

  set updatetime=100

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

  " use jk to exit insert mode
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
" }

" GUI Options {
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
" }

" Keybindings {
  " Save file
  nnoremap <Leader>w :w<CR>
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

  nnoremap <silent> <leader>tt :terminal<CR>
  nnoremap <silent> <leader>tv :vnew<CR>:terminal<CR>
  nnoremap <silent> <leader>th :new<CR>:terminal<CR>
  " Terminal settings
  tnoremap <Leader><ESC> <C-\><C-n>
  highlight TermCursor ctermfg=red guifg=red

  au FileType haskell nnoremap <buffer> <F1> :HdevtoolsType<CR>
  au FileType haskell nnoremap <buffer> <silent> <F2> :HdevtoolsClear<CR>
" }

" Plugin Settings {
    let g:python3_host_prog = '/home/kondy/.pyenv/versions/neovim3/bin/python'
" " Fugitive {
    nnoremap <Leader>gc :Gcommit<CR>
    nnoremap <Leader>gs :Gstatus<CR>
    nnoremap <Leader>gd :Gdiff<CR>
    nnoremap <Leader>gb :Gblame<CR>
    nnoremap <Leader>gL :exe ':!cd ' . expand('%:p:h') . '; git la'<CR>
    nnoremap <Leader>gl :exe ':!cd ' . expand('%:p:h') . '; git las'<CR>
    nnoremap <Leader>gh :Silent Glog<CR>
    nnoremap <Leader>gH :Silent Glog<CR>:set nofoldenable<CR>
    nnoremap <Leader>gr :Gread<CR>
    nnoremap <Leader>gw :Gwrite<CR>
    nnoremap <Leader>gp :Git push<CR>
    nnoremap <Leader>g- :silent! Git stash<CR>:e<CR>
    nnoremap <Leader>g+ :silent! Git stash pop<CR>:e<CR>
" }
  " Airline {
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
  " }
  " FZF {
    " linewise completion
    imap <c-x><c-l> <plug>(fzf-complete-line)
    " Open file menu
    nnoremap <Leader>f :Files<CR>
    " Open git tracked files (git ls-files)
    nnoremap <Leader>o :GFiles<CR>
    " Open buffer menu
    nnoremap <Leader>b :Buffers<CR>
    " Open most recently used files
    nnoremap <Leader>c :Commits<CR>
  " }
  "vim-tmux-navigation {
    let g:tmux_navigator_no_mappings = 1
    nnoremap <silent> <A-h> :TmuxNavigateLeft<cr>
    nnoremap <silent> <A-j> :TmuxNavigateDown<cr>
    nnoremap <silent> <A-k> :TmuxNavigateUp<cr>
    nnoremap <silent> <A-l> :TmuxNavigateRight<cr>
    nnoremap <silent> <A-\> :TmuxNavigatePrevious<cr>
  "}
  "neo-ghc {
    let g:haskellmode_completion_ghc = 1
    autocmd FileType haskell setlocal omnifunc=necoghc#omnifunc
  "}
  " supertab {
    inoremap <Nul> <c-r>=SuperTabAlternateCompletion("\<lt>c-x>\<lt>c-o>"<cr>
    let g:SuperTabDefaultCompletionType = "<c-x><c-o>"
  " }
  " deoplete {
    let g:deoplete#enable_at_startup = 1
  " }
  " vim-json {
    let g:vim_json_syntax_conceal = 0
  " }
" }
