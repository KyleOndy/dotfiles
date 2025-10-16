# Example home-manager configuration for WSL work environment
# This is a standalone configuration for WSL that extends the workstation profile

{
  config,
  pkgs,
  lib,
  ...
}:
{
  # Import the base workstation profile
  imports = [ ../profiles/workstation.nix ];

  # WSL-specific packages
  home.packages = with pkgs; [
    # WSL utilities
    wslu

    # Development tools
    awscli2
    azure-cli
    kubectl
    docker-compose
    terraform
    ansible

    # Windows interop tools
    powershell

    # Build tools that might not be in WSL's Ubuntu
    gcc
    gnumake
    cmake

    # Company-specific tools
    # internal-cli
    # proprietary-tool
  ];

  # Git configuration for work
  programs.git = {
    userEmail = lib.mkForce "your.name@company.com";
    userName = lib.mkForce "Your Name";

    extraConfig = {
      # WSL-specific git settings
      core = {
        # Handle Windows line endings
        autocrlf = "input";
        # Use Windows credential manager
        credentialStore = "wincredman";
      };

      # Work repository settings
      url."git@work-gitlab.com:" = {
        insteadOf = "https://work-gitlab.com/";
      };

      # Commit signing
      user.signingkey = "WORK_GPG_KEY_ID";
      commit.gpgsign = true;

      # WSL performance optimizations
      feature.manyFiles = true;
      core.fsmonitor = false; # Disable on WSL for performance
    };
  };

  # SSH configuration
  programs.ssh = {
    enable = true;

    # Use Windows SSH agent
    extraConfig = ''
      # Use Windows OpenSSH agent
      # Requires npiperelay.exe in Windows PATH
      Host *
        ForwardAgent yes
        # Use Windows SSH agent via npiperelay
        # IdentityAgent //./pipe/openssh-ssh-agent
    '';

    matchBlocks = {
      "work-*" = {
        user = "your-username";
        forwardAgent = true;
        # Use Windows-stored keys
        identityFile = "/mnt/c/Users/YourWindowsUser/.ssh/work_id_rsa";
      };

      "work-bastion" = {
        hostname = "bastion.company.com";
        user = "your-username";
      };

      "work-dev-*" = {
        proxyJump = "work-bastion";
      };
    };
  };

  # Shell configuration
  programs.zsh = {
    shellAliases = {
      # WSL-specific aliases
      explorer = "explorer.exe";
      code = "code.exe"; # Use Windows VS Code
      clip = "clip.exe"; # Copy to Windows clipboard

      # Docker in WSL
      docker = "docker.exe";
      docker-compose = "docker-compose.exe";

      # Quick navigation to Windows directories
      winhome = "cd /mnt/c/Users/$(whoami)";
      winwork = "cd /mnt/c/work";
      downloads = "cd /mnt/c/Users/$(whoami)/Downloads";

      # Kubernetes contexts
      kdev = "kubectl --context=dev";
      kprod = "kubectl --context=prod";

      # Work-specific
      vpn-check = "ping -c 1 internal.company.com";
    };

    sessionVariables = {
      # WSL-specific environment variables
      BROWSER = "wslview"; # Use Windows browser
      DISPLAY = ":0"; # For X11 apps if using WSLg

      # Path to Windows home
      WINHOME = "/mnt/c/Users/$(whoami)";

      # Work environment
      WORK_ENV = "wsl";
      DEFAULT_AWS_PROFILE = "company-dev";

      # Performance optimizations for WSL
      DOTNET_CLI_TELEMETRY_OPTOUT = "1";
      POWERSHELL_TELEMETRY_OPTOUT = "1";
    };

    initExtra = ''
      # WSL-specific PATH additions
      export PATH="$PATH:/mnt/c/Windows/System32"
      export PATH="$PATH:/mnt/c/Program Files/Docker/Docker/resources/bin"

      # Fix WSL permissions for mounted drives
      if [[ "$(umask)" = "0000" ]]; then
        umask 0022
      fi

      # Auto-start Docker Desktop if not running (optional)
      # if ! docker.exe ps >/dev/null 2>&1; then
      #   echo "Starting Docker Desktop..."
      #   "/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe" &
      # fi

      # WSL2 specific - get Windows IP for X11 forwarding
      export WINDOWS_HOST=$(ip route | grep default | awk '{print $3}')

      # Function to open files in Windows
      function open() {
        if [ $# -eq 0 ]; then
          explorer.exe .
        else
          explorer.exe "$@"
        fi
      }

      # Sync Windows SSH keys to WSL (optional)
      function sync-ssh-keys() {
        cp -r /mnt/c/Users/$(whoami)/.ssh/* ~/.ssh/
        chmod 600 ~/.ssh/*
        chmod 700 ~/.ssh
      }

      # Quick VPN status check
      function vpn-status() {
        if ping -c 1 -W 1 internal.company.com &>/dev/null; then
          echo "VPN: Connected"
        else
          echo "VPN: Disconnected"
        fi
      }
    '';
  };

  # VS Code integration (using Windows VS Code)
  home.sessionVariables = {
    EDITOR = "code.exe --wait";
    VISUAL = "code.exe --wait";
  };

  # Direnv for project environments
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # WSL-specific file management
  home.file = {
    # Link Windows .kube config if needed
    ".kube/config".source =
      config.lib.file.mkOutOfStoreSymlink "/mnt/c/Users/YourWindowsUser/.kube/config";

    # WSL config for better interop
    ".wslconfig".text = ''
      [automount]
      enabled = true
      options = "metadata,umask=22,fmask=11"

      [interop]
      appendWindowsPath = true
    '';
  };

  # Terminal multiplexer adjustments for WSL
  programs.tmux = {
    extraConfig = ''
      # WSL clipboard integration
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "clip.exe"
      bind -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "clip.exe"

      # Fix for WSL terminal colors
      set -g default-terminal "screen-256color"
    '';
  };
}
