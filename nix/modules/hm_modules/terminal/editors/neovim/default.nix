{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.editors.neovim;
  inherit (pkgs) stdenv;
  inherit (lib) optionals;
in
{
  options.hmFoundry.terminal.editors.neovim = {
    enable = mkEnableOption "todo";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # language servers
      gopls
      vscode-ls
      yaml-language-server
    ];
    programs.neovim = {
      enable = true;
      withNodeJs = true; # enable node provider # todo: need this?
      withPython3 = true; # todo: need this?
      plugins =
        with pkgs.vimPlugins;
        [
          # TODO: confrim if true
          # the built config follows the order of the plugins in this array.

          # Do to a bug/regression in the order the plugin configuration and the
          # general configuration is applied we need to prepend our configuration
          # to the first plugin. I could make a nop plugin to make this more
          # clear.
          #
          # https://github.com/nix-community/home-manager/pull/2391#issuecomment-988099479

          {
            # todo: make a vim-nop or nop-nvim plugin, to learn
            # todo: convert to lua, or is that just trendy?
            plugin = pkgs.hello; # could be anything
            config = builtins.readFile ./config/nvimrc;
          }

          {
            # https://github.com/editorconfig/editorconfig-vim
            plugin = editorconfig-vim; # respect editorconfig
            config = '''';
          }

          {
            plugin = undotree;
            config = ''
              nnoremap <leader>u :UndotreeToggle<CR>
              let g:undotree_SetFocusWhenToggle = 1
            '';
          }

          {
            # https://github.com/nvim-telescope/telescope.nvim
            plugin = telescope-nvim;
            type = "lua";
            config = ''
              require('telescope').setup{
                file_sorter =  require'telescope.sorters'.get_fzy_sorter,
              }

              require("which-key").add({
                { "<leader>i", group = "insert" },
                { "<leader>is", "<cmd>Telescope symbols<cr>", desc = "Insert symbol" },
                { "<leader>o", group = "open" },
                { "<leader>ob", "<cmd>Telescope buffers<cr>", desc = "Open Buffer" },
                { "<leader>of", "<cmd>Telescope find_files<cr>", desc = "Open File" },
                { "<leader>ok", "<cmd>Telescope keymaps<cr>", desc = "Open Keymaps" },
                { "<leader>om", "<cmd>Telescope marks<cr>", desc = "Open Marks" },
                { "<leader>on", "<cmd>enew<cr>", desc = "New File" },
                { "<leader>oo", "<cmd>Telescope git_files<cr>", desc = "Open Git Files" },
                { "<leader>op", "<cmd>Telescope man_pages<cr>", desc = "Open Man Pages" },
                { "<leader>or", "<cmd>Telescope oldfiles<cr>", desc = "Open Recent File" },
                { "<leader>ot", "<cmd>Telescope help_tags<cr>", desc = "Open Tags" },
                { "<leader>s", group = "search" },
                { "<leader>s/", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "Search buffer" },
                { "<leader>sa", "<cmd>Telescope grep_string<cr>", desc = "Search word under cursor" },
                { "<leader>ss", "<cmd>Telescope live_grep<cr>", desc = "Search Live Grep" },


              })
            '';
          }

          {
            # Installing tree-sitter via neovims built in tooling is not a great
            # idea within nix, and not very reproducible. Luckily, we can install
            # all the grammars like everything else.
            #
            # https://github.com/nvim-treesitter/nvim-treesitter
            # https://nixos.org/manual/nixpkgs/unstable/#managing-plugins-with-vim-packages
            plugin = nvim-treesitter.withAllGrammars;
            type = "lua";
            config = builtins.readFile ./config/treesitter.lua;
          }

          {
            # https://github.com/nvim-treesitter/nvim-treesitter-refactor
            plugin = nvim-treesitter-refactor;
            type = "lua";
            config = builtins.readFile ./config/treesitter_refactor.lua;
          }
          {
            # https://github.com/neovim/nvim-lspconfig
            plugin = nvim-lspconfig;
            type = "lua";
            config = builtins.readFile ./config/lspconfig.lua;
          }

          # https://github.com/romgrk/nvim-treesitter-context
          nvim-treesitter-context

          {
            # https://github.com/mfussenegger/nvim-dap
            plugin = nvim-dap; # todo: learn how to use this
            type = "lua";
            config = builtins.readFile ./config/dap.lua;
          }

          {
            # https://github.com/rcarriga/nvim-dap-ui
            plugin = nvim-dap-ui;
            type = "lua";
            config = ''
              require("dapui").setup()

              local dap, dapui = require("dap"), require("dapui")
              dap.listeners.after.event_initialized["dapui_config"] = function()
                dapui.open()
              end
              dap.listeners.before.event_terminated["dapui_config"] = function()
                dapui.close()
              end
              dap.listeners.before.event_exited["dapui_config"] = function()
                dapui.close()
              end
            '';
          }

          {
            # https://github.com/nvim-telescope/telescope-dap.nvim
            plugin = telescope-dap-nvim;
            type = "lua";
            config = ''
              require('telescope').load_extension('dap')
            '';
          }

          {
            # https://github.com/theHamsta/nvim-dap-virtual-text
            plugin = nvim-dap-virtual-text;
            type = "lua";
            config = ''
              require("nvim-dap-virtual-text").setup()
            '';
          }

          # https://github.com/rhysd/git-messenger.vim
          git-messenger-vim

          {
            plugin = vim-easymotion;
            config = builtins.readFile ./config/easymotion.vim;
          }

          {
            # https://github.com/hrsh7th/nvim-cmp
            plugin = nvim-cmp;
            type = "lua";
            config = builtins.readFile ./config/cmp.lua;
          }

          # https://github.com/hrsh7th/cmp-buffer
          { plugin = cmp-buffer; }
          { plugin = cmp-cmdline-history; }
          { plugin = cmp-cmdline; }
          { plugin = cmp-dictionary; }
          { plugin = cmp-nvim-lsp; }
          { plugin = cmp-rg; }
          { plugin = cmp-tmux; }

          {
            # https://github.com/dense-analysis/ale
            plugin = ale; # linting of almost all languages
            # I'm not sure how to split the config for plugins that span
            # multipule plugins.
            config = builtins.readFile ./config/ale.vim;
          }

          # https://github.com/hiphish/rainbow-delimiters.nvim
          rainbow-delimiters-nvim # TreeSitter rainbow parens

          # https://github.com/tpope/vim-surround
          vim-surround # easy wrapping

          {
            # https://github.com/hoob3rt/lualine.nvim
            plugin = lualine-nvim; # status bar
            # the config was modified from https://gist.githubusercontent.com/hoob3rt/b200435a765ca18f09f83580a606b878/raw/d99388470ed5ddb1da32a0bd3bccd4a69eb15429/evil_lualine.lua
            type = "lua";
            config = builtins.readFile ./config/lualine.lua;
          }

          {
            # https://github.com/kyazdani42/nvim-web-devicons
            # pretty icons in terminal
            plugin = nvim-web-devicons;
            type = "lua";
            config = ''
              require'nvim-web-devicons'.setup {}
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

          {
            # https://github.com/nvim-telescope/telescope-fzy-native.nvim
            plugin = telescope-fzy-native-nvim;
            config = ''
              lua <<CONFIG
                require('telescope').load_extension('fzy_native')
              CONFIG
            '';
          }
          # extend telescope
          telescope-symbols-nvim

          # these two plugins are required by telescope.
          plenary-nvim
          popup-nvim

          {
            # https://github.com/lewis6991/gitsigns.nvim
            plugin = gitsigns-nvim;
            config = ''
              lua <<CFG
              require('gitsigns').setup {
                current_line_blame = true,
              }
              CFG
            '';
          }

          {
            # https://github.com/tpope/vim-fugitive
            plugin = vim-fugitive;
            type = "lua";
            config = ''
              require("which-key").add({
                { "<leader>g", group = "git" },
                { "<leader>gg", "<cmd>tab Git<cr>", desc = "Git status" },
                { "<leader>gb", "<cmd>GBrowse<cr>", desc = "Browse file/selection in browser", mode = { "n", "v" } },
                { "<leader>gB", "<cmd>GBrowse!<cr>", desc = "Copy file/selection URL to clipboard", mode = { "n", "v" } },
                { "<leader>gp", "<cmd>Git push<cr>", desc = "Git push" },
              })
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
            type = "lua";
            config = ''
              require("which-key").setup { }
            '';
          }

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
            '';
          }

          {
            # https://github.com/vim-test/vim-test
            plugin = vim-test;
            config = ''
              nmap <silent> <leader>tn :TestNearest<CR>
              nmap <silent> <leader>tf :TestFile<CR>
              nmap <silent> <leader>ts :TestSuite<CR>
              nmap <silent> <leader>tl :TestLast<CR>
              nmap <silent> <leader>tg :TestVisit<CR>
            '';
          }

          {
            # https://github.com/jamessan/vim-gnupg
            plugin = vim-gnupg;
            config = '''';
          }

          {
            # https://github.com/towolf/vim-helm
            plugin = vim-helm;
            config = ''
              autocmd FileType helm lua vim.diagnostic.disable(0)
            '';
          }

          {
            # https://github.com/lukas-reineke/indent-blankline.nvim
            plugin = indent-blankline-nvim;
            type = "lua";
            config = ''
              --vim.opt.termguicolors = true
              --vim.cmd [[highlight IndentBlanklineIndent1 guifg=#cc241d gui=nocombine]]
              --vim.cmd [[highlight IndentBlanklineIndent2 guifg=#d79921 gui=nocombine]]
              --vim.cmd [[highlight IndentBlanklineIndent3 guifg=#458588 gui=nocombine]]
              --vim.cmd [[highlight IndentBlanklineIndent4 guifg=#98971a gui=nocombine]]
              --vim.cmd [[highlight IndentBlanklineIndent5 guifg=#b16286 gui=nocombine]]
              --vim.cmd [[highlight IndentBlanklineIndent6 guifg=#689d6a gui=nocombine]]

              --vim.opt.list = true
              ---- vim.opt.listchars:append "space:⋅"
              ---- vim.opt.listchars:append "eol:↴"

              --require("indent_blankline").setup {
              --    space_char_blankline = " ",
              --    show_current_context = false,
              --    show_current_context_start = false,
              --    char_highlight_list = {
              --        "IndentBlanklineIndent1",
              --        "IndentBlanklineIndent2",
              --        "IndentBlanklineIndent3",
              --        "IndentBlanklineIndent4",
              --        "IndentBlanklineIndent5",
              --        "IndentBlanklineIndent6",
              --    },
              --}
            '';
          }

          {
            # https://github.com/chentoast/marks.nvim
            plugin = marks-nvim;
            type = "lua";
            config = ''
              require'marks'.setup {};
            '';
          }

          # https://github.com/GEverding/vim-hocon
          {
            plugin = vim-hocon;
          }

          # https://github.com/ggml-org/llama.vim
          {
            plugin = llama-vim;
            type = "lua";
            config = '''';
          }

        ]
        ++

          optionals config.hmFoundry.dev.clojure.enable [
            # https://github.com/Olical/conjure
            # "conversational software development"
            {
              plugin = conjure;
              type = "vim";
              config = ''
                let g:conjure#mapping#doc_word = "K"

                -- Width of HUD as percentage of the editor width between 0.0 and 1.0. Default: `0.42`
                let g:conjure#log#hud#width = 1,

                -- Display HUD (REPL log). Default: `true`
                let g:conjure#log#hud#enabled = false,

                -- HUD corner position (over-ridden by HUD cursor detection). Default: `"NE"`
                -- Example: Set to `"SE"` and HUD width to `1.0` for full width HUD at bottom of screen
                let g:conjure#log#hud#anchor = "SE",

                -- Open log at bottom or far right of editor, using full width or height. Default: `false`
                let g:conjure#log#botright = true,

                -- Lines from top of file to check for `ns` form, to sett evaluation context Default: `24`
                -- `b:conjure#context` to override a specific buffer that isn't finding the context
                let g:conjure#extract#context_header_lines = 100,

                -- comment pattern for eval to comment command
                let g:conjure#eval#comment_prefix = ";; ",

                -- Hightlight evaluated forms
                let g:conjure#highlight#enabled = true,

                -- Start "auto-repl" process when nREPL connection not found, e.g. babashka. ;; Default: `true`
                let g:conjure#client#clojure#nrepl#connection#auto_repl#enabled = false,

                -- Hide auto-repl buffer when triggered. Default: `false`
                let g:conjure#client#clojure#nrepl#connection#auto_repl#hidden = true,

                -- Command to start the auto-repl. Default: `"bb nrepl-server localhost:8794"`
                let g:conjure#client#clojure#nrepl#connection#auto_repl#cmd = nil,

                -- Ensure namespace required after REPL connection. Default: `true`
                let g:conjure#client#clojure#nrepl#eval#auto_require = false,

                -- suppress `; (out)` prefix in log evaluation results
                let g:conjure#client#clojure#nrepl#eval#raw_out = true,

                -- test runner "clojure" (clojure.test) "clojurescript" (cljs.test) "kaocha"
                let g:conjure#client#clojure#nrepl#test#runner = "clojure",

                -- https://github.com/Olical/conjure/issues/609#issuecomment-2375618354
                aug my_bb | au! | autocmd my_bb BufNewFile,BufRead *.bb setlocal filetype=clojure
              '';
            }
          ];

      # See the comment for the first plugin as to why this is not configured.
      extraConfig = '''';
    };
    xdg.configFile."nvim/spell/shared.en.utf-8.add".text = ''
      AWS
      Clojure
      darwin
      fixup
      initramfs
      inline
      inode
      inotify
      MUA
      Neovim
      NixOS
      nixpkgs
      nvme
      pixicore
      pkgs
      plugin
      plugins
      precommit
      ramroot
      rebase
      Reusability
      sd
      Terraform
      todo
      urls
      vim
      zsh
    '';
  };
}
