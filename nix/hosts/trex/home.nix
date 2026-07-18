# Personal home-manager configuration for trex.
# The desktop profile is imported via mkDarwinSystem; this file provides
# macOS-specific overrides, mirroring nix/hosts/work-mac/home.nix.
{
  lib,
  pkgs,
  ...
}:
{
  imports = [ ];

  # Disable Linux-only features on macOS
  hmFoundry.desktop = {
    apps.discord.enable = lib.mkForce false;
    apps.slack.enable = lib.mkForce false;
    browsers.firefox.enable = lib.mkForce true;
    gaming.steam.enable = lib.mkForce false;
    term.foot.enable = lib.mkForce false;
    term.alacritty.enable = true;
    term.wezterm.enable = lib.mkForce false;
    wm.i3.enable = lib.mkForce false;
    media = {
      makemkv.enable = lib.mkForce false;
      documents.enable = lib.mkForce false;
    };
  };

  # Kensington trackball remapping - same physical hardware/need as dino's
  # hmFoundry.desktop.input.trackball, just the darwin-side mechanism.
  hmFoundry.desktop.input.karabiner = {
    enable = true;
    kensingtonExpert.enable = true;
    pcStyle.enable = true;
  };

  # App quick-switching
  hmFoundry.desktop.input.hammerspoon.enable = true;

  # Add Homebrew to PATH for all managed shells (including Claude Code)
  home.sessionPath = [ "/opt/homebrew/bin" ];

  hmFoundry.dev = {
    claude-code.enable = true;
    kubernetes.enable = true; # kubectl, kubectx, k9s, helm, kustomize, kind
    nixTools.enable = true; # nixfmt, nixpkgs-review, nix-index
    sysadmin.enable = true; # htop, lsof, nmap, mosh, dnsutils

    # Colima background service. Defaults (4 CPU / 8GB / 100GB) are
    # conservative starting points - tune once trex's actual RAM is known.
    docker.service.enable = true;
  };
}
