{ pkgs, ... }:

{
  fonts.fontconfig.enable = true;

  # todo: I do not use all these. Remove what I don't use.
  home.packages = [
    pkgs.fantasque-sans-mono
    pkgs.fira
    pkgs.fira-code
    pkgs.fira-code-symbols
    pkgs.fira-mono
    pkgs.hack-font
    pkgs.hasklig
    pkgs.hermit
    pkgs.inconsolata
    pkgs.mononoki
    pkgs.raleway
    pkgs.roboto
    pkgs.source-code-pro
    pkgs.terminus_font
  ];
}

