# Base home-manager configuration for work macOS environments
# The desktop profile is imported via mkDarwinSystem
# This file provides macOS-specific overrides and allows work-specific extensions via work-home.nix
{
  lib,
  pkgs,
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
  #
  # For work-specific Neovim plugins (e.g., copilot):
  # nvim.packageDefinitions.merge = {
  #   nvim = { pkgs, ... }: {
  #     categories = { work = true; };
  #     work = { copilot = true; };
  #   };
  # };
  #
  # Provision work Lua config from this directory:
  # xdg.configFile."nixCats-nvim/lua/plugins/work.lua".source = ./work.lua;
  # Then create work.lua in this directory and add "plugins.work" to lua/plugins.lua
  #
  # See docs/nixcats-work-plugins.md for details.

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
      documents.enable = lib.mkForce false;
    };
  };

  # Enable Karabiner for trackball button remapping
  hmFoundry.desktop.input.karabiner = {
    enable = true;
    kensingtonExpert.enable = true;
  };

  # Enable work context for shell completions (Jira tickets, etc.)
  home.sessionVariables = {
    DOTS_CONTEXT = "work";
  };

  # Enable Java development tools for work
  hmFoundry.dev.java.enable = true;

  # packages I use at work, but not persoanlly, that do not need to be kept
  # secret in the work fork.
  home.packages = with pkgs; [
    k9s
  ];
}
