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
    enable = mkEnableOption "email send / recieve";
  };

  config = mkIf cfg.enable {
    programs.mbsync.enable = true;
    programs.msmtp.enable = true;

    # Automatic mail sync timer
    systemd.user.services.mbsync = {
      Unit = {
        Description = "Mailbox synchronization service";
      };
      Service = {
        Type = "oneshot";
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
      hooks = {
        preNew = "mbsync --all";
      };
      new.tags = [ "new" ];
      hooks = {
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
              "*"
              "!INBOX/Archive"
              "!INBOX/Drafts"
              "!INBOX/Sent"
              "!INBOX/spam"
            ];
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
            enable = true;
            create = "maildir";
            patterns = [
              "*"
              "!INBOX/Archive"
              "!INBOX/Drafts"
              "!INBOX/Sent"
              "!INBOX/spam"
            ];
          };
          msmtp.enable = true;
          notmuch.enable = true;
          primary = false;
          realName = "Kyle Ondy";
          passwordCommand = "pass show email/kyle@ondy.me";
          smtp = {
            host = "london.mxroute.com";
            tls.enable = true;
          };
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
            enable = true;
            create = "maildir";
          };
          msmtp.enable = true;
          notmuch.enable = true;
          primary = false;
          realName = "Kyle Ondy";
          passwordCommand = "pass show email/kyleondy@gmail.com_mbsync";
          smtp = {
            host = "smtp.gmail.com";
            port = 587;
            tls = {
              enable = true;
              useStartTls = true;
            };
          };
          userName = "kyleondy@gmail.com";
        };
      };
    };
    home.packages = with pkgs; [
      neomutt # MUA

      # TODO: unmaintained, need to find new plugin. Perhaps extract_url or
      #       urlscan
      #urlview # easily open urls within emails
    ];
    xdg = {
      # todo: convert `~/.config` (XDG) to nix paths
      configFile."neomutt/neomuttrc".text = ''
        # -- I18n --
        set charset       = utf-8
        set send_charset  = utf-8

        # -- Colors --
        source ${pkgs.mutt-colors-solarized}/mutt-colors-solarized-dark-256.muttrc

        # -- Paths --
        set folder           = ~/mail
        set mailcap_path     = ~/.config/neomutt/mailcap.muttrc

        # -- Caching --
        set header_cache_backend  = lmdb
        set header_cache          = ~/.mutt/cache/headers
        set message_cachedir      = ~/.mutt/cache/bodies

        # -- Mailboxes --
        set realname          = 'Kyle Ondy'
        set from              = 'kyle@ondy.org'
        set spoolfile         = "+ondy.org/Inbox"
        set virtual_spoolfile = yes
        set mbox              = "+ondy.org/Inbox"
        set trash             = "+ondy.org/Trash"
        set postponed         = "+ondy.org/Drafts"
        set record            = "+ondy.org/Sent"
        set sendmail          = "msmtp"
        set sendmail_wait     = 0

        # Multiple account support
        alternates '^kyle@ondy\.org$' '^kyle@ondy\.me$' '^kyleondy@gmail\.com$'

        # Default account macros (kyle@ondy.org)
        macro index S "<save-message>+ondy.org/Spam<enter>"
        macro index,pager A "<save-message>=ondy.org/Archive<enter>"
        macro index ,d \
          "<tag-prefix><save-message>+ondy.org/Trash<enter>" \
        "delete all"

        # Account switching macros
        macro index <f2> '<sync-mailbox><enter-command>source ~/.config/neomutt/accounts/ondy.me<enter><change-folder>!<enter>' "Switch to kyle@ondy.me"
        macro index <f3> '<sync-mailbox><enter-command>source ~/.config/neomutt/accounts/gmail<enter><change-folder>!<enter>' "Switch to gmail"
        macro index <f4> '<sync-mailbox><enter-command>source ~/.config/neomutt/accounts/ondy.org<enter><change-folder>!<enter>' "Switch to kyle@ondy.org"

        # All mailboxes across all accounts
        mailboxes +ondy.org/Inbox \
                  +ondy.org/Archive \
                  +ondy.org/Drafts \
                  +ondy.org/Sent \
                  +ondy.org/Trash \
                  +ondy.org/Junk \
                  +ondy.org/spam \
                  +ondy.me/Inbox \
                  +ondy.me/Archive \
                  +ondy.me/Drafts \
                  +ondy.me/Sent \
                  +ondy.me/Trash \
                  +ondy.me/Junk \
                  +gmail/Inbox \
                  "+gmail/[Gmail]/Sent Mail" \
                  "+gmail/[Gmail]/Drafts" \
                  "+gmail/[Gmail]/Trash" \
                  "+gmail/[Gmail]/Spam" \
                  "+gmail/[Gmail]/All Mail"

        # TODO: figure out notmuch and workflow
        # virtual-mailboxes "inbox" "notmuch://?query=tag:inbox"
        # virtual-mailboxes "archive" "notmuch://?query=tag:archive"
        # virtual-mailboxes "sent" "notmuch://?query=tag:sent"
        # virtual-mailboxes "newsletters" "notmuch://?query=tag:newsletters"

        # -- Basic Options --
        set wait_key = no        # shut up, mutt
        set mbox_type = Maildir  # mailbox type
        set timeout = 3          # idle time before scanning
        set mail_check = 0       # minimum time between scans
        set delete               # don't ask, just do
        set quit                 # don't ask, just do!!
        set beep_new             # bell on new mails
        set pipe_decode          # strip headers and eval mimes when piping
        set thorough_search      # strip headers and eval mimes before searching
        set editor= 'nvim'
        unset record

        # -- Sidebar Patch --
        set sidebar_visible
        set sidebar_format = "%B%?F? [%F]?%* %?N?%N/?%S"
        set mail_check_stats
        set sidebar_short_path
        #color sidebar_new yellow default
        set status_chars  = " *%A"
        set status_format = "───[ Folder: %f ]───[%r%m messages%?n? (%n new)?%?d? (%d to delete)?%?t? (%t tagged)? ]───%>─%?p?( %p postponed )?───"

        # -- Header Options --
        ignore *                                # ignore all headers
        unignore from: to: cc: date: subject:   # show only these
        unhdr_order *                           # some distros order things by default
        hdr_order from: to: cc: date: subject:  # and in this order

        # -- Index View Options --
        set date_format="%y-%m-%d %R"
        set index_format = "[%Z]  %D  %-20.20F  %s"
        set sort = threads                         # like gmail
        set sort_aux = reverse-last-date-received  # like gmail
        set uncollapse_jump                        # don't collapse on an unread message
        set reply_regexp = "^(([Rr][Ee]?(\[[0-9]+\])?: *)?(\[[^]]+\] *)?)*"
        set confirmappend=no


        # -- Compose View --
        set envelope_from
        set sig_dashes
        set edit_headers
        set fast_reply
        set askcc
        set fcc_attach
        unset mime_forward
        set forward_format = "Fwd: %s"
        set forward_decode
        set attribution = "On %d, %n wrote:"
        set reply_to
        set reverse_name
        set include
        set forward_quote

        # -- Pager View Options --
        set pager_index_lines = 10 # number of index lines to show
        set pager_context = 3      # number of context lines to show
        set pager_stop             # don't go to next message automatically
        set menu_scroll            # scroll in menus
        set tilde                  # show tildes like in vim
        unset markers              # no ugly plus signs

        set quote_regexp = "^( {0,4}[>|:#%]| {0,4}[a-z0-9]+[>|]+)+"
        alternative_order text/plain text/enriched text/html

        # -- Bindings --
        # mode                  keys      action
        bind attach,index,pager \CD       next-page
        bind attach,index,pager \CU       previous-page
        bind index,pager        <down>    sidebar-next
        bind index,pager        <up>      sidebar-prev
        bind index,pager        <right>   sidebar-open
        bind attach,index       g         noop
        bind attach,index       gg        first-entry
        bind attach,index       G         last-entry
        bind index              R         group-reply
        bind index              <tab>     sync-mailbox
        bind index              <space>   collapse-thread
        bind pager              k         previous-line
        bind pager              g         noop
        bind pager              j         next-line
        bind pager              gg        top
        bind pager              G         bottom
        bind pager              R         group-reply
        bind index              p         recall-message
        bind attach             <return>  view-mailcap

        # -- macros --
        macro index C "<copy-message>?<toggle-mailboxes>" "copy a message to a mailbox"
        macro index M "<save-message>?<toggle-mailboxes>" "move a message to a mailbox"
        macro index,pager S '<sync-mailbox><shell-escape>mbsync -a<enter>'

        # -- GPG --
        set crypt_use_gpgme=yes
        set pgp_sign_as = 0xDB0E3C33491F91C9
        set crypt_autosign                              # sign all outgoing messages
        set crypt_replyencrypt                          # encrypt replies to messages which are encrypted
        set crypt_replysignencrypted                    # encrypt and sign replies to encryped messages
        set pgp_good_sign="^gpg: Good signature from"

        # -- mailcap --
        set mailcap_path = ~/.config/neomutt/mailcap
      '';
      configFile."neomutt/mailcap".text = ''
        # mailcap
        application/octet-stream ; echo %s "can be anything..."
        text/html                ; firefox %s
        application/pdf          ; /usr/bin/zathura %s
        image/*                  ; /usr/bin/feh %s
        audio/*                  ; /usr/bin/mpv %s
        video/*                  ; /usr/bin/mpv %s
        text/plain               ; cat %s                       ; copiousoutput
        text/x-diff              ; vim -R %s
        text/x-patch             ; vim -R %s
      '';
      configFile."neomutt/accounts/ondy.org".text = ''
        set from              = 'kyle@ondy.org'
        set spoolfile         = "+ondy.org/Inbox"
        set mbox              = "+ondy.org/Inbox"
        set trash             = "+ondy.org/Trash"
        set postponed         = "+ondy.org/Drafts"
        set record            = "+ondy.org/Sent"
        macro index S "<save-message>+ondy.org/Spam<enter>"
        macro index,pager A "<save-message>=ondy.org/Archive<enter>"
      '';
      configFile."neomutt/accounts/ondy.me".text = ''
        set from              = 'kyle@ondy.me'
        set spoolfile         = "+ondy.me/Inbox"
        set mbox              = "+ondy.me/Inbox"
        set trash             = "+ondy.me/Trash"
        set postponed         = "+ondy.me/Drafts"
        set record            = "+ondy.me/Sent"
        macro index S "<save-message>+ondy.me/Spam<enter>"
        macro index,pager A "<save-message>=ondy.me/Archive<enter>"
      '';
      configFile."neomutt/accounts/gmail".text = ''
        set from              = 'kyleondy@gmail.com'
        set spoolfile         = "+gmail/Inbox"
        set mbox              = "+gmail/Inbox"
        set trash             = "+gmail/[Gmail]/Trash"
        set postponed         = "+gmail/[Gmail]/Drafts"
        set record            = "+gmail/[Gmail]/Sent Mail"
        macro index S "<save-message>+gmail/[Gmail]/Spam<enter>"
        macro index,pager A "<save-message>+gmail/[Gmail]/All Mail<enter>"
      '';
    };
  };
}
