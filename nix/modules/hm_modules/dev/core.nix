# Core development tools that are always included when dev.enable = true
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev;
in
{
  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Essential dev utilities
      ctags
      envsubst

      # Search and navigation
      ripgrep
      fd
      tree
      silver-searcher

      # Network tools
      curl
      wget
      rsync

      # Data processing
      jq
      yq-go
      gron
      htmlq

      # Shell tools
      shellcheck
      shfmt

      # File utilities
      file
      groff

      # Other essentials
      bc
      entr
      fswatch
      lesspipe
      ranger
      visidata
      xlsx2csv

      # Development tools
      clang
      cmake
      cookiecutter
      grpcurl
      postgresql

      # Misc utilities
      cowsay
      fortune
      w3m
      xclip
      xxd

      # Personal scripts
      my-scripts
    ];

    programs = {
      bat = {
        enable = true;
        config = {
          theme = "gruvbox-dark";
        };
      };
      direnv = {
        enable = true;
        nix-direnv = {
          enable = true;
        };
      };
    };
  };
}
