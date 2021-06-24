{ pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/env.nix
    ./../../home/fonts.nix
    ./../../home/git.nix
    ./../../home/go.nix
    ./../../home/gpg.nix
    ./../../home/haskell.nix
    ./../../home/i3.nix
    ./../../home/neovim.nix
    ./../../home/packages.nix
    ./../../home/tmux.nix
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

  foundry = {
    # foundry is the namespace I've given to my internal modules
    desktop = {
      apps = {
        discord.enable = true;
      };
    };
    dev = {
      clojure.enable = true;
      python.enable = true;
    };
    shell = {
      zsh.enable = true;
    };
    terminal = {
      email.enable = true;
      dropbox.enable = true;
    };
  };

  # the following configuration should be moved into a module, I am just not sure where it fits right now, so dropping it inline.
  home.sessionVariables = {
    DOTFILES = "$HOME/src/dotfiles";
    EDITOR = "nvim";
    VISUAL = "nvim";
    # this allows the rest of the nix tooling to use the same nixpkgs that I
    # have set in the flake.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    MANPAGER = "${pkgs.bash}/bin/bash -c 'col -bx | ${pkgs.bat}/bin/bat -l man -p'";
  };
}
