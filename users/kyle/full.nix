{ pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/haskell.nix
    ./../../home/i3.nix
    ./../../home/packages.nix
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
      browsers = {
        firefox.enable = true;
      };
      fonts = {
        hack.enable = true;
      };
      gaming = {
        steam.enable = true;
      };
      media = {
        documents.enable = true;
      };
      term = {
        st.enable = true;
      };
    };
    dev = {
      enable = true;
      clojure.enable = true;
      python.enable = true;
      dotnet.enable = true;
      hashicorp.enable = true;
      #terraform.enable = true;
      git.enable = true;
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
      email.enable = true;
      dropbox.enable = true;
      tmux.enable = true;
      editors = {
        neovim.enable = true;
      };
      pass.enable = true;
      gpg.enable = true;
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
    MANPAGER = "${pkgs.neovim}/bin/nvim +Man! --";
  };
}
