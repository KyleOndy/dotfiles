{ lib, pkgs, config, ... }:
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
      plugins = with pkgs.vimPlugins; [
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
          config = ''
          '';
        }

        {
          plugin = undotree;
          config = ''
            nnoremap <leader>u :UndotreeToggle<CR>
            let g:undotree_SetFocusWhenToggle = 1
          '';
        }

        {
          # Installing tree-sitter via neovims built in tooling is not a great
          # idea within nix, and not very reproducible. Luckily, we can install
          # all the grammars like everything else.
          #
          # https://github.com/nvim-treesitter/nvim-treesitter
          # https://nixos.org/manual/nixpkgs/unstable/#managing-plugins-with-vim-packages
          plugin = nvim-treesitter.withPlugins (plugins: pkgs.tree-sitter.allGrammars);
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

        # https://github.com/mfussenegger/nvim-dap
        nvim-dap # todo: learn how to use this

        # https://github.com/theHamsta/nvim-dap-virtual-text
        nvim-dap-virtual-text # todo: learn how to use this

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
        { plugin = cmp-conjure; }
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


        # https://github.com/p00f/nvim-ts-rainbow
        nvim-ts-rainbow # TreeSitter rainbow parens

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
          # https://github.com/nvim-telescope/telescope.nvim
          plugin = telescope-nvim;
          config = ''
            lua <<CFG
              require('telescope').setup{
                file_sorter =  require'telescope.sorters'.get_fzy_sorter,
              }
            CFG
            " Find files using Telescope command-line sugar.

            " open / move to
            nnoremap <leader>ob <cmd>Telescope buffers<cr>
            nnoremap <leader>of <cmd>Telescope find_files<cr>
            nnoremap <leader>od <cmd>Telescope file_browser<cr>
            nnoremap <leader>ot <cmd>Telescope help_tags<cr>

            nnoremap <leader>oo <cmd>Telescope git_files<cr>
            nnoremap <leader>op <cmd>Telescope man_pages<cr>
            nnoremap <leader>om <cmd>Telescope marks<cr>

            " search
            nnoremap <leader>ss <cmd>Telescope live_grep<cr>
            nnoremap <leader>sa <cmd>Telescope grep_string<cr>
            nnoremap <leader>s/ <cmd>Telescope current_buffer_fuzzy_find<cr>

            " insert
            nnoremap <leader>is <cmd>Telescope symbols<cr>
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
          # https://github.com/ThePrimeagen/git-worktree.nvim
          plugin = git-worktree-nvim;
          config = ''
            lua <<CFG
            require("git-worktree").setup({})
            require("telescope").load_extension("git_worktree")
            CFG

            nmap <silent> <leader>ww :lua require('telescope').extensions.git_worktree.git_worktrees()<cr>
            nmap <silent> <leader>wc :lua require('telescope').extensions.git_worktree.create_git_worktree()<cr>
          '';
        }

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
          config = ''
            nmap <Leader>gg :tab Git<CR>
            nmap <Leader>gb :GBrowse<CR>
            vmap <Leader>gb :GBrowse<CR> " goes to line number!
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
      ];

      # See the comment for the first plugin as to why this is not configured.
      extraConfig = ''
      '';
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
      netboot
      NixOS
      nixpkgs
      nvme
      pixicore
      pkgs
      plugin
      plugins
      precommit
      pxe
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
