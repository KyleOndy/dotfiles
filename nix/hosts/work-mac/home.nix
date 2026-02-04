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

  # Enable Karabiner for trackball button remapping and PC-style shortcuts
  hmFoundry.desktop.input.karabiner = {
    enable = true;
    kensingtonExpert.enable = true;
    pcStyle.enable = true;
  };

  # Enable Hammerspoon for app quick-switching
  hmFoundry.desktop.input.hammerspoon = {
    enable = true;
    extraConfig = ''
      -- Forward delete moves to trash in Finder
      hs.hotkey.bind({}, "forwarddelete", function()
        local app = hs.application.frontmostApplication()
        if app:bundleID() == "com.apple.finder" then
          hs.eventtap.keyStroke({"cmd"}, "delete")
        end
      end)
    '';
  };

  # Enable work context for shell completions (Linear tickets, etc.)
  home.sessionVariables = {
    DOTS_CONTEXT = "work";
    PDM_USE_VENV = "1"; # Configure PDM to use venv instead of __pypackages__
  };

  # Override src alias to point to modularml workspace
  programs.zsh.shellAliases = {
    src = lib.mkForce "cd /Users/kondy/src/modularml";
  };

  # Enable development modules
  hmFoundry.dev = {
    git.userEmail = "kondy@modular.com";
    java.enable = true;
    claude-code.enable = true;
    kubernetes.enable = true; # kubectl, kubectx, k9s, helm, kustomize, kind
    nixTools.enable = true; # nixfmt, nixpkgs-review, nix-index
    sysadmin.enable = true; # htop, lsof, nmap, mosh, dnsutils
    go.installGo = false; # Use Homebrew Go for CGO compatibility on macOS

    # Enable Colima background service
    docker.service = {
      enable = true;
      cpu = 4;
      memory = 8;
      disk = 100;
    };
  };

  # packages I use at work, but not persoanlly, that do not need to be kept
  # secret in the work fork.
  home.packages = with pkgs; [
    argocd # ArgoCD CLI
    gh # GitHub CLI
    linear-cli
    pdm # Python Development Master
    pulumi
    pkgs.pulumiPackages.pulumi-python
  ];

  # Manage Claude.md for modularml project
  home.file."src/modularml/Claude.md" = {
    source = ./modularml-CLAUDE.md;
    force = true; # Override existing file if present
  };
}
