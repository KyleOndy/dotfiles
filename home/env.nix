# settings that are not specific to the shell being used.
{ pkgs, ... }:
let
  # todo: I would like to do something like `${pkgs.neovim}/bin/nvim";`, but
  #       that is the system neovim binary without my configuration. If I run
  #       `readlink $(which nvim)` I get a path
  #       `/nix/store/...-home-manager-path/bin/nvim`. I need to do a bit of
  #       digging to figure out how to source that path.
  editor = "nvim";
  dotfiles = "$HOME/src/dotfiles";
in
{
  programs = {
    bat = {
      enable = true;
      config = {
        theme = "gruvbox-dark";
      };
    };

  services = {
    dropbox.enable = true;
  };

  home.sessionVariables = {
    DOTFILES = dotfiles;
    EDITOR = editor;
    VISUAL = editor;
    # todo: shouldn't my-scripts be on path already?
    PATH = "$PATH:${pkgs.my-scripts}/bin";
    # this allows the rest of the nix tooling to use the same nixpkgs that I
    # have set in the flake.
    NIX_PATH = "nixpkgs=${pkgs.path}";
    MANPAGER = "${pkgs.bash}/bin/bash -c 'col -bx | ${pkgs.bat}/bin/bat -l man -p'";
  };
}
