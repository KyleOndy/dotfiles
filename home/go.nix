{ pkgs, ... }:

{
  programs.go = {
    enable = true;
    package = pkgs.go;
    goPath = "go";
  };
}
