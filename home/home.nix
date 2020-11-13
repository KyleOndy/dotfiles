{ ... }:
let
  sources = import ../nix/sources.nix;
  home-manager = import sources.home-manager { };
in
# This is the entrypoint for home-manager. This file should mainly be to import
  # other more specific files

{
  nixpkgs.config.allowUnfree = true;
  # import each nix file into home-manager
  imports = [
    ./clojure.nix
    ./email.nix
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

  nixpkgs.config.packageOverrides = pkgs: {
    nur = import sources.NUR {
      inherit pkgs;
    };
  };

  programs = {
    home-manager = {
      enable = true;
      # this uses the pinned version of home-manager
      path = "${home-manager.path}";
    };
    lesspipe.enable = true;
  };

  services = {
    lorri.enable = true;
  };

}
