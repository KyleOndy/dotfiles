filetype off
if has('vim_starting')
  set runtimepath+=~/.vim/bundle/neobundle.vim/
  if !isdirectory(expand('~/.vim/bundle/neobundle.vim'))
    echo "Installing NeoBundle\n"
    silent execute '!mkdir -p ~/.vim/bundle'
    silent execute '!git clone https://github.com/Shougo/neobundle.vim ~/.vim/bundle/neobundle.vim'
  endif
endif
call neobundle#begin(expand('~/.vim/bundle/'))
NeoBundleFetch "Shougo/neobundle.vim"
" Plugins
NeoBundle 'KyleOndy/wombat256mod'
NeoBundle 'scrooloose/syntastic'
NeoBundle 'altercation/vim-colors-solarized'
NeoBundle 'vim-pandoc/vim-pandoc-syntax'
call neobundle#end()

NeoBundleCheck
filetype plugin indent on
syntax on

"-------------------------------------------------------------
" Use Vim settings, rather then Vi settings (much better!).
"-------------------------------------------------------------
set nocompatible

"-------------------------------------------------------------
" General Config
"-------------------------------------------------------------

set backspace=indent,eol,start  "Allow backspace in insert mode
set history=1000                "Store lots of :cmdline history
set showcmd                     "Show incomplete cmds down the bottom
set showmode                    "Show current mode down the bottom
set number                      "Show line numbers
set gcr=a:blinkon0              "Disable cursor blink
set visualbell                  "No sounds
set autoread                    "Reload files changed outside vim
set guioptions=                 "Disables all gui options
set numberwidth=4               "line numbering takes up 5 spaces
set laststatus=2                "Makes status bar two line high
"set cursorline                 "Highlights current line
"set cursorcolumn               "Highlights current column
set colorcolumn=80              "Colored line at 80 characters
set t_Co=256                    "Force 256 colors
colors wombat256mod             "Wombat Color Scheme
set list
"set spell spelllang=en_us      "Spell check, I do need it. Lots.

" This makes vim act like all other editors, buffers can
" exist in the background without being in a window.
" http://items.sjbach.com/319/configuring-vim-right
set hidden

"turn on syntax highlighting
syntax on

"-------------------------------------------------------------
" Key Mappings
"-------------------------------------------------------------

let mapleader=","               " change the mapleader from \ to ,

"-------------------------------------------------------------
" Search Settings
"-------------------------------------------------------------

set incsearch                   "Find the next match as we type the search
set hlsearch                    "Highlight searches by default
set viminfo='100,f1             "Save up to 100 marks, enable capital marks
set wildmode=list:longest       "make cmdline tab completion similar to bash
set wildmenu                    "enable ctrl-n and ctrl-p to scroll thru matches
set wildignore=*.o,*.obj,*~     "stuff to ignore when tab completing"


"-------------------------------------------------------------
" Swap File
"-------------------------------------------------------------

set noswapfile                  " Turn off swapfile
set nobackup
set nowb

"-------------------------------------------------------------
" Persistent Undo
"
" Keep undo history across sessions, by storing in file.
" Only works all the time.
"-------------------------------------------------------------

silent !mkdir ~/.vim/backups > /dev/null 2>&1
set undodir=~/.vim/backups
set undofile

"-------------------------------------------------------------
" Indentation and line apperance
"-------------------------------------------------------------

set autoindent
set smartindent
set smarttab
set shiftwidth=4
set softtabstop=4
set tabstop=4
set expandtab

filetype plugin on
filetype indent on

" Display tabs and trailing spaces visually
set list listchars=tab:\ \ ,trail:·

set nowrap                      "Don't wrap lines
set linebreak                   "Wrap lines at convenient points

"-------------------------------------------------------------
" Folds
"-------------------------------------------------------------

set foldmethod=indent           "fold based on indent
set foldnestmax=3               "deepest fold is 3 levels
set nofoldenable                "don't fold by default

"-------------------------------------------------------------
" Scrolling
"-------------------------------------------------------------

set scrolloff=8                 "Start scrolling when we're 8 lines away from margins
set sidescrolloff=15
set sidescroll=1

"-------------------------------------------------------------
" Learning
"
" To prevent me from learning bad habits.
"-------------------------------------------------------------

" Disable arrow keys.
map <up> <nop>
map <down> <nop>
map <left> <nop>
map <right> <nop>

" Quickly edit/reload the vimrc file
nmap <silent> <leader>ev :e $MYVIMRC<CR>
nmap <silent> <leader>sv :so $MYVIMRC<CR>
