{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.terminal.email;
  maildir = "ondy.org";

  # Derived from the folder on every run, since other clients move mail after
  # notmuch has indexed it. Searches skip search.exclude_tags (deleted, spam)
  # unless the query names one. folder: matches only that directory, not its
  # subfolders. mbsync puts the server's INBOX/spam under the Inbox maildir.
  folderTags = {
    inbox = [ "Inbox" ];
    deleted = [ "Deleted Messages" ];
    spam = [
      "Junk"
      "Inbox/spam"
    ];
  };
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
      # unread comes from the S flag alone. A flag-mapped tag (draft, flagged,
      # passed, replied, unread) set here or in postNew is written into the
      # filename, and mbsync pushes it over every other client.
      new.tags = [ ];
      hooks = {
        preNew = "mbsync --all";
        postNew = concatStrings (
          mapAttrsToList (
            tag: folders:
            let
              inFolders = "(${concatMapStringsSep " or " (f: ''folder:"${maildir}/${f}"'') folders})";
            in
            ''
              notmuch tag +${tag} -- '${inFolders} and not tag:${tag}'
              notmuch tag -${tag} -- 'tag:${tag} and not ${inFolders}'
            ''
          ) folderTags
        );
      };
    };
    accounts.email = {
      maildirBasePath = "mail";
      accounts = {
        kyle_at_ondy_org = {
          address = "kyle@ondy.org";
          maildir.path = maildir;
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
            # Expunge Near: a message deleted or moved away on the server is
            # removed here too. Nothing here expunges on the server.
            expunge = "maildir";
            patterns = [
              "INBOX"
              "INBOX/spam"
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
        # ondy.me and Gmail are synced only to see whether anything still
        # arrives before the accounts are shut down. Sync Pull, so reading or
        # tagging here never changes the server.
        kyle_at_ondy_me = {
          address = "kyle@ondy.me";
          maildir.path = "ondy.me";
          imap = {
            host = "london.mxroute.com";
            tls.enable = true;
          };
          mbsync = {
            enable = true;
            create = "maildir";
            expunge = "maildir";
            patterns = [ "*" ];
            extraConfig.channel.Sync = "Pull";
          };
          notmuch.enable = true;
          realName = "Kyle Ondy";
          passwordCommand = cfg.passwordCommand "kyle@ondy.me";
          userName = "kyle@ondy.me";
        };
        kyleondy_at_gmail_com = {
          address = "kyleondy@gmail.com";
          flavor = "gmail.com";
          maildir.path = "gmail.com";
          mbsync = {
            enable = true;
            create = "maildir";
            expunge = "maildir";
            # All Mail holds every label except Spam and Trash; "*" would
            # store a copy per label.
            patterns = [
              "INBOX"
              "[Gmail]/All Mail"
            ];
            extraConfig.channel.Sync = "Pull";
          };
          notmuch.enable = true;
          realName = "Kyle Ondy";
          passwordCommand = cfg.passwordCommand "kyleondy@gmail.com";
          userName = "kyleondy@gmail.com";
        };
      };
    };
  };
}
