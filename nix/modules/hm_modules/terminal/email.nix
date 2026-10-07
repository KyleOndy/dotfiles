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
  # unless the query names one.
  folderTags = {
    inbox = "Inbox";
    deleted = "Deleted Messages";
    spam = "Junk";
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
          mapAttrsToList (tag: folder: ''
            notmuch tag +${tag} -- 'folder:"${maildir}/${folder}" and not tag:${tag}'
            notmuch tag -${tag} -- 'tag:${tag} and not folder:"${maildir}/${folder}"'
          '') folderTags
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
