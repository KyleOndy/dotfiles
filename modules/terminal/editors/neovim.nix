{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.terminal.editors.neovim;
  inherit (pkgs) stdenv;
  inherit (lib) optionals;
in
{
  options.foundry.terminal.editors.neovim = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.tree-sitter ];
    programs.neovim = {
      enable = true;
      # will go back to the pkg on unstable once v0.5.x is released
      package = pkgs.neovim-nightly;
      withNodeJs = true; # enable node provider # todo: need this?
      withPython3 = true; # todo: need this?
      plugins = with pkgs.vimPlugins; [
        {
          # https://github.com/nvim-treesitter/nvim-treesitter
          plugin = nvim-treesitter;
          config = ''
            lua <<CFG
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
                    node_decremental = "grm"
                  }
                }
              }
            CFG
          '';
        }
        {
          # https://github.com/nvim-treesitter/nvim-treesitter-textobjects
          plugin = nvim-treesitter-textobjects;
          config = ''
            lua <<CFG
              require'nvim-treesitter.configs'.setup {
                textobjects = {
                  select = {
                    enable = true,
                    keymaps = {
                      -- You can use the capture groups defined in textobjects.scm
                      ["af"] = "@function.outer",
                      ["if"] = "@function.inner",
                      ["ac"] = "@class.outer",
                      ["ic"] = "@class.inner",
                    }
                  }
                }
              }
            CFG
          '';
        }
        {
          # https://github.com/nvim-treesitter/nvim-treesitter-refactor
          plugin = nvim-treesitter-refactor;
          config = ''
            lua <<CFG
              refactor = {
                highlight_definitions = { enable = true },
                highlight_current_scope = { enable = true },
                smart_rename = {
                  enable = true,
                  keymaps = {
                    smart_rename = "grr",
                  },
                },
                navigation = {
                  enable = true,
                  keymaps = {
                    goto_definition = "gnd",
                    list_definitions = "gnD",
                    list_definitions_toc = "gO",
                    goto_next_usage = "<a-*>",
                    goto_previous_usage = "<a-#>",
                  }
                }
              }
            CFG'';
        }
        {
          # https://github.com/nvim-lua/completion-nvim
          # the `completion-nvim` plugin is configued as part of
          # `nvim-lspconfig` below.
          plugin = completion-nvim;
          #config = ''
          #  lua <<CFG
          #    require'lspconfig'.clojure_lsp.setup{on_attach=require'completion'.on_attach}
          #  CFG
          #'';
        }
        {
          # https://github.com/neovim/nvim-lspconfig
          plugin = nvim-lspconfig;
          #config = ''
          #  lua <<CFG
          #    require'lspconfig'.clojure_lsp.setup{}
          #  CFG
          #'';
          config = ''
            lua <<CFG
              local nvim_lsp = require('lspconfig')
              local on_attach = function(client, bufnr)
                require('completion').on_attach()
                -- buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')
                -- todo: add mappings
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
                'pyright',
                'terraformls',
                'tsserver',
                -- 'vimls', -- no nix package
                'yamlls',
              }
              for _, lsp in ipairs(servers) do
                nvim_lsp[lsp].setup {
                  on_attach = on_attach,
                }
              end
            CFG

            " Completion
            let g:completion_matching_strategy_list = ['exact', 'substring', 'fuzzy']
            inoremap <expr> <Tab>   pumvisible() ? "\<C-n>" : "\<Tab>"
            inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"
          '';
        }


        # https://github.com/romgrk/nvim-treesitter-context
        nvim-treesitter-context

        # https://github.com/mfussenegger/nvim-dap
        nvim-dap # todo: learn how to use this

        # https://github.com/theHamsta/nvim-dap-virtual-text
        nvim-dap-virtual-text # todo: learn how to use this

        # https://github.com/rhysd/git-messenger.vim
        git-messenger-vim

        {
          plugin = vim-easymotion;
          config = ''
            let g:EasyMotion_do_mapping = 0 " Disable default mappings
            let g:EasyMotion_smartcase = 1

            " todo: add leader bindings back
          '';
        }

        { plugin = aniseed; }

        {
          # https://github.com/dense-analysis/ale
          plugin = ale; # linting of almost all languages
          # I'm not sure how to split the config for plugins that span
          # multipule plugins.
          config = ''
            autocmd ColorScheme * highlight ALEWarning ctermbg=DarkMagenta guibg=DarkMagenta
            let g:ale_linters = {
                  \ 'gitcommit': ['proselint'],
                  \ 'clojure': ['clj-kondo']
                  \}
          '';
        }

        # https://github.com/editorconfig/editorconfig-vim
        editorconfig-vim # respect editorconfig

        # https://github.com/p00f/nvim-ts-rainbow
        nvim-ts-rainbow # TreeSitter rainbow parens

        # https://github.com/tpope/vim-surround
        vim-surround # easy wrapping

        {
          # https://github.com/hoob3rt/lualine.nvim
          plugin = lualine-nvim; # status bar
          # the config was modified from https://gist.githubusercontent.com/hoob3rt/b200435a765ca18f09f83580a606b878/raw/d99388470ed5ddb1da32a0bd3bccd4a69eb15429/evil_lualine.lua
          config = ''
            lua <<CFG
              require('lualine').setup{
                options = {
                  icons_enabled = true,
                  theme = 'gruvbox',
                  component_separators = {'', ''},
                  section_separators = {'', ''},
                  disabled_filetypes = {}
                },
                sections = {
                  lualine_a = {'mode'},
                  lualine_b = {'branch'},
                  lualine_c = {'filename', 'diagnostics'},
                  lualine_x = {'encoding', 'fileformat', 'filetype'},
                  lualine_y = {'progress'},
                  lualine_z = {'location'}
                },
                inactive_sections = {
                  lualine_a = {},
                  lualine_b = {},
                  lualine_c = {'filename'},
                  lualine_x = {'location'},
                  lualine_y = {},
                  lualine_z = {}
                },
                tabline = {},
                extensions = {'fugitive'}
              }
            CFG
          '';
        }
        # https://github.com/vim-airline/vim-airline-themes
        # this is used in the `vim-airline` plugin
        vim-airline-themes # status bar themes

        {
          # https://github.com/kyazdani42/nvim-web-devicons
          # pretty icons in terminal
          plugin = nvim-web-devicons;
          config = ''
            lua <<CFG
              require'nvim-web-devicons'.setup {}
            CFG
          '';
        }
        {
          # https://github.com/christoomey/vim-tmux-navigator
          plugin = vim-tmux-navigator; # move between nvim and tmux
          config = ''
            " do not use the default mappings
            let g:tmux_navigator_no_mappings = 1
            nnoremap <silent> <A-h> :TmuxNavigateLeft<cr>
            nnoremap <silent> <A-j> :TmuxNavigateDown<cr>
            nnoremap <silent> <A-k> :TmuxNavigateUp<cr>
            nnoremap <silent> <A-l> :TmuxNavigateRight<cr>
            nnoremap <silent> <A-\> :TmuxNavigatePrevious<cr>
          '';
        }

        # https://github.com/wellle/tmux-complete.vim
        tmux-complete-vim # needed for tmux completion with compe

        {
          # https://github.com/hrsh7th/nvim-compe
          plugin = nvim-compe;
          config = ''
            lua <<CFG
            vim.o.completeopt = "menuone,noselect"

            require'compe'.setup {
              enabled = true;
              autocomplete = true;
              debug = false;
              min_length = 1;
              preselect = 'enable';
              throttle_time = 80;
              source_timeout = 200;
              incomplete_delay = 400;
              max_abbr_width = 100;
              max_kind_width = 100;
              max_menu_width = 100;
              documentation = true;

              source = {
                buffer = true;
                calc = true;
                conjure = true;
                nvim_lsp = true;
                nvim_lua = true;
                path = true;
                tmux = true;
                vsnip = true;
              };
            }
            CFG
          '';
        }
        {
          # https://github.com/nvim-telescope/telescope.nvim
          plugin = telescope-nvim;
          config = ''
            lua <<CFG
              require('telescope').setup{
                file_sorter =  require'telescope.sorters'.get_fzy_sorter,
              }
            CFG
            " todo: add leader bindings back
          '';
        }
        {
          # https://github.com/nvim-telescope/telescope-fzy-native.nvim
          plugin = telescope-fzy-native-nvim;
          config = ''
            lua <<CONFIG
              require('telescope').load_extension('fzy_native')
            CONFIG
          '';
        }
        # these two plugins are required by telescope.
        plenary-nvim
        popup-nvim

        {
          # https://github.com/ThePrimeagen/git-worktree.nvim
          plugin = git-worktree-nvim;
          config = ''
            lua <<CFG
            require("git-worktree").setup({})
            require("telescope").load_extension("git_worktree")
            CFG
          '';
        }

        {
          # https://github.com/lewis6991/gitsigns.nvim
          plugin = gitsigns-nvim;
          config = ''
            lua <<CFG
            require('gitsigns').setup {
              -- there is some colorscheme issue with this. The "virtual text"
              -- is not in the subtle color, its stark white. Running
              -- `:colorscheme gruvbox` fixes it, but that is annyotinh.
              current_line_blame = false,
            }
            CFG
          '';
        }

        {
          # https://github.com/tpope/vim-fugitive
          plugin = vim-fugitive;
          config = ''
            " todo: add leader bindings back
          '';
        }
        {
          # https://github.com/shumphrey/fugitive-gitlab.vim
          # broser current file in GitLab webUI with :GBrowse
          plugin = fugitive-gitlab-vim;
          config = ''
            let g:fugitive_gitlab_domains = ['https://gitlab.paigeai.net']
          '';
        }
        {
          # https://github.com/tpope/vim-rhubarb
          # broser current file in GitHub webUI with :GBrowse
          plugin = vim-rhubarb;
        }

        # https://github.com/folke/which-key.nvim
        {
          plugin = which-key-nvim;
          config = ''
            lua <<CFG
              require("which-key").setup { }
            CFG
          '';
        }

        # still need original gruvbox for the airline theme until gruvbox-nvim
        # supports its.
        #
        # [1]: https://github.com/npxbr/gruvbox.nvim/issues/19
        gruvbox

        {
          # I've moved to a fork of gruvbox [1] that better supports neovim
          # 0.5.0 features, most notably treesitter.
          #
          # [1]: https://github.com/npxbr/gruvbox.nvim
          # [2]: https://github.com/morhetz/gruvbox
          plugin = gruvbox-nvim;
          config = ''
            " I really like dark and warm color schemes. I used to rock a fork of
            " Wombat256 [1]. Gruvbox [2] is 90% of where I want to be, and its available
            " for everything via the contrib repo [3]. Given that, I've learned to live
            " with almost perfect due to the amount of work it would take to make my own
            " color scheme. However, since I am running neovim 0.5.x, I am
            " currently using gruvbox.nvim [4], which better supports new
            " features. I hope that gruvbox proper will intergate these features
            " in the future.
            "
            " [1] https://github.com/KyleOndy/wombat256mod
            " [2] https://github.com/morhetz/gruvbox
            " [3] https://github.com/morhetz/gruvbox-contrib
            " [4] https://github.com/npxbr/gruvbox.nvim
            colorscheme gruvbox
            set background=dark

            " pretty sure this is the default
            let gruvbox_contrast_dark = 'medium'

            " when in light mode, I am probably outside, and need the contract cranked to 11.
            let g:gruvbox_contrast_light = 'hard'

            " getting hacky, want to set colorscheme after everything else has loaded.
            " autocmd BufEnter * colorscheme gruvbox
          '';
        }
      ];

      # lots of config... This is the balance of the configuration that does
      # not apply to any single plugin, and is core neovim.
      extraConfig = ''
        " Map the leader key to space. Easy to reach with either hand and
        " shouldn't clobber other applications control sequences. Need to be
        " mindful of tmux's leader (currently <C-Space>) since neovim is very
        " often run within a tmux session.
        let mapleader="\<SPACE>"

        " I didn't really have a strong first choice for localleader, so I
        " chose `,` arbitrarily. localleader is used to have different
        " implementations for a function depending on file type.
        let maplocalleader=","

        " 'Ex mode is fucking dumb' --sircmpwm
        " I have never intentionally entered Ex mode, make it a NOP.
        nnoremap Q <Nop>

        " prettier colors
        set termguicolors

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
        autocmd ColorScheme * highlight ExtraWhitespace ctermbg=darkgreen guibg=darkgreen | match ExtraWhitespace /\s\+$\|\t/

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

        " HACK! I need to learn the right way to do this. NixOS is loading the
        " colorscheme after init.vim, so these get overrideen. checkout
        " :scriptnames

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

        " use jk to exit insert mode. Escape key is a far reach.
        inoremap jk <Esc>`^
        " Stop cursor from jumping over wrapped lines
        nnoremap j gj
        nnoremap k gk
        " Make HOME and END behave like shell
        inoremap <C-E> <End>
        inoremap <C-A> <Home>
        nmap <Leader>w :w<CR>

        " # work with terminal
        " make the cursor red. Stands out more
        highlight TermCursor ctermfg=red
        nmap <silent> <leader>th :new<CR>:terminal<CR>
        nmap <silent> <leader>tt :terminal<CR>
        nmap <silent> <leader>tv :vnew<CR>:terminal<CR>
        nmap <silent> <leader>tb :enew<CR>:terminal<CR>
        tnoremap <leader><ESC> <C-\><C-n>
        tnoremap <leader>jk <C-\><C-n>

        " enable cursorline so we can color it
        set cursorline
        " Set the line number background coloring to dark gray
        autocmd ColorScheme * highlight CursorLineNr ctermbg=DarkRed guibg=DarkRed
        " do not highlight the line itslef
        autocmd ColorScheme * highlight CursorLine ctermbg=NONE guibg=NONE

        " ## languageclient
        let g:LanguageClient_autoStart = 1

        nnoremap <F5> :call LanguageClient_contextMenu()<CR>

        " automatically highlight the word we are seaching for
        let g:ackhighlight = 1

        "Copy and paste from system clipboard
        vmap <Leader>y "+y
        vmap <Leader>d "+d
        nmap <Leader>p "+p
        nmap <Leader>P "+P
        vmap <Leader>p "+p
        vmap <Leader>P "+P

        " todo: enable only in mergetool?
        nmap <Leader>dv :Gvdiffsplit!<CR>
        nmap <Leader>du :diffupdate<CR>
        nmap <Leader>dh :diffget //2<CR>
        nmap <Leader>dl :diffget //3<CR>

        " Plugin kepmaps
        " these are temparary, until nixos + neovim plugin config get sorted
        " ==> telescope
        " Find files using Telescope command-line sugar.
        nnoremap <leader>ob <cmd>Telescope buffers<cr>
        nnoremap <leader>of <cmd>Telescope find_files<cr>
        nnoremap <leader>od <cmd>Telescope file_browser<cr>

        nnoremap <leader>oo <cmd>Telescope git_files<cr>
        nnoremap <leader>op <cmd>Telescope man_pages<cr>
        nnoremap <leader>om <cmd>Telescope marks<cr>

        nnoremap <leader>ss <cmd>Telescope live_grep<cr>
        nnoremap <leader>sa <cmd>Telescope grep_string<cr>
        nnoremap <leader>s/ <cmd>Telescope current_buffer_fuzzy_find<cr>

        " ==> fugitive
        nmap <Leader>gg :tab Git<CR>
        nmap <Leader>gb :GBrowse<CR>
        vmap <Leader>gb :GBrowse<CR> " goes to line number!

        " ==> EasyMotion
        " JK motions: Line motions
        " map <Leader>sj <Plug>(easymotion-j)
        " map <Leader>sk <Plug>(easymotion-k)
        nmap <leader>ff <Plug>(easymotion-overwin-f2)
      '';
    };
  };
}
