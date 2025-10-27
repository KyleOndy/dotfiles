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
      defaultCacheTtl = 1800; # GPG keys: 30 minutes
      defaultCacheTtlSsh = 3600; # SSH keys: 1 hour (resets on use)
      maxCacheTtl = 7200; # GPG keys max: 2 hours
      maxCacheTtlSsh = 14400; # SSH keys max: 4 hours
      enableSshSupport = true; # Enable SSH agent functionality
      # Smart pinentry: Use curses in interactive terminals, GUI otherwise
      pinentry.package = pkgs.writeShellScriptBin "pinentry-auto" ''
        # Use curses (text mode) if we're in an interactive terminal with GPG_TTY set
        # Use gtk2 (GUI) otherwise (for IDEs, automation, Claude Code, etc.)
        if [ -t 0 ] && [ -n "$GPG_TTY" ] && [ -c "$GPG_TTY" ]; then
          exec ${pkgs.pinentry-curses}/bin/pinentry-curses "$@"
        else
          exec ${pkgs.pinentry-gtk2}/bin/pinentry-gtk2 "$@"
        fi
      '';
    };
  };
}
