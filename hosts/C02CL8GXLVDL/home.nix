{ pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/env.nix
    ./../../home/fonts.nix
    ./../../home/git.nix
    #./../../home/go.nix
    #./../../home/gpg.nix
    #./../../home/haskell.nix
    #./../../home/i3.nix
    ./../../home/packages.nix
  ];


  programs = {
    home-manager = {
      enable = true;
    };
    lesspipe.enable = true;
  };

  services = {
    #lorri.enable = true;
  };

  foundry = {
    # foundry is the namespace I've given to my internal modules
    dev = {
      clojure.enable = false; # todo: want true
      python.enable = true;
      dotnet.enable = true;
      hashicorp.enable = true;
      #terraform.enable = true;
      #git.enable = true;
      #haskell.enable = true;
      nix.enable = true;
      #powershell.enable = true;
      #puppet.enable = true;
      #go.enable = true;
    };
    shell = {
      zsh.enable = true;
      bash.enable = true;
    };
    terminal = {
      tmux.enable = true;
      gpg = {
        enable = true;
        service = false; # no service on darwin
      };
      editors = {
        neovim.enable = true;
      };
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
