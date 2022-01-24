{ pkgs, ... }:
{
  programs = {
    home-manager = {
      enable = true;
    };
    lesspipe.enable = true;
  };

  services = {
    lorri.enable = true;
  };

  hmFoundry = {
    # foundry is the namespace I've given to my internal modules
    dev = {
      enable = true;
      clojure.enable = true;
      python.enable = true;
      dotnet.enable = true;
      hashicorp.enable = true;
      git.enable = true;
      haskell.enable = true;
      nix.enable = true;
      go.enable = false;
    };
    shell = {
      zsh.enable = true;
      bash.enable = true;
    };
    terminal = {
      email.enable = true;
      dropbox.enable = true;
      tmux.enable = true;
      gpg.enable = true;
      pass.enable = true;
      editors = {
        neovim.enable = true;
      };
    };
  };

  # the following configuration should be moved into a module, I am just not sure where it fits right now, so dropping it inline.
  home.sessionVariables = {
    DOTFILES = "$HOME/src/dotfiles";
    FOUNDRY_DATA = "$HOME/src/foundry";
    EDITOR = "nvim";
    VISUAL = "nvim";
    # this allows the rest of the nix tooling to use the same nixpkgs that I
    # have set in the flake.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    MANPAGER = "${pkgs.neovim}/bin/nvim +Man! -- ";
  };
}
