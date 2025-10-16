# Base home-manager configuration for work macOS environments
# The desktop profile is imported via mkDarwinSystem
# This file provides macOS-specific overrides and allows work-specific extensions via work-home.nix
{
  lib,
  ...
}:
{
  # The desktop profile is imported via mkDarwinSystem in flake.nix
  # This file provides macOS-specific overrides
  imports = [ ] ++ lib.optional (builtins.pathExists ./work-home.nix) ./work-home.nix;

  # The desktop profile provides:
  # - Full development tools (kubernetes, aws, terraform, docker, etc.)
  # - Shell configuration (zsh with sensible defaults)
  # - Desktop applications (browsers, communication apps, terminals)
  # - Language toolchains (via hmFoundry.dev flags)
  #
  # Work forks can override or extend any of these settings in work-home.nix
  # using lib.mkForce, lib.mkDefault, or by adding to existing lists/attrsets

  # Example customizations that work forks might add in work-home.nix:
  # - programs.git.userEmail = lib.mkForce "you@company.com";
  # - home.packages = with pkgs; [ company-specific-tool ];
  # - programs.ssh.matchBlocks = { "work-*" = { ... }; };
  # - programs.zsh.shellAliases = { vpn = "tailscale up"; };
  # - hmFoundry.dev.aws.enable = true;

  # Disable Linux-only features on macOS
  hmFoundry.desktop = {
    # Disable all desktop features to isolate i686 issue
    apps.discord.enable = lib.mkForce false;
    apps.slack.enable = lib.mkForce false;
    browsers.firefox.enable = lib.mkForce false;
    gaming.steam.enable = lib.mkForce false;
    term.foot.enable = lib.mkForce false;
    term.wezterm.enable = lib.mkForce false;
    wm.i3.enable = lib.mkForce false;
    media = {
      makemkv.enable = lib.mkForce false;
      documents.enable = lib.mkForce false; # LibreOffice is Linux-only
    };
  };

  # Desktop packages are managed by hmFoundry modules
  # home.packages overrides should be additive, not replacing
}
