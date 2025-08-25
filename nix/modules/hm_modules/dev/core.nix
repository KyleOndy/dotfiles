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
      # Essential build tools
      bashInteractive
      gnumake
      gnused
      coreutils-full
      findutils

      # Essential dev utilities
      ctags
      direnv
      envsubst

      # Search and navigation
      ripgrep
      fd
      tree
      bat
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
      man-pages
      groff

      # Compression
      unzip
      xz

      # Other essentials
      bc
      entr
      fswatch
      lorri
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
