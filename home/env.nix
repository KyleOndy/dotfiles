# settings that are not specific to the shell being used.
{ pkgs, ... }:

let
  editor = "${pkgs.my-scripts}/bin/emacs.sh";
in
{
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  home.sessionVariables = {
    DOTFILES = "/home/kyle/src/dotfiles";
    # todo:
    EDITOR = editor;
    VISUAL = editor;
    PATH = "$PATH:${pkgs.my-scripts}/bin";
  };
}
