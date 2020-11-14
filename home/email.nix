# nix's accounts.email does _not_ allow for more than one account at the
# moment. This is a problem as I typically set neomutt up to read multiple
# accounts at one.
#
# I need to look into solutions to this, but set up my main account for now.
{ ... }:

{
  programs.mbsync.enable = true;
  programs.msmtp.enable = true;
  programs.notmuch = {
    enable = true;
    hooks = { preNew = "mbsync --all"; };
  };
  accounts.email = {
    maildirBasePath = "./mail";
    accounts.kyle_at_ondy_org = {
      address = "kyle@ondy.org";
      maildir.path = "ondy.org";
      gpg = {
        key = "3C799D26057B64E6D907B0ACDB0E3C33491F91C9";
        signByDefault = true;
      };
      imap = {
        host = "london.mxroute.com";
        tls = { enable = true; };
      };
      mbsync = {
        enable = true;
        create = "maildir";
      };
      msmtp.enable = true;
      notmuch.enable = true;
      primary = true;
      realName = "Kyle Ondy";
      passwordCommand = "pass show email/kyle@ondy.org";
      smtp = {
        host = "london.mxroute.com";
        tls.enable = true;
      };
      userName = "kyle@ondy.org";
    };
  };
}
