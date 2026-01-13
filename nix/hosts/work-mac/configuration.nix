# Base darwin system configuration for work macOS environments
# This provides sensible defaults that can be extended via work.nix in work forks
{
  lib,
  pkgs,
  ...
}:
{
  # Conditional import of work-specific overrides
  # Work forks should create work.nix in this directory with company-specific config
  imports = [ ] ++ lib.optional (builtins.pathExists ./work.nix) ./work.nix;

  # Nix configuration
  nix = {
    package = pkgs.nixVersions.latest;
    optimise.automatic = true;
    settings = {
      # Enable flakes and new nix commands
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Trusted users can use additional nix features
      trusted-users = [
        "root"
        "@admin"
      ];
    };

    # Use nixpkgs from registry for consistency
    nixPath = [ "nixpkgs=${pkgs.path}" ];
  };

  # Enable TouchID for sudo (nice quality of life improvement)
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault true;

  # Homebrew integration for GUI applications and tools not in nixpkgs
  homebrew = {
    enable = lib.mkDefault true;

    # Behavior during activation
    onActivation = {
      autoUpdate = lib.mkDefault false;
      upgrade = lib.mkDefault false;
      cleanup = lib.mkDefault "zap"; # Remove packages not in config
    };

    # Default casks (can be overridden with lib.mkForce in work.nix)
    casks = lib.mkDefault [ "karabiner-elements" ];

    # Default brews (can be overridden with lib.mkForce in work.nix)
    brews = lib.mkDefault [ ];
  };

  # macOS system preferences
  system = {
    # Primary user for homebrew and system defaults
    primaryUser = "kondy";

    # System version (managed by nix-darwin)
    stateVersion = 5;

    defaults = {
      # Dock preferences
      dock = {
        autohide = lib.mkDefault true;
        show-recents = lib.mkDefault false;
        tilesize = lib.mkDefault 48;
        mru-spaces = lib.mkDefault false; # Don't rearrange spaces
      };

      # Finder preferences
      finder = {
        AppleShowAllExtensions = lib.mkDefault true;
        FXPreferredViewStyle = lib.mkDefault "clmv"; # Column view
        ShowPathbar = lib.mkDefault true;
        ShowStatusBar = lib.mkDefault true;
      };

      # Trackpad settings
      trackpad = {
        Clicking = lib.mkDefault true; # Tap to click
      };
    };
  };

  # Allow unfree packages (many work tools require this)
  nixpkgs.config.allowUnfree = true;
}
