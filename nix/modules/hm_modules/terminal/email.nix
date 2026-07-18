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

    # Automatic mail sync timer
    # Note: This service is overridden in host configuration to use sops-based config
    systemd.user.services.mbsync = {
      Unit = {
        Description = "Mailbox synchronization service";
      };
      Service = {
        Type = "oneshot";
        # This ExecStart is overridden in host config for automated sync with sops
        ExecStart = "${pkgs.isync}/bin/mbsync --all";
        # Don't fail if quota exceeded - just skip and retry later
        SuccessExitStatus = [
          0
          1
        ];
      };
    };

    systemd.user.timers.mbsync = {
      Unit = {
        Description = "Mailbox synchronization timer";
      };
      Timer = {
        OnCalendar = "*:0/15"; # Every 15 minutes
        Persistent = true; # Run if missed while system was off
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
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
        kyle_at_ondy_me = {
          address = "kyle@ondy.me";
          maildir.path = "ondy.me";
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
            enable = false; # TODO: setup
            create = "maildir";
          };
          notmuch.enable = true;
          primary = false;
          realName = "Kyle Ondy";
          passwordCommand = cfg.passwordCommand "kyle@ondy.me";
          userName = "kyle@ondy.me";
        };
        kyleondy_at_gmail = {
          address = "kyleondy@gmail.com";
          maildir.path = "gmail";
          imap = {
            host = "imap.gmail.com";
            tls = {
              enable = true;
            };
          };
          mbsync = {
            enable = false; # TODO: setup
            create = "maildir";
          };
          notmuch.enable = true;
          primary = false;
          realName = "Kyle Ondy";
          passwordCommand = cfg.passwordCommand "kyleondy@gmail.com";
          userName = "kyleondy@gmail.com";
        };
      };
    };
  };
}
