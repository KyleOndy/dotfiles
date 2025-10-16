# Base home-manager configuration for work macOS environments
# Imports the workstation profile and allows work-specific extensions via work-home.nix
{
  lib,
  ...
}:
{
  # Import the base workstation profile for full development environment
  imports = [
    ../../profiles/workstation.nix
  ]
  ++ lib.optional (builtins.pathExists ./work-home.nix) ./work-home.nix;

  # The workstation profile provides:
  # - Development tools (git, editors, terminal multiplexers)
  # - Shell configuration (zsh with sensible defaults)
  # - Language toolchains (via hmFoundry.features flags)
  # - Desktop applications (if isDesktop is enabled)
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

  # Temporarily disable desktop packages
  home.packages = lib.mkForce [ ];
}
