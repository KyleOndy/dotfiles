# Server profile - for server deployments
# Includes monitoring, SSH access, and basic administration tools

{ pkgs, ... }:
{
  imports = [
    ./common/base.nix
    ./common/ssh-hosts.nix
    ../modules/hm_modules/common-tools.nix
  ];

  hmFoundry.commonTools.enable = true;

  hmFoundry.features = {
    isDevelopment = false;
    isDesktop = false;
    isServer = true;
    isGaming = false;

    # Enable server-specific features
    isSystemAdmin = true; # System administration tools
    isMonitoring = true; # Advanced monitoring tools
    isPerformance = true; # Performance optimization tools
    isSecurity = true; # Security tools
  };

  # Server-specific packages
  home.packages = with pkgs; [
    # Monitoring and diagnostics
    htop
    glances
    lsof
    nettools
    dnsutils
    nmap

    # System administration
    mosh # better ssh
    tmux # session management

    # Compression tools
    xz
    lz4
    pixz

    # Basic utilities
    watch
    viddy
    pv
  ];

  # Enable essential terminal tools for server management
  hmFoundry.terminal = {
    tmux.enable = true;
    editors = {
      neovim.enable = true;
    };
  };

  hmFoundry.shell = {
    bash.enable = true;
    zsh.enable = false; # Keep it simple on servers
  };
}
