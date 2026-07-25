{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.email;
in
{
  options.hmFoundry.terminal.email = {
    enable = mkEnableOption "email sync and indexing";
    passwordCommand = mkOption {
      type = types.functionTo types.str;
      default = addr: "pass show email/${addr}";
      description = ''
        Maps an email address to the shell command that prints its password
        (mbsync PassCmd). Overridden per-host to read sops secrets instead of pass.
      '';
    };
  };

  config = mkIf cfg.enable {
    programs.mbsync.enable = true;

    programs.notmuch = {
      enable = true;
      new.tags = [ "new" ];
      hooks = {
        preNew = "mbsync --all";
        postNew = ''
          # retag all "new" messages "inbox" and "unread"
          notmuch tag +inbox +unread -new -- tag:new
        '';
      };
    };
    accounts.email = {
      maildirBasePath = "mail";
      accounts = {
        kyle_at_ondy_org = {
          address = "kyle@ondy.org";
          maildir.path = "ondy.org";
          gpg = {
            key = "3C799D26057B64E6D907B0ACDB0E3C33491F91C9";
            signByDefault = false;
          };
          imap = {
            host = "london.mxroute.com";
            tls = {
              enable = true;
            };
          };
          mbsync = {
            enable = true;
            create = "maildir";
            patterns = [
              "INBOX"
              "Archive"
              "Deleted Messages"
              "Drafts"
              "Junk"
              "Sent"
            ];
          };
          notmuch.enable = true;
          primary = true;
          realName = "Kyle Ondy";
          passwordCommand = cfg.passwordCommand "kyle@ondy.org";
          userName = "kyle@ondy.org";
        };
      };
    };
  };
}
