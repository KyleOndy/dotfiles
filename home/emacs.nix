{ ... }:
#let
#  sources = import ../nix/sources.nix;
#  emacs-overlay = import sources.emacs-overlay {};
#in
{
  programs.emacs = {
    enable = true;
    #package = emacs-overlay.emacsGit;
  };
}
