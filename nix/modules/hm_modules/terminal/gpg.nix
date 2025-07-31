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
    home.packages = with pkgs; [ pinentry-curses ]; # cli pin entry
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
      defaultCacheTtl = 1800;
      enableSshSupport = false;
      pinentry.package = pkgs.pinentry-curses;
    };
  };
}
