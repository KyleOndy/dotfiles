{ ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/clojure.nix
    ./../../home/email.nix
    ./../../home/emacs.nix
    ./../../home/env.nix
    ./../../home/firefox.nix
    ./../../home/fonts.nix
    ./../../home/git.nix
    ./../../home/go.nix
    ./../../home/gpg.nix
    ./../../home/haskell.nix
    ./../../home/i3.nix
    ./../../home/neomutt.nix
    ./../../home/neovim.nix
    ./../../home/packages.nix
    ./../../home/python.nix
    ./../../home/tmux.nix
    ./../../home/zsh.nix
  ];


  programs = {
    home-manager = {
      enable = true;
    };
    lesspipe.enable = true;
  };

  services = {
    lorri.enable = true;
  };

}
