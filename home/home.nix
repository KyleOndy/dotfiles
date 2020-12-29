{ config, pkgs, ... }:
{
  #nixpkgs.config.allowUnfree = true;
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

  # import all the overlays that extend packages via nix or home-manager.
  # Overlays are a nix file within the `overlay` folder or a sub folder in
  # `overlay` that contains a `default.nix`.
  nixpkgs.overlays =
    let
      path = ./overlays;
    in
    with builtins;
    map (n: import (path + ("/" + n))) (
      filter
        (
          n:
          match ".*\\.nix" n != null
          || pathExists (path + ("/" + n + "/default.nix"))
        )
        (attrNames (readDir path))
    );

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
