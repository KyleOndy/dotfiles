# settings that are not specific to the shell being used.
{ pkgs, ... }:

let
  editor = "nvim";
in
{
  programs = {
    bat = {
      enable = true;
      config = {
        theme = "Solarized (dark)"; # todo: add gruvbox
      };
    };
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };

  home.sessionVariables = {
    DOTFILES = "/home/kyle/src/dotfiles";
    # todo:
    EDITOR = editor;
    VISUAL = editor;
    # $HOME/wip_scripts is where I put scripts that are not ready for inclsion
    # in the source contro repo. I try hard to not let scripts sit there for
    # too long.
    PATH = "$PATH:${pkgs.my-scripts}/bin:$HOME/wip_scripts";
  };
}
