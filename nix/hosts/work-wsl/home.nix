# Home Manager configuration for WSL work environments
# This is the base configuration - work forks can add ./work-home.nix for company-specific settings
{
  config,
  pkgs,
  lib,
  ...
}:
{
  # Import the server profile - WSL is used as a terminal-only environment
  imports = [
    ../../profiles/server.nix
  ]
  ++ lib.optional (builtins.pathExists ./work-home.nix) ./work-home.nix;

  # WSL-specific packages
  home.packages = with pkgs; [
    # WSL utilities for Windows interop
    wslu

    # Common build tools that might not be in WSL's default Ubuntu
    gcc
    gnumake
    cmake
  ];

  # WSL-specific shell configuration
  programs.zsh = {
    shellAliases = {
      # Windows interop aliases
      explorer = lib.mkDefault "explorer.exe";
      clip = lib.mkDefault "clip.exe"; # Copy to Windows clipboard

      # Quick navigation to Windows directories
      winhome = lib.mkDefault "cd /mnt/c/Users/$(whoami)";
      downloads = lib.mkDefault "cd /mnt/c/Users/$(whoami)/Downloads";
    };

    sessionVariables = {
      # Enable work context for shell completions (Jira tickets, etc.)
      DOTS_CONTEXT = "work";

      # Use Windows browser for opening URLs
      BROWSER = lib.mkDefault "wslview";

      # X11 display for GUI apps (if using WSLg)
      DISPLAY = lib.mkDefault ":0";

      # Path to Windows home directory
      WINHOME = "/mnt/c/Users/$(whoami)";

      # Disable telemetry for Windows tools
      DOTNET_CLI_TELEMETRY_OPTOUT = lib.mkDefault "1";
      POWERSHELL_TELEMETRY_OPTOUT = lib.mkDefault "1";
    };

    initExtra = ''
      # WSL-specific PATH additions
      export PATH="$PATH:/mnt/c/Windows/System32"

      # Fix WSL permissions for mounted drives
      if [[ "$(umask)" = "0000" ]]; then
        umask 0022
      fi

      # Get Windows host IP for X11 forwarding
      export WINDOWS_HOST=$(ip route | grep default | awk '{print $3}')

      # Function to open files/directories in Windows Explorer
      function open() {
        if [ $# -eq 0 ]; then
          explorer.exe .
        else
          explorer.exe "$@"
        fi
      }
    '';
  };

  # Enable direnv for project-specific environments
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Terminal multiplexer with WSL clipboard integration
  programs.tmux.extraConfig = lib.mkAfter ''
    # WSL clipboard integration
    bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "clip.exe"
    bind -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "clip.exe"
  '';

  # WSL configuration file
  home.file.".wslconfig".text = lib.mkDefault ''
    [automount]
    enabled = true
    options = "metadata,umask=22,fmask=11"

    [interop]
    appendWindowsPath = true
  '';

  # Work forks should create ./work-home.nix to add:
  # - Company-specific git configuration (email, signing keys, credential manager)
  # - SSH configuration for work servers (bastion hosts, jump boxes)
  # - Cloud provider tools (awscli2, azure-cli, google-cloud-sdk)
  # - Kubernetes and container tools (kubectl, helm, k9s)
  # - Docker Desktop integration (if using Windows Docker)
  # - Company VPN status checking
  # - Work-specific aliases and environment variables
  # - Windows-specific tool integration (PowerShell, Windows SSH agent)

  # Example work-home.nix structure:
  # {
  #   home.packages = with pkgs; [
  #     awscli2
  #     kubectl
  #     terraform
  #     docker-compose
  #   ];
  #
  #   programs.git = {
  #     userEmail = lib.mkForce "you@company.com";
  #     extraConfig = {
  #       core.autocrlf = "input";
  #       core.credentialStore = "wincredman";
  #       user.signingkey = "WORK_GPG_KEY_ID";
  #     };
  #   };
  #
  #   programs.ssh.matchBlocks = {
  #     "work-*" = {
  #       user = "your-username";
  #       forwardAgent = true;
  #     };
  #   };
  #
  #   programs.zsh.shellAliases = {
  #     docker = "docker.exe";
  #     kdev = "kubectl --context=dev";
  #     vpn-check = "ping -c 1 internal.company.com";
  #   };
  #
  #   hmFoundry.dev = {
  #     aws.enable = true;
  #     kubernetes.enable = true;
  #     docker.enable = true;
  #   };
  # }
}
