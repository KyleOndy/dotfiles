{ pkgs, config, ... }:
{
  programs = {
    home-manager = {
      enable = true;
    };
    lesspipe.enable = true;
    ssh = {
      enable = true;
      extraConfig = ''
        IdentitiesOnly yes
      '';

      matchBlocks = {
        "pi1" = {
          hostname = "pi.lan.509ely.com";
          user = "kyle";
        };
        "pi2" = {
          hostname = "pi2.dmz.509ely.com";
          user = "kyle";
        };
        "pi3" = {
          hostname = "pi3.dmz.509ely.com";
          user = "kyle";
        };
        "*.compute-1.amazonaws.com" = {
          extraOptions = {
            UserKnownHostsFile = "/dev/null";
            StrictHostKeyChecking = "no";
          };
        };
        "tiger tiger.dmz.509ely.com" = {
          # 10.25.89.5
          hostname = "tiger.dmz.509ely.com";
          user = "kyle";
          port = 2332;
        };
        "dino" = {
          hostname = "dino.lan.509ely.com";
          user = "kyle";
        };
        "alpha" = {
          hostname = "alpha.lan.509ely.com";
          user = "kyle";
        };
      };
    };
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
      hashicorp.enable = false;
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
      tmux.enable = true;
      gpg.enable = true;
      pass.enable = true;
      editors = {
        neovim.enable = true;
      };
    };
  };

  # the following configuration should be moved into a module, I am just not sure where it fits right now, so dropping it inline.
  home = {
    sessionVariables = {
      DOTFILES = "${config.home.homeDirectory}/src/dotfiles";
      FOUNDRY_DATA = "${config.home.homeDirectory}/src/foundry";
      EDITOR = "nvim";
      VISUAL = "nvim";
      # this allows the rest of the nix tooling to use the same nixpkgs that I
      # have set in the flake.
      NIX_PATH = "nixpkgs=${pkgs.path}";
      MANPAGER = "nvim +Man! -- ";

      # TODO: even if we aren't using GPG, we need this set before trying to
      #       use the GPG module. Race condition I need to fix later.
      GNUPGHOME = "${config.home.homeDirectory}/.gnupg";
    };
    stateVersion = "18.09";
  };
}
