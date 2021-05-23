{ pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/emacs.nix
    ./../../home/env.nix
    ./../../home/firefox.nix
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

}
