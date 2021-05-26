# settings that are not specific to the shell being used.
{ pkgs, ... }:
let
  # todo: I would like to do something like `${pkgs.neovim}/bin/nvim";`, but
  # that is the system neovim binary without my configuration. If I run
  # `readlink $(which nvim)` I get a path
  # `/nix/store/...-home-manager-path/bin/nvim`. I need to do a bit of digging
  # to figure out how to source that path.
  editor = "nvim";
  homeDir = "$HOME"; # todo: does this work?
  dotfiles = "${homeDir}/src/dotfiles";
in
{
  programs = {
    bat = {
      enable = true;
      config = {
        theme = "gruvbox-dark";
      };
    };
  };
}
