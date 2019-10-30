# settings that are not specific to the shell being used.
{ pkgs, ... }:

{
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  home.sessionVariables = {
    DOTFILES = "/home/kyle/src/dotfiles";
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
}
