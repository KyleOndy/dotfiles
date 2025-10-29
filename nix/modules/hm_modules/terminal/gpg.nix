{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.gpg;
in
{
  options.hmFoundry.terminal.gpg = {
    enable = mkEnableOption "gpg";
    service = mkOption {
      type = types.bool;
      default = true;
    };
    clearCacheOnScreenLock = mkOption {
      type = types.bool;
      default = true;
      description = "Clear GPG and SSH agent caches when the screen locks";
    };
  };

  config = mkIf cfg.enable {
    # TODO: see note in ssh.nix
    #home.sessionVariables = { GNUPGHOME = "${config.home.homeDirectory}/.gnupg"; };

    programs.gpg = {
      enable = true;
      settings = {
        # Disable inclusion of the version string in ASCII armored output
        no-emit-version = true;
        # Disable comment string in clear text signatures and ASCII armored messages
        no-comments = true;
        # Display long key IDs
        keyid-format = "0xlong";
        # List all keys (or the specified ones) along with their fingerprints
        with-fingerprint = true;
        # Display the calculated validity of user IDs during key listings
        list-options = "show-uid-validity";
        verify-options = "show-uid-validity";
      };
      scdaemonSettings = {
        verbose = true;
        debug-level = "basic";
        log-file = "~/.gnupg/scdaemon.log";
        disable-ccid = true;
      };
    };

    services.gpg-agent = {
      enable = cfg.service;
      defaultCacheTtl = 28800; # GPG keys: 8 hours
      defaultCacheTtlSsh = 28800; # SSH keys: 8 hours (resets on use)
      maxCacheTtl = 28800; # GPG keys max: 8 hours
      maxCacheTtlSsh = 28800; # SSH keys max: 8 hours
      enableSshSupport = true; # Enable SSH agent functionality
      pinentry.package = pkgs.pinentry-curses;
    };

    # Systemd service to clear GPG/SSH cache on screen lock
    systemd.user.services.gpg-lock-on-screensaver = mkIf cfg.clearCacheOnScreenLock {
      Unit = {
        Description = "Clear GPG and SSH caches when screen locks";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${pkgs.bash}/bin/bash ${./gpg-lock-on-screensaver.sh}";
        Restart = "on-failure";
        RestartSec = "5s";
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
