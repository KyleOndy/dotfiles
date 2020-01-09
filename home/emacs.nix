{ pkgs, ... }:

# https://gitlab.com/rycee/configurations/blob/d6dcf6480e29588fd473bd5906cd226b49944019/user/emacs.nix

let

  nurNoPkgs = import (builtins.fetchTarball
    "https://github.com/nix-community/NUR/archive/master.tar.gz") { };

in {
  imports = [ nurNoPkgs.repos.rycee.hmModules.emacs-init ];

  services.emacs = { enable = true; };
  programs.emacs = {
    enable = true;
    package = pkgs.emacs;
    init = {
      enable = true;
      recommendedGcSettings = true;

        # evil
        epkgs.evil

        # git
        epkgs.magit
      ];
  };

}
