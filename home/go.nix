
{ pkgs, ... }:

let old_dots = import ./_dotfiles-dir.nix;

in {
  programs.go = {
    enable = true;
    package = pkgs.go;
    goPath = "src";
  };
}

