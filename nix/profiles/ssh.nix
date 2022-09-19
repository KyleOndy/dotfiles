{ pkgs, ... }:
{
  programs = {
    home-manager = {
      enable = true;
    };
    lesspipe.enable = true;
    ssh = {
      # TODO: move to SSH module
      enable = true;
      extraConfig = ''
        IdentitiesOnly yes
      '';

      matchBlocks = {
        "util" = {
          hostname = "10.25.89.4";
          user = "pi";
        };
        "w" = {
          hostname = "10.25.89.6";
          user = "root";
        };
        "w1" = {
          hostname = "w1.dmz.509ely.com";
          user = "root";
        };
        "w2" = {
          hostname = "w2.dmz.509ely.com";
          user = "root";
        };
        "w3" = {
          hostname = "w3.dmz.509ely.com";
          user = "root";
        };
        "m1" = {
          hostname = "m1.dmz.509ely.com";
          user = "root";
        };
        "m2" = {
          hostname = "m2.dmz.509ely.com";
          user = "root";
        };
        "m3" = {
          hostname = "m3.dmz.509ely.com";
          user = "root";
        };
        "eu.nixbuild.net beta.nixbuild.net" = {
          extraOptions = {
            PubkeyAcceptedKeyTypes = "ssh-ed25519";
          };
          identityFile = "~/.ssh/nixbuild";
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
          user = "svc.deploy";
          port = 2332;
        };
        "dino" = {
          user = "svc.deploy";
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
      DOTFILES = "$HOME/src/dotfiles";
      FOUNDRY_DATA = "$HOME/src/foundry";
      EDITOR = "nvim";
      VISUAL = "nvim";
      # this allows the rest of the nix tooling to use the same nixpkgs that I
      # have set in the flake.
      NIX_PATH = "nixpkgs=${pkgs.path}";
      MANPAGER = "nvim +Man! -- ";

      # even if we aren't using GPG, we need this set before trying to use the
      # GPG module. Race condition I need to fix later.
      GNUPGHOME = "$HOME/.gnupg";
    };
    stateVersion = "18.09";
  };
}
