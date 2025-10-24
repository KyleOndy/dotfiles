# nixCats category definitions - what plugins/LSPs belong to each category
# This function is used by nixCats to determine which packages to include
# based on the categories enabled in packages.nix
{
  pkgs,
  settings,
  categories,
  name,
  ...
}:
{
  lspsAndRuntimeDeps = {
    general = with pkgs; [
      # Language servers
      gopls
      clojure-lsp
      yaml-language-server
      nixd # Nix language server (feature-rich, nixpkgs-aware)
      # Alternative: nil (faster but limited nixpkgs docs)
      lua-language-server # Lua LSP (for neovim config)
      # Tools
      ripgrep
      fd
    ];
  };

  startupPlugins = {
    general = with pkgs.vimPlugins; [
      # Color scheme
      gruvbox-nvim
      # Essential UI
      nvim-web-devicons
      lualine-nvim
      nvim-treesitter-context
      rainbow-delimiters-nvim
      # Tree-sitter with specific grammars
      (nvim-treesitter.withPlugins (p: [
        p.nix
        p.bash
        p.markdown
        p.json
        p.lua
        p.clojure
        p.rust
        p.python
        p.terraform
        p.go
        p.yaml
        p.vim
        p.toml
        p.make
        p.dockerfile
        p.gitignore
        p.regex
        p.diff
        p.git_rebase
        p.comment
      ]))
      # Fuzzy finder
      telescope-nvim
      telescope-fzy-native-nvim
      telescope-symbols-nvim
      plenary-nvim
      popup-nvim
      # LSP
      nvim-lspconfig
      # Completion
      nvim-cmp
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      cmp-cmdline
      cmp-cmdline-history
      cmp-tmux
      cmp-rg
      cmp-dictionary
      # Git
      vim-fugitive
      vim-rhubarb
      gitsigns-nvim
      git-messenger-vim
      # Editing
      vim-surround
      editorconfig-vim
      vim-easymotion
      marks-nvim
      # Linting
      ale
      # Testing
      vim-test
      # Debugging (DAP)
      nvim-dap
      nvim-dap-ui
      telescope-dap-nvim
      nvim-dap-virtual-text
      # Clojure
      conjure
      # Tmux integration
      vim-tmux-navigator
      # File type support
      vim-gnupg
      vim-helm
      vim-hocon
      # UI
      which-key-nvim
    ];
  };

  optionalPlugins = {
    # For lazy loading later
  };
}
