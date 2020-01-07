{ pkgs, ... }:

{
  programs.emacs = {
    enable = true;
    package = pkgs.emacs;
    extraPackages = epkgs:
      with epkgs; [
        # themes
        epkgs.solarized-theme

        # evil
        epkgs.evil

        # git
        epkgs.magit
      ];
  };
}

