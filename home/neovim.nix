# todo: clean this whole file up. Been doing lots of hacking.
{ pkgs, ... }:

{
  # language servers
  home.packages = with pkgs; [
    terraform-ls

    dotnet-netcore

    # Node packages do not appear when running `nix search`. Use
    # `nix-env -qaPA nixos.nodePackages` to view them.`
    nodePackages.bash-language-server
  ];

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
      vim-which-key
      nvim-treesitter-context
      nvim-treesitter-refactor
      nvim-treesitter-textobjects

      # debugging
      nvim-dap # todo: learn how to use this
      nvim-dap-virtual-text # todo: learn how to use this

      # autocomplete
      completion-treesitter
      completion-buffers
      # https://github.com/kristijanhusak/completion-tags
      # https://github.com/kristijanhusak/vim-dadbod-completion


      vista-vim
      tmux-complete-vim # todo: replace with https://github.com/albertoCaroM/completion-tmux
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
      nvim-ts-rainbow # TreeSitter rainbow parens
      vim-surround # easy wrapping
      vim-easymotion # move easier
      tmux-complete-vim # completion from tmux windows
      vim-airline # status bar
      vim-airline-themes # status bar themes
      vim-hdevtools
      vim-nix # nix configuration
      vim-polyglot # A collection of language packs for Vim.
      vim-ps1
      vim-puppet
      vim-startify # some helpful links on the start screen
      vim-signature # show marks in gutter
      vim-terraform
      vim-test # invoke test runner
      vim-tmux-navigator # move between nvim and tmux
      vimproc-vim

    ];
    extraConfig = builtins.readFile ./init.vim;
  };
}
