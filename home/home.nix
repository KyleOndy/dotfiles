{ config, pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./clojure.nix
    ./email.nix
    ./emacs.nix
    ./env.nix
    ./firefox.nix
    ./fonts.nix
    ./git.nix
    ./go.nix
    ./gpg.nix
    ./haskell.nix
    ./i3.nix
    ./neomutt.nix
    ./neovim.nix
    ./packages.nix
    ./python.nix
    ./tmux.nix
    ./zsh.nix
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
