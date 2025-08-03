# Server profile - for server deployments
# Includes monitoring, SSH access, and basic administration tools

{ pkgs, ... }:
{
  imports = [
    ./common/base.nix
    ./common/ssh-hosts.nix
  ];

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

    # File management
    rsync
    tree
    fd
    ripgrep

    # System administration
    mosh # better ssh
    tmux # session management
    curl
    wget
    jq
    yq-go

    # Compression tools
    xz
    lz4
    pixz

    # Basic utilities
    bat
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
