{ pkgs, ... }:
{
  # import each nix file into home-manager
  imports = [
    ./../../home/git.nix
    ./../../home/gpg.nix
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
      enable = true;
      clojure.enable = true;
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
        # todo: need to fix on darwin
        #     [I] ➜ gpg --card-status
        #     gpg: Fatal: can't create directory '/var/empty/.gnupg': Operation not permitted
        enable = false;
        service = false; # no service on darwin
      };
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
