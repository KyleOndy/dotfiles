# todo: clean this whole file up. Been doing lots of hacking.
{ pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    package = pkgs.neovim-nightly;
    withNodeJs = true; # enable node provider
    withPython3 = true;
    # these plugins can be found in `nixpkgs/pkgs/misc/vim-plugins`.
    plugins = with pkgs.vimPlugins; [
      # general language agnostic plugins
      nvim-treesitter
      nvim-lspconfig
      completion-nvim
      diagnostic-nvim
      completion-treesitter

      tmux-complete-vim
      vim-signify
      git-messenger-vim

      ack-vim # Run your favorite search tool from Vim, with an enhanced results list
      ale # linting of almost all languages
      editorconfig-vim # respect editorconfig
      float-preview-nvim # prettier previews
      fzf-vim # fuzzy file finder
      ghcmod-vim
      gruvbox # color scheme
      haskell-vim
      rainbow # easier matching of parans
      surround # easy wrapping
      tmux-complete-vim # completion from tmux windows
      jedi-vim # jedi for python
      vim-airline # status bar
      vim-airline-themes # status bar themes
      vim-clap # interactive finder and dispatcher,
      vim-hdevtools
      vim-nix # nix configuration
      vim-polyglot # A collection of language packs for Vim.
      vim-ps1
      vim-puppet
      vim-rooter # changes the working directory to the project root
      vim-signature # show marks in gutter
      vim-terraform
      vim-test # invoke test runner
      vim-tmux-navigator # move between nvim and tmux
      vimproc-vim

      # clojure plugins
      vim-clojure-highlight # Extend builtin syntax highlighting
      vim-clojure-static # Meikel Brandmeyer's Clojure runtime files
      vim-fireplace # Clojure REPL support
      vim-sexp # Precision Editing for S-expressions
      vim-sexp-mappings-for-regular-people # tpope to the rescue again
    ];
    extraConfig = builtins.readFile ./init.vim;
  };
}
