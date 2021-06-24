{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.foundry.terminal.email;
  old_dots = ../../home/_dots_not_yet_in_nix;
in
{
  options.foundry.terminal.email = {
    enable = mkEnableOption "email send / recieve";
  };

  config = mkIf cfg.enable {
    programs.mbsync.enable = true;
    programs.msmtp.enable = true;
    programs.notmuch = {
      enable = true;
      hooks = { preNew = "mbsync --all"; };
    };
    accounts.email = {
      maildirBasePath = "mail";
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
    home.packages = with pkgs; [
      neomutt # MUA
      urlview # easily open urls within emails
    ];
    xdg = {
      configFile."neomutt/neomuttrc".source = old_dots + /neomutt/neomuttrc;
      configFile."neomutt/mutt-colors-solarized-dark-256.muttrc".source = old_dots
        + /neomutt/mutt-colors-solarized-dark-256.muttrc;
      configFile."neomutt/bindings.muttrc".source = old_dots
        + /neomutt/bindings.muttrc;
      configFile."neomutt/macros.muttrc".source = old_dots
        + /neomutt/macros.muttrc;
      configFile."neomutt/gpg.muttrc".source = old_dots + /neomutt/gpg.muttrc;
      configFile."neomutt/hooks.muttrc".source = old_dots + /neomutt/hooks.muttrc;
      configFile."neomutt/mailcap.muttrc".source = old_dots + /neomutt/mailcap.muttrc;
    };
  };
}
