# Home Manager configuration for WSL work environments
# Company-specific settings come from the work-config flake input
# (flake.nix:771), overridden with --override-input on work machines.
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
  ];

  # Enable Java development tools for work
  hmFoundry.dev.java.enable = true;

  # WSL-specific packages
  home.packages = with pkgs; [
    # WSL utilities for Windows interop
    wslu

    # Build tools for WSL (clang and cmake are provided by dev/core.nix)
    gnumake

    # Linear CLI for issue tracking
    linear-cli
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
      # Enable work context for shell completions (Linear tickets, etc.)
      DOTS_CONTEXT = "work";

      # Use Windows browser for opening URLs
      BROWSER = "wslview";

      # X11 display for GUI apps (if using WSLg)
      DISPLAY = ":0";

      # Path to Windows home directory
      WINHOME = "/mnt/c/Users/$(whoami)";

      # Disable telemetry for Windows tools
      DOTNET_CLI_TELEMETRY_OPTOUT = "1";
      POWERSHELL_TELEMETRY_OPTOUT = "1";
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
  home.file.".wslconfig".text = ''
    [automount]
    enabled = true
    options = "metadata,umask=22,fmask=11"

    [interop]
    appendWindowsPath = true
  '';

}
