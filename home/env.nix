# settings that are not specific to the shell being used.
{ pkgs, ... }:
let
  # todo: I would like to do something like `${pkgs.neovim}/bin/nvim";`, but
  # that is the system neovim binary without my configuration. If I run
  # `readlink $(which nvim)` I get a path
  # `/nix/store/...-home-manager-path/bin/nvim`. I need to do a bit of digging
  # to figure out how to source that path.
  editor = "nvim";
  dotfiles = "${builtins.getEnv "HOME"}/src/dotfiles";
in
{
  programs = {
    bat = {
      enable = true;
      config = {
        theme = "gruvbox-dark";
      };
    };
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
  };

  services = {
    dropbox.enable = true;
  };

  home.sessionVariables = {
    DOTFILES = dotfiles;
    # todo:
    EDITOR = editor;
    VISUAL = editor;
    # $HOME/wip_scripts is where I put scripts that are not ready for inclsion
    # in the source contro repo. I try hard to not let scripts sit there for
    # too long.
    PATH = "$PATH:${pkgs.my-scripts}/bin:$HOME/wip_scripts";
    # this allows the rest of the system to default to the packages I use in my
    # dotfiles.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    MANPAGER = "${pkgs.bash}/bin/bash -c 'col -bx | ${pkgs.bat}/bin/bat -l man -p'";
  };
}
